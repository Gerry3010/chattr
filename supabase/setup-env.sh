#!/bin/bash

# Setup Environment Variables in Supabase Vault
# This script should be run after starting Supabase locally or on deployment

echo "Setting up environment variables in Supabase Vault..."

# Get the Supabase URL and Service Role Key from environment or config
SUPABASE_URL="${SUPABASE_URL:-http://localhost:54321}"
SUPABASE_SERVICE_ROLE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"

# If not in environment, try to get from config.toml
if [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
  # Try to extract from config.toml (if exists)
  CONFIG_FILE="$(dirname "$0")/config.toml"
  if [ -f "$CONFIG_FILE" ]; then
    SUPABASE_SERVICE_ROLE_KEY=$(grep -A 1 '\[auth\]' "$CONFIG_FILE" | grep 'service_role_key' | sed 's/.*"\(.*\)".*/\1/')
  fi
fi

if [ -z "$SUPABASE_SERVICE_ROLE_KEY" ]; then
  echo "Error: SUPABASE_SERVICE_ROLE_KEY not found"
  echo "Please set it as an environment variable or ensure it's in config.toml"
  exit 1
fi

# Call the setup function
echo "Calling setup-env function..."
RESPONSE=$(curl -s -X POST \
  "${SUPABASE_URL}/functions/v1/setup-env" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json")

# Check if successful
if echo "$RESPONSE" | grep -q '"success":true'; then
  echo "✅ Environment variables loaded successfully"
  echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
  exit 0
else
  echo "❌ Failed to load environment variables"
  echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
  exit 1
fi
