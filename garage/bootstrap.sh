#!/bin/sh
# One-shot cluster bootstrap for Garage — same role as ZITADEL's steps.yaml self-bootstrap, but
# Garage has no equivalent declarative first-boot mechanism, so this drives it externally via the
# admin HTTP API (verified live against v1.2.0). Every step checks current state first so re-running
# this container after the volumes already exist is a safe no-op.
set -eu

BASE="${GARAGE_ADMIN_BASE_URL:-http://garage:3903}"
AUTH="Authorization: Bearer ${GARAGE_ADMIN_TOKEN}"
BUCKET="grg-media"

# Runs one admin-API call; leaves the body in $BODY and the HTTP status in $CODE.
call() {
  method="$1"; path="$2"; data="${3:-}"
  if [ -n "$data" ]; then
    resp=$(curl -sS -w '\n%{http_code}' -X "$method" -H "$AUTH" -H "Content-Type: application/json" -d "$data" "$BASE$path")
  else
    resp=$(curl -sS -w '\n%{http_code}' -X "$method" -H "$AUTH" "$BASE$path")
  fi
  CODE=$(printf '%s' "$resp" | tail -n1)
  BODY=$(printf '%s' "$resp" | sed '$d')
}

json_field() {
  # json_field <field-name> <body> — first "name": "value" match, hex/word chars only (every
  # field this script reads is an id, a hex secret, or a small integer).
  printf '%s' "$2" | grep -oE "\"$1\": *\"?[A-Za-z0-9]+" | head -1 | grep -oE '[A-Za-z0-9]+$'
}

echo "garage-init: waiting for admin API..."
# /health (unversioned) is deliberately unauthenticated — for liveness probes; /v1/health requires
# the admin bearer token, which is fine everywhere else in this script but wrong for "is it up yet".
until curl -sf "$BASE/health" >/dev/null 2>&1; do sleep 2; done

echo "garage-init: checking cluster layout..."
call GET /v1/status
LAYOUT_VERSION=$(json_field layoutVersion "$BODY")
NODE_ID=$(json_field node "$BODY")

if [ "$LAYOUT_VERSION" = "0" ]; then
  echo "garage-init: no layout yet — assigning single-node layout for $NODE_ID..."
  call POST /v1/layout "[{\"id\":\"$NODE_ID\",\"zone\":\"dc1\",\"capacity\":100000000000,\"tags\":[]}]"
  call POST /v1/layout/apply "{\"version\":1}"
  echo "garage-init: layout applied."
else
  echo "garage-init: layout already applied (version $LAYOUT_VERSION), skipping."
fi

echo "garage-init: ensuring bucket '$BUCKET' exists..."
call GET "/v1/bucket?globalAlias=$BUCKET"
if [ "$CODE" = "404" ]; then
  call POST /v1/bucket "{\"globalAlias\":\"$BUCKET\"}"
  echo "garage-init: bucket created."
else
  echo "garage-init: bucket already exists."
fi
BUCKET_ID=$(json_field id "$BODY")

echo "garage-init: ensuring the backend access key is imported..."
call GET "/v1/key?id=${GARAGE_ACCESS_KEY_ID}"
if [ "$CODE" = "404" ]; then
  call POST /v1/key/import "{\"accessKeyId\":\"${GARAGE_ACCESS_KEY_ID}\",\"secretAccessKey\":\"${GARAGE_SECRET_ACCESS_KEY}\",\"name\":\"grg-backend\"}"
  echo "garage-init: key imported."
else
  echo "garage-init: key already imported."
fi

echo "garage-init: granting read/write on '$BUCKET' to the backend key..."
call POST /v1/bucket/allow "{\"bucketId\":\"$BUCKET_ID\",\"accessKeyId\":\"${GARAGE_ACCESS_KEY_ID}\",\"permissions\":{\"read\":true,\"write\":true,\"owner\":false}}"

echo "garage-init: bootstrap complete."
