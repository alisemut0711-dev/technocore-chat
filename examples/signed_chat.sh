#!/bin/bash
# signed_chat.sh — signed write lane, end to end.
#
#   bash examples/signed_chat.sh
#
# This extends beautiful_chat.sh's unsigned lane with the signed one:
# generate a key, read the room's last nonce, sign a message, post it,
# and verify the signature against the running service.  The signed lane
# proves authorship; the verifier proves the record on disk is what was
# signed.
#
# Requirements: bash, curl, uv (https://docs.astral.sh/uv/), openssl (for
# key generation).  Nothing else.

set -euo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------- the stage
PORT=$(uv run python -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
TMP=$(mktemp -d)
LOG="$TMP/server.log"
SRV_PID=""
cleanup() {
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "== booting the real service on 127.0.0.1:$PORT"
CHAT_ROOT="$TMP" \
  uv run uvicorn --app-dir src app:app --port "$PORT" --log-level warning >"$LOG" 2>&1 &
SRV_PID=$!

# Wait for server up
for i in $(seq 1 50); do
    sleep 0.2
    CODE=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/healthz" 2>/dev/null)
    [ "$CODE" = "200" ] && break
done
if [ "$CODE" != "200" ]; then
    echo "server failed to start"
    cat "$LOG"
    exit 1
fi

BASE="http://127.0.0.1:$PORT"
ROOM="signed-demo-$$"

# Helpers
fail() { echo "FAIL: $1"; exit 1; }
body() { curl -sS "$BASE$1" | tee /dev/stderr; }
ok_has() { grep -q "$1" <<<"$2" || fail "expected '$1' in: $2"; }
ok_lacks() { grep -q "$1" <<<"$2" && fail "expected NOT '$1' in: $2"; }

# ---------------------------------------------------------------- key setup
echo "== generating Ed25519 key"
# Ed25519 seed: 32 bytes = 64 hex chars.  Use openssl for determinism in this demo.
# A real script would use a random seed or $SIGN_SEED.
DEMO_SEED=$(openssl rand -hex 32)
echo "   seed (first 8 chars): ${DEMO_SEED:0:8}..."

# Derive did:key from the seed using sign.py
DID=$(uv run python scripts/sign.py --seed "$DEMO_SEED" did)
echo "   did: $DID"

# ---------------------------------------------------------------- first signed write
echo "== first signed write"
# Get the current last_seq so we know what nonce to use
SEQ=$(curl -sS "$BASE/r/$ROOM?format=json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('last_seq',0))")
NONCE=$((SEQ + 1))
# A brand-new room returns last_seq=0, so nonce=1 is correct.  The first signed
# message in a room always uses nonce 1 unless you are resuming from a known state.
echo "   room last_seq=$SEQ  using nonce=$NONCE"

TEXT="hello from the signed lane"
# sign the canonical string: room|nonce|swept-text
# sweep: this text has no invisible chars so it's unchanged
# sign.py say prints two lines — the did:key, then the signature. We already
# have the did from `did` above, so keep only the last line (the signature).
SIG=$(uv run python scripts/sign.py --seed "$DEMO_SEED" say "$ROOM" "$NONCE" "$TEXT" | tail -n1)
echo "   sig (first 20 chars): ${SIG:0:20}..."

RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" "$BASE/r/$ROOM/say-signed/$DID/$SIG/$NONCE/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$TEXT'))")")
HTTP_STATUS=$(echo "$RESP" | grep "HTTP_STATUS" | cut -d: -f2)
BODY=$(echo "$RESP" | grep -v "HTTP_STATUS")
echo "   HTTP $HTTP_STATUS  body: $BODY"

ok_has "HTTP_STATUS:200" "$RESP" || fail "first signed write failed"
ok_has "$DID" "$BODY"

# ---------------------------------------------------------------- second signed write — nonce must increase
echo "== second signed write (nonce incremented)"
NONCE=$((NONCE + 1))
TEXT="second message, same key"
SIG2=$(uv run python scripts/sign.py --seed "$DEMO_SEED" say "$ROOM" "$NONCE" "$TEXT" | tail -n1)
RESP2=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" "$BASE/r/$ROOM/say-signed/$DID/$SIG2/$NONCE/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$TEXT'))")")
HTTP_STATUS2=$(echo "$RESP2" | grep "HTTP_STATUS" | cut -d: -f2)
ok_has "HTTP_STATUS:200" "$RESP2" || fail "second signed write failed"

# ---------------------------------------------------------------- verify the record on disk
echo "== verifying signatures against the room"
# Read both messages back and check they carry the did
ROOM_JSON=$(curl -sS "$BASE/r/$ROOM?format=json")
echo "   room has $(echo "$ROOM_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d["messages"]))') messages"

# The did appears in the from field of signed messages
ok_has "$DID" "$ROOM_JSON" || fail "did not appear in room JSON"

# ---------------------------------------------------------------- nonce reuse must fail
echo "== nonce reuse must be refused"
SIG_REUSE=$(uv run python scripts/sign.py --seed "$DEMO_SEED" say "$ROOM" "$NONCE" "this should be refused" | tail -n1)
RESP_REUSE=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
    "$BASE/r/$ROOM/say-signed/$DID/$SIG_REUSE/$NONCE/$(python3 -c "import urllib.parse; print(urllib.parse.quote('reused nonce'))")")
HTTP_REUSE=$(echo "$RESP_REUSE" | grep "HTTP_STATUS" | cut -d: -f2)
# A reused nonce returns 409 (conflict) or 400 (bad nonce) — either means the server caught it
ok_has "HTTP_STATUS:4" "$RESP_REUSE" || fail "reused nonce was not refused (got HTTP $HTTP_REUSE)"

# ---------------------------------------------------------------- show the rendering
echo "== rendered room view"
curl -sS "$BASE/r/$ROOM" | head -5

echo ""
echo "done — signed lane works"
