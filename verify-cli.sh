#!/usr/bin/env bash
# End-to-end check of the brew CLI install path:
#   working tree -> tarball -> local formula -> brew install ->
#   REST + MCP checks against a natively running server -> full cleanup.
# Success: prints "ALL CLI CHECKS PASS" and exits 0.
set -u
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

PORT=17977
BASE="http://127.0.0.1:${PORT}"
MCP="${BASE}/mcp/"
RUN_ID="$(date +%s)"
KEY="$(openssl rand -hex 24)"
AUTH="Authorization: Bearer $KEY"
TMPDATA="$(mktemp -d /tmp/vocald-verify-data.XXXXXX)"
TMP="$(mktemp -d)"
SERVER_PID=""

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
jval() { tr -d '\\' | grep -oE "\"$1\": *\"[^\"]+\"" | head -1 | sed -E 's/.*: *"//; s/"$//'; }

# Homebrew 6 only installs formulas from taps — use a throwaway local tap
# dir (no git, removed on cleanup). Never published anywhere.
TAP_DIR="$(brew --repository)/Library/Taps/vocald/homebrew-local"

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null
  brew uninstall vocald/local/vocald >/dev/null 2>&1 || brew uninstall vocald >/dev/null 2>&1
  rm -rf "$(dirname "$TAP_DIR")" "$TMPDATA" "$TMP"
  echo "── cleanup done (server stopped, formula uninstalled, tap + temp data removed)"
}
trap cleanup EXIT

# ── 1. tarball from the WORKING TREE (git archive would miss uncommitted work)
mkdir -p dist
tar czf dist/vocald.tar.gz \
  --exclude .git --exclude dist --exclude data --exclude .claude \
  --exclude output --exclude "__pycache__" --exclude ".smoke-*" \
  -C . .
SHA="$(shasum -a 256 dist/vocald.tar.gz | awk '{print $1}')"
sed -e "s|@TARBALL@|$PWD/dist/vocald.tar.gz|" -e "s|@SHA256@|$SHA|" \
  packaging/vocald.rb > dist/vocald.rb
ok "tarball + formula rendered (sha ${SHA:0:12}...)"

# ── 2. brew install via the throwaway local tap
mkdir -p "$TAP_DIR/Formula"
cp dist/vocald.rb "$TAP_DIR/Formula/vocald.rb"
BREW_RC=0
brew install vocald/local/vocald > "$TMP/brew-install.log" 2>&1 || BREW_RC=$?
CELLAR="$(brew --prefix)/Cellar/vocald"
if [ "$BREW_RC" -eq 0 ]; then
  ok "brew install vocald/local/vocald (local tap)"
elif [ -d "$CELLAR" ] && grep -q "Failed to fix install linkage" "$TMP/brew-install.log"; then
  # Known cosmetic failure: brew can't rewrite dylib IDs inside delocate-built
  # wheels (PyAV) — no load-command headroom. The dylibs resolve via
  # @loader_path and work un-relocated; we PROVE that below instead of
  # trusting it. Ensure the keg is linked since post-install aborted early.
  brew link --overwrite vocald >/dev/null 2>&1
  ok "brew install completed (tolerated known wheel-dylib relocation failure)"
  VENV_PY="$(echo "$CELLAR"/*/libexec/bin/python)"
  if "$VENV_PY" -c "import av, ctranslate2" 2>/dev/null; then
    ok "un-relocated PyAV + ctranslate2 dylibs import cleanly"
  else
    bad "PyAV import broken after relocation failure — real breakage"
    echo "RESULT: ${PASS} passed, ${FAIL} failed"; exit 1
  fi
else
  bad "brew install failed. Error lines:"
  grep -iE "^(Error|fatal)|error:" "$TMP/brew-install.log" | head -8
  echo "── last 40 log lines:"; tail -40 "$TMP/brew-install.log"
  echo "RESULT: ${PASS} passed, ${FAIL} failed"; exit 1
fi
command -v vocald-server >/dev/null && ok "vocald-server on PATH" || bad "vocald-server not on PATH"

# ── 3. start the server (authed) on a scratch data dir
VOICEBOX_API_KEY="$KEY" vocald-server --port "$PORT" --data-dir "$TMPDATA" \
  > "$TMP/server.log" 2>&1 &
SERVER_PID=$!

code=000
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "$AUTH" "$BASE/health" || true)
  [ "$code" = "200" ] && break
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 2
done
if [ "$code" = "200" ]; then
  ok "GET /health with key -> 200"
else
  bad "server never became healthy (last code $code)"; tail -30 "$TMP/server.log"
  echo "RESULT: ${PASS} passed, ${FAIL} failed"; exit 1
fi

# ── 4. auth
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/health")
[ "$code" = "401" ] && ok "GET /health without key -> 401" || bad "GET /health without key -> $code"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{}' "$MCP")
[ "$code" = "401" ] && ok "POST /mcp without key -> 401" || bad "POST /mcp without key -> $code"

# ── 5. profile create + list
PNAME="cli-$RUN_ID"
resp="$(curl -s --max-time 30 -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$PNAME\",\"voice_type\":\"preset\",\"preset_engine\":\"kokoro\",\"preset_voice_id\":\"af_bella\",\"language\":\"en\"}" \
  "$BASE/profiles")"
pid="$(echo "$resp" | jval id)"
[ -n "$pid" ] && ok "POST /profiles created '$PNAME'" || bad "POST /profiles failed: $(echo "$resp" | head -c 200)"
curl -s --max-time 10 -H "$AUTH" "$BASE/profiles" | grep -q "$PNAME" && ok "GET /profiles lists it" || bad "profile missing from list"

# ── 6. generate -> poll -> artifact (first run downloads the kokoro model)
gid="$(curl -s --max-time 60 -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"profile_id\":\"$pid\",\"text\":\"Brew install check, one two three.\",\"engine\":\"kokoro\"}" \
  "$BASE/generate" | jval id)"
[ -n "$gid" ] && ok "POST /generate accepted" || bad "POST /generate failed"
status=unknown
for _ in $(seq 1 300); do
  status="$(curl -s --max-time 10 -H "$AUTH" "$BASE/history/$gid" | jval status)"
  [ "$status" = "completed" ] || [ "$status" = "failed" ] && break
  sleep 1
done
if [ "$status" = "completed" ]; then
  curl -s --max-time 60 -H "$AUTH" -o "$TMP/cli.audio" "$BASE/audio/$gid"
  size=$(wc -c < "$TMP/cli.audio" | tr -d ' ')
  [ "$size" -gt 1000 ] && ok "GET /audio/$gid non-empty ($size bytes)" || bad "audio too small ($size)"
else
  bad "generation status=$status"; tail -15 "$TMP/server.log"
fi

# ── 7. MCP handshake + tools + generate
SID=""
init_resp="$(curl -s --max-time 30 -D "$TMP/h" -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify-cli","version":"0"}}}' \
  "$MCP")"
SID="$(sed -n 's/^[Mm][Cc][Pp]-[Ss]ession-[Ii][Dd]: *//p' "$TMP/h" | tr -d '\r' | head -1)"
[ -n "$SID" ] && echo "$init_resp" | grep -q '"serverInfo"' && ok "MCP initialize" || bad "MCP initialize failed"
mcp_call() {
  curl -s --max-time "${2:-60}" -X POST -H "$AUTH" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -H 'MCP-Protocol-Version: 2025-06-18' \
    ${SID:+-H "mcp-session-id: $SID"} -d "$1" "$MCP"
}
mcp_call '{"jsonrpc":"2.0","method":"notifications/initialized"}' 15 > /dev/null
tools="$(mcp_call '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' 30)"
for tool in create_profile generate; do
  echo "$tools" | grep -Eq "\"name\": *\"voicebox\.$tool\"" && ok "tools/list has voicebox.$tool" || bad "tools/list missing voicebox.$tool"
done
mcp_gen="$(mcp_call "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"voicebox.generate\",\"arguments\":{\"text\":\"MCP over brew works.\",\"profile\":\"$PNAME\"}}}" 300)"
audio_url="$(echo "$mcp_gen" | jval audio_url)"
if [ -n "$audio_url" ]; then
  curl -s --max-time 60 -H "$AUTH" -o "$TMP/mcp.audio" "$BASE$audio_url"
  size=$(wc -c < "$TMP/mcp.audio" | tr -d ' ')
  [ "$size" -gt 1000 ] && ok "MCP generate audio_url downloads ($size bytes)" || bad "MCP audio too small"
else
  bad "MCP generate no audio_url: $(echo "$mcp_gen" | head -c 200)"
fi

echo
echo "RESULT: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -eq 0 ]; then echo "ALL CLI CHECKS PASS"; exit 0; else exit 1; fi
