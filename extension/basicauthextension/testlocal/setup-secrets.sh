#!/bin/bash
set -euo pipefail

ENDPOINT="${AWS_ENDPOINT_URL:-http://localhost:4566}"
REGION="us-east-1"

HTPASSWD='admin:{SHA}8rFPaOuZX6yzocNSh7d41b14VRE='
CLIENT_CREDS='{"user":"admin","pass":"secret123"}'

echo "Creating client credentials secret..."
aws --endpoint-url "$ENDPOINT" --region "$REGION" \
  secretsmanager create-secret \
  --name "test/client-creds" \
  --secret-string "$CLIENT_CREDS"

echo "Creating server htpasswd secret..."
aws --endpoint-url "$ENDPOINT" --region "$REGION" \
  secretsmanager create-secret \
  --name "test/server-htpasswd" \
  --secret-string "$HTPASSWD"

echo "Secrets created successfully."
