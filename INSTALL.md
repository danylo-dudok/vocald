# vocald — install

Headless TTS/STT server (REST + MCP at `/mcp`). Kokoro-82M on onnxruntime
for synthesis, faster-whisper for transcription. One codebase, two install
paths.

## Docker (linux/macOS hosts, isolated)

```sh
export VOICEBOX_API_KEY=$(openssl rand -hex 24)
docker compose -f docker-compose.headless.yml up -d --build
curl -H "Authorization: Bearer $VOICEBOX_API_KEY" http://127.0.0.1:17600/health
```

The kokoro model is baked into the image; whisper downloads into a named
volume on first transcription. Auth is fail-closed: the container refuses
to start without a key, and every route (including `/mcp`) returns 401
without `Authorization: Bearer <key>`.

## Brew (native macOS CLI)

```sh
bash verify-cli.sh        # builds dist/vocald.rb from the working tree and tests it
# or manually (Homebrew requires formulas to live in a tap):
tar czf dist/vocald.tar.gz --exclude .git --exclude dist -C . .
sed -e "s|@TARBALL@|$PWD/dist/vocald.tar.gz|" \
    -e "s|@SHA256@|$(shasum -a 256 dist/vocald.tar.gz | awk '{print $1}')|" \
    packaging/vocald.rb > dist/vocald.rb
mkdir -p "$(brew --repository)/Library/Taps/vocald/homebrew-local/Formula"
cp dist/vocald.rb "$(brew --repository)/Library/Taps/vocald/homebrew-local/Formula/"
brew install vocald/local/vocald

vocald-server                    # loopback dev mode: no auth, 127.0.0.1:17493
VOICEBOX_API_KEY=... vocald-server --host 0.0.0.0   # bearer enforced everywhere
```

Model files (~115 MB) download to the data dir on first generation.
`voicebox-server` is an alias of `vocald-server`.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `VOICEBOX_API_KEY` | unset | Bearer key. Set ⇒ every REST route + `/mcp` require it. Unset (native) ⇒ open loopback dev mode. The docker image sets `VOICEBOX_REQUIRE_AUTH=1`, so unset there ⇒ deny all. |
| `VOICEBOX_HOST_PORT` | `17600` | Docker only: host port the container publishes on 127.0.0.1. |
| `VOICEBOX_IDLE_UNLOAD_S` | `0` (off) | Unload TTS/STT/LLM models after N seconds without authed requests. |
| `VOICEBOX_ONNX_THREADS` | `2` | onnxruntime intra-op threads for kokoro. |
| `VOICEBOX_WHISPER_COMPUTE` | `int8` | faster-whisper compute type. |
| `VOICEBOX_KOKORO_ONNX_MODEL` / `_VOICES` | data dir | Explicit kokoro model/voices paths (docker points them at baked files). |
| `--data-dir` | `~/.voicebox` (CLI), `/app/data` (docker) | DB, profiles, generated audio, downloaded models. |

## MCP

Endpoint: `http://host:port/mcp` (Streamable HTTP), header
`Authorization: Bearer <key>`. Tools: `voicebox.list_profiles`,
`voicebox.create_profile`, `voicebox.generate` (returns `audio_url`),
`voicebox.speak`, `voicebox.transcribe`, `voicebox.list_captures`.

## Slim-image limits (both install paths)

Voice cloning engines and the LLM personality feature are not included —
kokoro preset voices only; `personality=true` returns a clear error.
Compressed-audio (mp3/m4a) story imports need ffmpeg, which the docker
image no longer ships; transcription of compressed audio still works
(PyAV is bundled with faster-whisper).
