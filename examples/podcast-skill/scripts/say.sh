#!/usr/bin/env bash
# Render ONE podcast turn with vocald/Voicebox and play it, blocking until it finishes.
# Call once per turn IN ORDER -> clean, non-overlapping playback.
# Usage: say.sh <profile> <text>
#
# Works against either backend:
#  - vocald (github.com/danylo-dudok/vocald), local or remote — set
#    VOICEBOX_API (e.g. http://127.0.0.1:17493 or https://host) and, if the
#    server enforces auth, VOICEBOX_API_KEY (sent as a bearer).
#  - the Voicebox desktop app (no key needed).
#
# Encodes the quirks found the hard way:
#  - live `speak` is async and overlaps -> render to a file instead
#  - kokoro presets (Bella/Alloy) need engine=kokoro on servers whose
#    /generate defaults to another engine (vocald already defaults to kokoro)
#  - /generate's audio_path is server-local -> download the clip via GET /audio/{id}
#  - no ffmpeg required -> afplay each clip; afplay BLOCKS, so ordering is free
set -euo pipefail

API="${VOICEBOX_API:-http://127.0.0.1:17493}"
ENGINE="${VOICEBOX_ENGINE:-kokoro}"
KEY="${VOICEBOX_API_KEY:-}"
auth=()
[ -n "$KEY" ] && auth=(-H "Authorization: Bearer $KEY")
profile="${1:?usage: say.sh <profile> <text>}"
text="${2:?usage: say.sh <profile> <text>}"

# 1. render (JSON built via python3 so quotes/apostrophes in the text are escaped safely)
payload=$(python3 -c 'import json,sys; print(json.dumps({"text":sys.argv[1],"profile":sys.argv[2],"engine":sys.argv[3]}))' "$text" "$profile" "$ENGINE")
id=$(curl -fsS -X POST "$API/generate" ${auth[@]+"${auth[@]}"} -H 'Content-Type: application/json' -d "$payload" \
     | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("id") or d.get("generation_id") or "")')
[ -n "$id" ] || { echo "say.sh: no generation id (server running at $API? engine=$ENGINE valid for '$profile'?)" >&2; exit 1; }

# 2. download when ready. /audio/{id} 404s until the clip exists; retry ~30s.
#    (The /generate/{id}/status stream is SSE, not JSON — polling the download is simpler.)
out="/tmp/podcast_${id}.wav"
for _ in $(seq 1 60); do
  if curl -fsS ${auth[@]+"${auth[@]}"} -o "$out" "$API/audio/$id" 2>/dev/null && [ "$(wc -c <"$out")" -gt 1024 ]; then
    # 3. play — afplay blocks until the clip ends, so the next turn starts after this one
    afplay "$out"
    rm -f "$out"
    exit 0
  fi
  sleep 0.5
done
echo "say.sh: audio for $id never became available at $API/audio/$id" >&2
rm -f "$out"
exit 1
