#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENDPOINT="http://localhost:4566"
REGION="us-east-1"
LOG_DIR="$SCRIPT_DIR/logs"
PASS_COUNT=0
FAIL_COUNT=0

export AWS_ENDPOINT_URL="$ENDPOINT"
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export no_proxy="localhost,127.0.0.1,.dev.bloomberg.com,.bcs.bloomberg.com,.bms.bloomberg.com"

mkdir -p "$LOG_DIR"

# --- helpers ---

send_trace() {
  local name="${1:-test-span}"
  local payload="{
    \"resourceSpans\": [{
      \"resource\": {\"attributes\": [{\"key\": \"service.name\", \"value\": {\"stringValue\": \"$name-service\"}}]},
      \"scopeSpans\": [{
        \"spans\": [{
          \"traceId\": \"01020304050607080102030405060708\",
          \"spanId\": \"0102030405060708\",
          \"name\": \"$name\",
          \"kind\": 1,
          \"startTimeUnixNano\": \"3000000000\",
          \"endTimeUnixNano\": \"4000000000\"
        }]
      }]
    }]
  }"
  echo "$payload"
}

check_result() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL (expected $expected, got $actual)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

stop_pids() {
  for pid in "$@"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "$@"; do
    wait "$pid" 2>/dev/null || true
  done
}

cleanup() {
  echo ""
  echo "=== Cleaning up ==="
  echo "  Stopping LocalStack..."
  docker compose -f "$SCRIPT_DIR/docker-compose.yaml" down 2>/dev/null || true
  echo "  Done."
}
trap cleanup EXIT

# --- header ---

echo "=== Configuration ==="
echo "  SCRIPT_DIR:       $SCRIPT_DIR"
echo "  REPO_ROOT:        $REPO_ROOT"
echo "  AWS_ENDPOINT_URL: $ENDPOINT"
echo "  no_proxy:         $no_proxy"
echo ""

# --- localstack ---

echo "=== Starting LocalStack ==="
docker compose -f "$SCRIPT_DIR/docker-compose.yaml" up -d
echo "  Waiting for LocalStack to be ready..."
for i in $(seq 1 30); do
  if aws --endpoint-url "$ENDPOINT" --region "$REGION" \
    secretsmanager list-secrets --query 'SecretList' --output text >/dev/null 2>&1; then
    echo "  LocalStack is ready (attempt $i)."
    break
  fi
  sleep 1
done
echo ""

# --- seed secrets ---

echo "=== Seeding secrets ==="
source "$SCRIPT_DIR/setup-secrets.sh"

echo ""
echo "=== Verifying secrets in LocalStack ==="
echo "  Client secret:"
aws --endpoint-url "$ENDPOINT" --region "$REGION" \
  secretsmanager get-secret-value --secret-id "test/client-creds" \
  --query 'SecretString' --output text

echo "  Server secret:"
aws --endpoint-url "$ENDPOINT" --region "$REGION" \
  secretsmanager get-secret-value --secret-id "test/server-htpasswd" \
  --query 'SecretString' --output text

# capture ARNs for configs
export SERVER_SECRET_ARN=$(aws --endpoint-url "$ENDPOINT" --region "$REGION" \
  secretsmanager describe-secret --secret-id "test/server-htpasswd" \
  --query 'ARN' --output text)
export CLIENT_SECRET_ARN=$(aws --endpoint-url "$ENDPOINT" --region "$REGION" \
  secretsmanager describe-secret --secret-id "test/client-creds" \
  --query 'ARN' --output text)
echo ""

# --- build ---

echo "=== Building collector ==="
echo "  Running: go build -o $SCRIPT_DIR/testcollector ./collector/"
(cd "$SCRIPT_DIR/collector" && go build -o "$SCRIPT_DIR/testcollector" .)
echo "  Build complete."
echo ""

# =========================================
#  SERVER-SIDE TESTS
# =========================================

echo "========================================="
echo "  SERVER-SIDE TESTS"
echo "  The server collector validates inbound requests using htpasswd"
echo "  credentials fetched from AWS Secrets Manager."
echo "========================================="
echo ""

echo "=== Starting server collector ==="
echo "  Config: $SCRIPT_DIR/config-server.yaml"
echo "  Listening on: :4318 (OTLP HTTP with basicauth server)"
"$SCRIPT_DIR/testcollector" --config "$SCRIPT_DIR/config-server.yaml" \
  > "$LOG_DIR/server-collector.log" 2>&1 &
SERVER_PID=$!
echo "  Server PID: $SERVER_PID"
echo "  Waiting for server to start..."
sleep 3
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "  FAIL: Server collector died on startup"
  cat "$LOG_DIR/server-collector.log"
  exit 1
fi
echo "  Server collector is running."
echo ""

echo "=== Test 1: valid credentials (expect HTTP 200) ==="
echo "  Description: Send OTLP trace with correct username/password that matches"
echo "  the htpasswd entry stored in AWS Secrets Manager."
echo "  Sending: curl -u admin:secret123 http://localhost:4318/v1/traces"
RESP=$(curl -s -w "\n%{http_code}" -u admin:secret123 \
  -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d "$(send_trace test-span-1)")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
echo "  HTTP Code: $HTTP_CODE"
echo "  Body: $BODY"
check_result "valid credentials" "200" "$HTTP_CODE"
echo ""

echo "=== Test 2: invalid credentials (expect HTTP 401) ==="
echo "  Description: Send OTLP trace with wrong password. The server rejects"
echo "  because the password does not match the htpasswd entry from AWS."
echo "  Sending: curl -u admin:wrongpass http://localhost:4318/v1/traces"
RESP=$(curl -s -w "\n%{http_code}" -u admin:wrongpass \
  -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d "$(send_trace test-span-bad)")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
echo "  HTTP Code: $HTTP_CODE"
echo "  Body: $BODY"
check_result "invalid credentials" "401" "$HTTP_CODE"
echo ""

echo "=== Test 3: no credentials (expect HTTP 401) ==="
echo "  Description: Send OTLP trace with no Authorization header."
echo "  The server rejects unauthenticated requests."
echo "  Sending: curl http://localhost:4318/v1/traces (no auth)"
RESP=$(curl -s -w "\n%{http_code}" \
  -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d "$(send_trace test-span-noauth)")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
echo "  HTTP Code: $HTTP_CODE"
echo "  Body: $BODY"
check_result "no credentials" "401" "$HTTP_CODE"
echo ""

# =========================================
#  CLIENT-SIDE TESTS
# =========================================

echo "========================================="
echo "  CLIENT-SIDE TESTS"
echo "  The client collector fetches credentials from AWS Secrets Manager"
echo "  and attaches them to outgoing requests to the server collector."
echo "========================================="
echo ""

echo "=== Starting client collector ==="
echo "  Config: $SCRIPT_DIR/config-client.yaml"
echo "  Listening on: :4319 (OTLP HTTP, no auth required on inbound)"
echo "  Forwarding to: :4318 (server collector, with basicauth client)"
"$SCRIPT_DIR/testcollector" --config "$SCRIPT_DIR/config-client.yaml" \
  > "$LOG_DIR/client-collector.log" 2>&1 &
CLIENT_PID=$!
echo "  Client PID: $CLIENT_PID"
echo "  Waiting for client to start..."
sleep 3
if ! kill -0 "$CLIENT_PID" 2>/dev/null; then
  echo "  FAIL: Client collector died on startup"
  cat "$LOG_DIR/client-collector.log"
  exit 1
fi
echo "  Client collector is running."
echo ""

echo "=== Test 4: client forwards with AWS credentials (expect HTTP 200) ==="
echo "  Description: Send OTLP trace to the client collector (no auth needed)."
echo "  The client fetches username/password from AWS Secrets Manager and"
echo "  attaches them as Basic Auth when forwarding to the server collector."
echo "  The server validates the credentials against its htpasswd from AWS."
echo "  Sending: curl http://localhost:4319/v1/traces (no auth, client adds it)"
RESP=$(curl -s -w "\n%{http_code}" \
  -X POST http://localhost:4319/v1/traces \
  -H "Content-Type: application/json" \
  -d "$(send_trace test-span-forwarded)")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
echo "  HTTP Code: $HTTP_CODE"
echo "  Body: $BODY"
check_result "client forwards" "200" "$HTTP_CODE"
echo ""

echo "=== Test 5: verify server received the forwarded trace ==="
echo "  Description: Check the server collector logs to confirm it received"
echo "  and processed the trace that was forwarded by the client collector."
sleep 2
if grep -q "test-span-forwarded" "$LOG_DIR/server-collector.log"; then
  echo "  Server log contains 'test-span-forwarded' — trace was forwarded successfully."
  check_result "server received trace" "200" "200"
else
  echo "  WARNING: Could not verify trace in server debug output."
  check_result "server received trace" "200" "missing"
fi
echo ""

echo "=== Test 6: Prometheus metrics ==="
echo "  Description: Query the collector Prometheus endpoints to verify"
echo "  exporter and receiver metrics."
echo ""
echo "  Full Prometheus metrics: server collector (:8888)"
curl -s http://localhost:8888/metrics | tee "$LOG_DIR/server-metrics.txt" | grep -E "^otelcol_"
echo ""
echo "  Full Prometheus metrics: client collector (:8889)"
curl -s http://localhost:8889/metrics | tee "$LOG_DIR/client-metrics.txt" | grep -E "^otelcol_"
echo ""

echo "  Stopping collectors from basic tests..."
stop_pids "$SERVER_PID" "$CLIENT_PID"
unset SERVER_PID CLIENT_PID
echo ""

# =========================================
#  FAILURE TESTS
# =========================================

echo "========================================="
echo "  FAILURE TESTS"
echo "  Verify the collector fails to start when it cannot fetch"
echo "  the secret from AWS Secrets Manager (e.g., wrong ARN)."
echo "========================================="
echo ""

echo "=== Test 7: server fails to start with non-existent secret (expect exit) ==="
echo "  Description: The awssecretsmanagerprovider extension references a secret ARN"
echo "  that does not exist. The collector should fail to start because the initial"
echo "  fetch in Start() returns an error."
echo "  Config: config-server-bad-secret.yaml"
"$SCRIPT_DIR/testcollector" --config "$SCRIPT_DIR/config-server-bad-secret.yaml" \
  > "$LOG_DIR/server-bad-secret.log" 2>&1 || true
EXIT_CODE=$?
echo "  Collector exited with code: $EXIT_CODE"
echo "  Log output:"
cat "$LOG_DIR/server-bad-secret.log"
if grep -q "ResourceNotFoundException\|secret.*not found\|failed to start" "$LOG_DIR/server-bad-secret.log"; then
  echo ""
  echo "  Collector failed to start as expected — secret not found."
  check_result "server bad secret" "200" "200"
else
  echo ""
  echo "  WARNING: Expected failure message not found in logs."
  check_result "server bad secret" "200" "missing"
fi
echo ""

echo "=== Test 8: client fails to start with non-existent secret (expect exit) ==="
echo "  Description: The awssecretsmanagerprovider extension references a secret ARN"
echo "  that does not exist. The collector should fail to start because the initial"
echo "  fetch in Start() returns an error."
echo "  Config: config-client-bad-secret.yaml"
"$SCRIPT_DIR/testcollector" --config "$SCRIPT_DIR/config-client-bad-secret.yaml" \
  > "$LOG_DIR/client-bad-secret.log" 2>&1 || true
EXIT_CODE=$?
echo "  Collector exited with code: $EXIT_CODE"
echo "  Log output:"
cat "$LOG_DIR/client-bad-secret.log"
if grep -q "ResourceNotFoundException\|secret.*not found\|failed to start" "$LOG_DIR/client-bad-secret.log"; then
  echo ""
  echo "  Collector failed to start as expected — secret not found."
  check_result "client bad secret" "200" "200"
else
  echo ""
  echo "  WARNING: Expected failure message not found in logs."
  check_result "client bad secret" "200" "missing"
fi
echo ""

# =========================================
#  CONFIG CONFLICT TESTS
# =========================================

echo "========================================="
echo "  CONFIG CONFLICT TESTS"
echo "  Verify the collector rejects configs where secret_provider"
echo "  is combined with inline/file credential sources."
echo "========================================="
echo ""

echo "=== Test 9: server secret_provider + inline htpasswd (expect rejection) ==="
echo "  Description: basicauth/server has both 'inline' and 'secret_provider' set."
echo "  The collector should reject this at config validation time."
echo "  Config: config-server-conflict-inline.yaml"
"$SCRIPT_DIR/testcollector" --config "$SCRIPT_DIR/config-server-conflict-inline.yaml" \
  > "$LOG_DIR/server-conflict-inline.log" 2>&1 || true
echo "  Log output:"
cat "$LOG_DIR/server-conflict-inline.log"
if grep -q "only one credential source allowed" "$LOG_DIR/server-conflict-inline.log"; then
  echo ""
  echo "  Collector rejected conflicting config as expected."
  check_result "server conflict inline" "200" "200"
else
  echo ""
  echo "  WARNING: Expected conflict error not found in logs."
  check_result "server conflict inline" "200" "missing"
fi
echo ""

echo "=== Test 10: server secret_provider + file htpasswd (expect rejection) ==="
echo "  Description: basicauth/server has both 'file' and 'secret_provider' set."
echo "  The collector should reject this at config validation time."
echo "  Config: config-server-conflict-file.yaml"
"$SCRIPT_DIR/testcollector" --config "$SCRIPT_DIR/config-server-conflict-file.yaml" \
  > "$LOG_DIR/server-conflict-file.log" 2>&1 || true
echo "  Log output:"
cat "$LOG_DIR/server-conflict-file.log"
if grep -q "only one credential source allowed" "$LOG_DIR/server-conflict-file.log"; then
  echo ""
  echo "  Collector rejected conflicting config as expected."
  check_result "server conflict file" "200" "200"
else
  echo ""
  echo "  WARNING: Expected conflict error not found in logs."
  check_result "server conflict file" "200" "missing"
fi
echo ""

echo "=== Test 11: client secret_provider + username (expect rejection) ==="
echo "  Description: basicauth/client has both 'username' and 'secret_provider' set."
echo "  The collector should reject this at config validation time."
echo "  Config: config-client-conflict-username.yaml"
"$SCRIPT_DIR/testcollector" --config "$SCRIPT_DIR/config-client-conflict-username.yaml" \
  > "$LOG_DIR/client-conflict-username.log" 2>&1 || true
echo "  Log output:"
cat "$LOG_DIR/client-conflict-username.log"
if grep -q "only one credential source allowed" "$LOG_DIR/client-conflict-username.log"; then
  echo ""
  echo "  Collector rejected conflicting config as expected."
  check_result "client conflict username" "200" "200"
else
  echo ""
  echo "  WARNING: Expected conflict error not found in logs."
  check_result "client conflict username" "200" "missing"
fi
echo ""

echo "=== Test 12: client secret_provider + password_file (expect rejection) ==="
echo "  Description: basicauth/client has both 'password_file' and 'secret_provider' set."
echo "  The collector should reject this at config validation time."
echo "  Config: config-client-conflict-file.yaml"
"$SCRIPT_DIR/testcollector" --config "$SCRIPT_DIR/config-client-conflict-file.yaml" \
  > "$LOG_DIR/client-conflict-file.log" 2>&1 || true
echo "  Log output:"
cat "$LOG_DIR/client-conflict-file.log"
if grep -q "only one credential source allowed" "$LOG_DIR/client-conflict-file.log"; then
  echo ""
  echo "  Collector rejected conflicting config as expected."
  check_result "client conflict file" "200" "200"
else
  echo ""
  echo "  WARNING: Expected conflict error not found in logs."
  check_result "client conflict file" "200" "missing"
fi
echo ""

# =========================================
#  ROTATION TESTS
# =========================================

echo "========================================="
echo "  ROTATION TESTS"
echo "  Verify the collector picks up rotated secrets after refresh_interval."
echo "  Starting fresh collectors for this section."
echo "  refresh_interval is 10s in both configs."
echo "========================================="
echo ""

echo "  Re-seeding secrets to original values..."
aws --endpoint-url "$ENDPOINT" --region "$REGION" \
  secretsmanager put-secret-value --secret-id "test/server-htpasswd" \
  --secret-string 'admin:{SHA}8rFPaOuZX6yzocNSh7d41b14VRE=' > /dev/null
aws --endpoint-url "$ENDPOINT" --region "$REGION" \
  secretsmanager put-secret-value --secret-id "test/client-creds" \
  --secret-string '{"user":"admin","pass":"secret123"}' > /dev/null
echo ""

echo "=== Starting server collector (for rotation tests) ==="
"$SCRIPT_DIR/testcollector" --config "$SCRIPT_DIR/config-server.yaml" \
  > "$LOG_DIR/rotation-server.log" 2>&1 &
ROT_SERVER_PID=$!
echo "  Server PID: $ROT_SERVER_PID"
sleep 3
echo "  Server running on :4318"
echo ""

echo "=== Starting client collector (for rotation tests) ==="
"$SCRIPT_DIR/testcollector" --config "$SCRIPT_DIR/config-client.yaml" \
  > "$LOG_DIR/rotation-client.log" 2>&1 &
ROT_CLIENT_PID=$!
echo "  Client PID: $ROT_CLIENT_PID"
sleep 3
echo "  Client running on :4319"
echo ""

echo "=== Test 13: rotate server htpasswd secret ==="
echo "  Description: Update the server htpasswd in AWS to accept a new password"
echo "  ('rotated789' instead of 'secret123'). After the refresh interval,"
echo "  the old password should be rejected and the new one accepted."
echo ""

echo "  Step 1: Verify current password works before rotation..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u admin:secret123 \
  -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d "$(send_trace pre-rotation)")
echo "  curl -u admin:secret123 → HTTP $HTTP_CODE (should be 200)"
echo ""

# rotated789 → SHA1
ROTATED_HTPASSWD='admin:{SHA}sGNqzFg1FAaXk2fHrL2gSfUIQUQ='
echo "  Step 2: Update secret in LocalStack..."
aws --endpoint-url "$ENDPOINT" --region "$REGION" \
  secretsmanager put-secret-value --secret-id "test/server-htpasswd" \
  --secret-string "$ROTATED_HTPASSWD"
echo "  Secret updated to: $ROTATED_HTPASSWD (password: rotated789)"
echo ""

echo "  Step 3: Waiting 12s for refresh_interval (10s) to trigger..."
sleep 12
echo ""

echo "  Step 4: Test old password is now rejected..."
echo "  Sending: curl -u admin:secret123 http://localhost:4318/v1/traces"
RESP=$(curl -s -w "\n%{http_code}" -u admin:secret123 \
  -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d "$(send_trace old-pass-span)")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
echo "  HTTP Code: $HTTP_CODE"
echo "  Body: $BODY"
echo "  Old password rejected — $([ "$HTTP_CODE" = "401" ] && echo "PASS" || echo "FAIL")"
check_result "old password rejected" "401" "$HTTP_CODE"
echo ""

echo "  Step 5: Test new password is now accepted..."
echo "  Sending: curl -u admin:rotated789 http://localhost:4318/v1/traces"
RESP=$(curl -s -w "\n%{http_code}" -u admin:rotated789 \
  -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d "$(send_trace new-pass-span)")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
echo "  HTTP Code: $HTTP_CODE"
echo "  Body: $BODY"
echo "  New password accepted — $([ "$HTTP_CODE" = "200" ] && echo "PASS" || echo "FAIL")"
check_result "new password accepted" "200" "$HTTP_CODE"
echo ""

echo "=== Test 14: rotate client credentials + server htpasswd together ==="
echo "  Description: Simulate a coordinated rotation — update both the server"
echo "  htpasswd and client credentials to a new shared password ('finalpass')."
echo "  After refresh, the client should forward with the new password and"
echo "  the server should accept it."
echo ""

# finalpass → SHA1
FINAL_HTPASSWD='admin:{SHA}ZLtHL1yz8cE3Oh/JwegFDyot8hk='
FINAL_CLIENT_CREDS='{"user":"admin","pass":"finalpass"}'

echo "  Step 1: Update both secrets..."
aws --endpoint-url "$ENDPOINT" --region "$REGION" \
  secretsmanager put-secret-value --secret-id "test/server-htpasswd" \
  --secret-string "$FINAL_HTPASSWD"
aws --endpoint-url "$ENDPOINT" --region "$REGION" \
  secretsmanager put-secret-value --secret-id "test/client-creds" \
  --secret-string "$FINAL_CLIENT_CREDS"
echo "  Server htpasswd updated to: $FINAL_HTPASSWD (password: finalpass)"
echo "  Client creds updated to: $FINAL_CLIENT_CREDS"
echo ""

echo "  Step 2: Waiting 12s for both collectors to refresh..."
sleep 12
echo ""

echo "  Step 3: Verify direct auth with new password works..."
echo "  Sending: curl -u admin:finalpass http://localhost:4318/v1/traces"
RESP=$(curl -s -w "\n%{http_code}" -u admin:finalpass \
  -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d "$(send_trace final-direct-span)")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
echo "  HTTP Code: $HTTP_CODE"
echo "  Body: $BODY"
echo "  Direct auth with rotated password — $([ "$HTTP_CODE" = "200" ] && echo "PASS" || echo "FAIL")"
check_result "direct rotated auth" "200" "$HTTP_CODE"
echo ""

echo "  Step 4: Verify client forwards with rotated credentials..."
echo "  Sending: curl http://localhost:4319/v1/traces (client adds rotated creds)"
RESP=$(curl -s -w "\n%{http_code}" \
  -X POST http://localhost:4319/v1/traces \
  -H "Content-Type: application/json" \
  -d "$(send_trace rotated-span)")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
echo "  HTTP Code: $HTTP_CODE"
echo "  Body: $BODY"
echo "  Client forwarded with rotated credentials — $([ "$HTTP_CODE" = "200" ] && echo "PASS" || echo "FAIL")"
check_result "client rotated forward" "200" "$HTTP_CODE"
echo ""

echo "  Step 5: Verify server received the rotated-span..."
sleep 2
if grep -q "rotated-span" "$LOG_DIR/rotation-server.log"; then
  echo "  Server log contains 'rotated-span' — end-to-end rotation works."
  check_result "rotation e2e" "200" "200"
else
  echo "  WARNING: 'rotated-span' not found in server log."
  check_result "rotation e2e" "200" "missing"
fi
echo ""

echo "  Stopping rotation collectors..."
stop_pids "$ROT_SERVER_PID" "$ROT_CLIENT_PID"
echo ""

echo "=== Rotation server collector logs ==="
cat "$LOG_DIR/rotation-server.log"
echo ""
echo "=== Rotation client collector logs ==="
cat "$LOG_DIR/rotation-client.log"
echo ""

# =========================================
#  SUMMARY
# =========================================

TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "========================================="
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "  ALL TESTS PASSED ($PASS_COUNT/$TOTAL)"
else
  echo "  TESTS FAILED: $FAIL_COUNT/$TOTAL"
fi
echo "========================================="
echo ""

echo "=== Logs saved to ==="
echo "  Server log:           $LOG_DIR/server-collector.log"
echo "  Client log:           $LOG_DIR/client-collector.log"
echo "  Rotation server log:  $LOG_DIR/rotation-server.log"
echo "  Rotation client log:  $LOG_DIR/rotation-client.log"
echo "  Server bad secret:    $LOG_DIR/server-bad-secret.log"
echo "  Client bad secret:    $LOG_DIR/client-bad-secret.log"
echo "  Server conflict inline: $LOG_DIR/server-conflict-inline.log"
echo "  Server conflict file:   $LOG_DIR/server-conflict-file.log"
echo "  Client conflict user:   $LOG_DIR/client-conflict-username.log"
echo "  Client conflict file:   $LOG_DIR/client-conflict-file.log"
echo "  Server metrics:       $LOG_DIR/server-metrics.txt"
echo "  Client metrics:       $LOG_DIR/client-metrics.txt"
echo ""

[ "$FAIL_COUNT" -eq 0 ] || exit 1
