#!/usr/bin/env bash
# Acceptance checks for the headless voicebox container.
# Usage: bash verify.sh          (builds + starts the compose stack, then checks)
# Success: prints "ALL CHECKS PASS" and exits 0.
set -u
cd "$(dirname "$0")"

COMPOSE="docker compose -f docker-compose.headless.yml"
PORT="${VOICEBOX_HOST_PORT:-17600}"
BASE="http://127.0.0.1:${PORT}"
MCP="${BASE}/mcp/"
RUN_ID="$(date +%s)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── API key: reuse the running container's, else generate one in-memory.
# ponytail: no .env written — this host forbids agent-written .env files;
# compose substitution reads the exported shell var instead.
KEY="$(docker inspect voicebox-headless --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^VOICEBOX_API_KEY=//p' | head -1)"
[ -n "$KEY" ] || KEY="$(openssl rand -hex 24)"
export VOICEBOX_API_KEY="$KEY"
AUTH="Authorization: Bearer $KEY"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
# extract "key":"value" from JSON (tolerates SSE framing and \" escapes)
jval() { tr -d '\\' | grep -oE "\"$1\": *\"[^\"]+\"" | head -1 | sed -E 's/.*: *"//; s/"$//'; }

echo "── docker compose up -d --build (first build resolves the python deps — slow)"
# --force-recreate: metrics must start from a fresh process, not inherit
# whatever models a previous verify run left loaded in a reused container.
$COMPOSE up -d --build --force-recreate || { echo "FATAL: compose up failed"; exit 1; }

echo "── waiting for /health"
code=000
for _ in $(seq 1 150); do
  code=$(curl -s -o "$TMP/health" -w '%{http_code}' --max-time 10 -H "$AUTH" "$BASE/health" || true)
  [ "$code" = "200" ] && break
  sleep 2
done
[ "$code" = "200" ] && ok "GET /health with key -> 200" || { bad "GET /health with key -> $code"; echo "FATAL: server never became healthy"; $COMPOSE logs --tail 50 voicebox; echo "RESULT: ${PASS} passed, ${FAIL} failed"; exit 1; }

# ── UI must not be served
root_body="$(curl -s --max-time 10 -H "$AUTH" "$BASE/")"
if echo "$root_body" | grep -qi "<html"; then bad "GET / serves the HTML app: $(echo "$root_body" | head -c 120)"; else ok "GET / does not serve the web UI"; fi
if echo "$root_body" | grep -q '"message"'; then ok "GET / returns JSON ($(echo "$root_body" | head -c 60)...)"; else bad "GET / body not the JSON API banner: $(echo "$root_body" | head -c 120)"; fi

# ── auth enforcement: no key / wrong key -> 401
for path in /health /profiles /generate/does-not-exist/status; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE$path")
  [ "$code" = "401" ] && ok "GET $path without key -> 401" || bad "GET $path without key -> $code (want 401)"
done
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{}' "$MCP")
[ "$code" = "401" ] && ok "POST /mcp without key -> 401" || bad "POST /mcp without key -> $code (want 401)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer wrong-key-$RUN_ID" "$BASE/profiles")
[ "$code" = "401" ] && ok "GET /profiles with wrong key -> 401" || bad "GET /profiles with wrong key -> $code (want 401)"

# ── REST: create + list profile (kokoro preset — no samples needed)
PNAME="verify-rest-$RUN_ID"
resp="$(curl -s --max-time 30 -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$PNAME\",\"voice_type\":\"preset\",\"preset_engine\":\"kokoro\",\"preset_voice_id\":\"af_bella\",\"language\":\"en\"}" \
  "$BASE/profiles")"
pid="$(echo "$resp" | jval id)"
[ -n "$pid" ] && ok "POST /profiles created '$PNAME' (id $pid)" || bad "POST /profiles failed: $(echo "$resp" | head -c 200)"
curl -s --max-time 10 -H "$AUTH" "$BASE/profiles" | grep -q "$PNAME" && ok "GET /profiles lists '$PNAME'" || bad "GET /profiles does not list '$PNAME'"

# ── REST: generate -> poll -> download artifact (timed for the metrics)
now_s() { python3 -c 'import time; print(f"{time.time():.2f}")'; }
# Untimed warmup so the timed run measures steady-state generation, not
# first-load model/session init — the baseline was captured warm too.
warm_gid="$(curl -s --max-time 60 -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"profile_id\":\"$pid\",\"text\":\"Warm up.\",\"engine\":\"kokoro\"}" "$BASE/generate" | jval id)"
for _ in $(seq 1 120); do
  ws="$(curl -s --max-time 10 -H "$AUTH" "$BASE/history/$warm_gid" | jval status)"
  [ "$ws" = "completed" ] || [ "$ws" = "failed" ] && break
  sleep 1
done
T0="$(now_s)"
gen_resp="$(curl -s --max-time 60 -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"profile_id\":\"$pid\",\"text\":\"Headless verification check, one two three.\",\"engine\":\"kokoro\"}" \
  "$BASE/generate")"
gid="$(echo "$gen_resp" | jval id)"
[ -n "$gid" ] && ok "POST /generate accepted (generation $gid)" || bad "POST /generate failed: $(echo "$gen_resp" | head -c 200)"
status="unknown"
if [ -n "$gid" ]; then
  echo "── waiting for generation (model is baked into the image; first load takes a few seconds)"
  for _ in $(seq 1 300); do
    hist="$(curl -s --max-time 10 -H "$AUTH" "$BASE/history/$gid")"
    status="$(echo "$hist" | jval status)"
    [ "$status" = "completed" ] || [ "$status" = "failed" ] && break
    sleep 1
  done
fi
GEN_WALL="$(python3 -c "import time; print(f'{time.time()-$T0:.1f}')")"
if [ "$status" = "completed" ]; then
  ok "generation completed"
  curl -s --max-time 60 -H "$AUTH" -o "$TMP/rest.audio" "$BASE/audio/$gid"
  size=$(wc -c < "$TMP/rest.audio" | tr -d ' ')
  [ "$size" -gt 1000 ] && ok "GET /audio/$gid -> non-empty audio ($size bytes)" || bad "GET /audio/$gid too small ($size bytes)"
else
  bad "generation did not complete (status=$status): $(echo "${hist:-}" | head -c 300)"
fi

# ── metrics: RSS with models loaded, image size, generation wall-time
RSS_MIB="$(docker stats --no-stream --format '{{.MemUsage}}' voicebox-headless 2>/dev/null | cut -d/ -f1 | awk '
  /GiB/ {printf "%.0f", $1*1024; next} /MiB/ {printf "%.0f", $1; next} /KiB/ {printf "%.0f", $1/1024; next} {print 0}')"
IMG_SHA="$(docker inspect voicebox-headless --format '{{.Image}}' 2>/dev/null)"
IMG_MB="$(docker image inspect "$IMG_SHA" --format '{{.Size}}' 2>/dev/null | awk '{printf "%.0f", $1/1000000}')"
echo "METRIC image_size_mb=$IMG_MB"
echo "METRIC gen_wall_s=$GEN_WALL"
echo "METRIC rss_after_gen_mib=$RSS_MIB"

# ── MCP: initialize session (Streamable HTTP)
mcp_call() {  # $1=json body  $2=curl max-time
  curl -s --max-time "${2:-60}" -X POST -H "$AUTH" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -H 'MCP-Protocol-Version: 2025-06-18' \
    ${SID:+-H "mcp-session-id: $SID"} -d "$1" "$MCP"
}
SID=""
init_resp="$(curl -s --max-time 30 -D "$TMP/mcp_headers" -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"0"}}}' \
  "$MCP")"
SID="$(sed -n 's/^[Mm][Cc][Pp]-[Ss]ession-[Ii][Dd]: *//p' "$TMP/mcp_headers" | tr -d '\r' | head -1)"
if [ -n "$SID" ] && echo "$init_resp" | grep -q '"serverInfo"'; then
  ok "MCP initialize handshake (session ${SID:0:8}...)"
else
  bad "MCP initialize failed: $(echo "$init_resp" | head -c 200)"
fi
mcp_call '{"jsonrpc":"2.0","method":"notifications/initialized"}' 15 > /dev/null

# ── MCP: tools/list must contain old + new tools
tools="$(mcp_call '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' 30)"
for tool in create_profile generate list_profiles speak; do
  # anchor on the tool's name field so a mention in another tool's
  # description can't false-pass this check
  echo "$tools" | grep -Eq "\"name\": *\"voicebox\.$tool\"" && ok "MCP tools/list contains voicebox.$tool" || bad "MCP tools/list missing voicebox.$tool: $(echo "$tools" | head -c 300)"
done

# ── MCP: create_profile tool
MNAME="verify-mcp-$RUN_ID"
mcp_create="$(mcp_call "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"voicebox.create_profile\",\"arguments\":{\"name\":\"$MNAME\",\"voice_type\":\"preset\",\"preset_engine\":\"kokoro\",\"preset_voice_id\":\"af_heart\",\"language\":\"en\"}}}" 60)"
mcp_pid="$(echo "$mcp_create" | jval id)"
if [ -n "$mcp_pid" ] && ! echo "$mcp_create" | grep -q '"isError": *true'; then
  ok "MCP create_profile created '$MNAME'"
else
  bad "MCP create_profile failed: $(echo "$mcp_create" | head -c 300)"
fi
curl -s --max-time 10 -H "$AUTH" "$BASE/profiles" | grep -q "$MNAME" && ok "GET /profiles lists MCP-created '$MNAME'" || bad "MCP-created profile '$MNAME' not in GET /profiles"

# ── MCP: generate tool -> audio_url -> download
mcp_gen="$(mcp_call "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"voicebox.generate\",\"arguments\":{\"text\":\"MCP generate returns an artifact, not playback.\",\"profile\":\"$MNAME\"}}}" 900)"
audio_url="$(echo "$mcp_gen" | jval audio_url)"
if [ -n "$audio_url" ]; then
  ok "MCP generate returned audio_url ($audio_url)"
  curl -s --max-time 60 -H "$AUTH" -o "$TMP/mcp.audio" "$BASE$audio_url"
  size=$(wc -c < "$TMP/mcp.audio" | tr -d ' ')
  [ "$size" -gt 1000 ] && ok "MCP audio_url downloads non-empty audio ($size bytes)" || bad "MCP audio_url download too small ($size bytes)"
else
  bad "MCP generate returned no audio_url: $(echo "$mcp_gen" | head -c 300)"
fi

# ── MCP: legacy speak tool with `profile` arg (podcast-skill contract)
mcp_speak="$(mcp_call "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"voicebox.speak\",\"arguments\":{\"text\":\"Speak still works.\",\"profile\":\"$PNAME\"}}}" 120)"
speak_gid="$(echo "$mcp_speak" | jval generation_id)"
[ -n "$speak_gid" ] && ok "MCP speak(profile=...) works (generation $speak_gid)" || bad "MCP speak failed: $(echo "$mcp_speak" | head -c 300)"

# ── MCP: list_profiles tool still works
mcp_list="$(mcp_call '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"voicebox.list_profiles","arguments":{}}}' 30)"
echo "$mcp_list" | grep -q "$PNAME" && ok "MCP list_profiles returns profiles" || bad "MCP list_profiles missing '$PNAME': $(echo "$mcp_list" | head -c 200)"

# ── transcribe roundtrip: /generate output -> whisper -> non-empty text.
# REST first (it auto-downloads the whisper model, replying "downloading"
# until ready), then the MCP tool (which requires the model cached).
if [ -s "$TMP/rest.audio" ]; then
  tr_text=""
  echo "── waiting for whisper (downloads on first transcribe)"
  for _ in $(seq 1 40); do
    tr_resp="$(curl -s --max-time 120 -X POST -H "$AUTH" -F "file=@$TMP/rest.audio;type=audio/wav" "$BASE/transcribe")"
    tr_text="$(echo "$tr_resp" | jval text)"
    [ -n "$tr_text" ] && break
    echo "$tr_resp" | grep -q '"downloading"' || break
    sleep 15
  done
  [ -n "$tr_text" ] && ok "REST /transcribe -> text: '$(echo "$tr_text" | head -c 60)'" || bad "REST /transcribe failed: $(echo "${tr_resp:-}" | head -c 200)"

  B64="$(base64 < "$TMP/rest.audio" | tr -d '\n')"
  printf '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"voicebox.transcribe","arguments":{"audio_base64":"%s"}}}' "$B64" > "$TMP/tr.json"
  mcp_tr="$(curl -s --max-time 300 -X POST -H "$AUTH" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -H 'MCP-Protocol-Version: 2025-06-18' \
    ${SID:+-H "mcp-session-id: $SID"} -d @"$TMP/tr.json" "$MCP")"
  # Real assertion: not an error AND the transcription contains a word we
  # actually spoke (jval alone matches the outer content wrapper — tautology).
  if echo "$mcp_tr" | grep -q '"isError": *false' && echo "$mcp_tr" | grep -qi "verification"; then
    ok "MCP transcribe -> transcription contains 'verification'"
  else
    bad "MCP transcribe failed or wrong text: $(echo "$mcp_tr" | head -c 300)"
  fi
else
  bad "transcribe roundtrip skipped: no generated audio to feed it"
fi

# ── budget checks (VERIFY_BUDGETS=1): final-state gates for the slim image
if [ "${VERIFY_BUDGETS:-0}" = "1" ]; then
  [ -n "$IMG_MB" ] && [ "$IMG_MB" -gt 0 ] && [ "$IMG_MB" -le 1500 ] \
    && ok "budget: image ${IMG_MB}MB <= 1500MB" || bad "budget: image ${IMG_MB:-?}MB > 1500MB (or unmeasured)"
  # Gate on the post-generation sample (the budget's definition). The
  # kokoro+whisper figure is informational — idle-unload reclaims it.
  [ -n "$RSS_MIB" ] && [ "$RSS_MIB" -gt 0 ] && [ "$RSS_MIB" -le 600 ] \
    && ok "budget: RSS ${RSS_MIB}MiB <= 600MiB after generation" || bad "budget: RSS ${RSS_MIB:-?}MiB > 600MiB (or unmeasured)"
  RSS_BOTH="$(docker stats --no-stream --format '{{.MemUsage}}' voicebox-headless 2>/dev/null | cut -d/ -f1 | awk '
    /GiB/ {printf "%.0f", $1*1024; next} /MiB/ {printf "%.0f", $1; next} /KiB/ {printf "%.0f", $1/1024; next} {print 0}')"
  echo "INFO: RSS with kokoro+whisper both loaded: ${RSS_BOTH}MiB (reclaim via VOICEBOX_IDLE_UNLOAD_S)"
  # Positive control first so daemon/image errors can't fake "torch absent"
  if ! docker run --rm --entrypoint python "$IMG_SHA" -c "print(1)" >/dev/null 2>&1; then
    bad "budget: cannot run python in the image — torch check inconclusive"
  elif docker run --rm --entrypoint python "$IMG_SHA" -c "import torch" >/dev/null 2>&1; then
    bad "budget: torch is still importable in the image"
  else
    ok "budget: torch absent from the image"
  fi
  if [ -f baseline.txt ]; then
    BASE_WALL="$(sed -n 's/^gen_wall_s=//p' baseline.txt | head -1)"
    if [ -n "$BASE_WALL" ] && python3 -c "exit(0 if $GEN_WALL <= $BASE_WALL else 1)"; then
      ok "budget: gen wall ${GEN_WALL}s <= baseline ${BASE_WALL}s"
    else
      bad "budget: gen wall ${GEN_WALL}s > baseline ${BASE_WALL:-?}s"
    fi
  else
    bad "budget: baseline.txt missing — capture it from the pre-optimization image first"
  fi
fi

if [ -f baseline.txt ]; then
  echo "── baseline (pre-optimization):"
  sed 's/^/   /' baseline.txt
  echo "── current: image=${IMG_MB}MB rss=${RSS_MIB}MiB gen_wall=${GEN_WALL}s"
fi

echo
echo "RESULT: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -eq 0 ]; then echo "ALL CHECKS PASS"; exit 0; else exit 1; fi
