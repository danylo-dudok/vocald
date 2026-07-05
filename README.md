# vocald

Headless text-to-speech / speech-to-text server with a REST API and a native
[MCP](https://modelcontextprotocol.io) endpoint. No GUI, no GPU, no torch —
built to give AI agents and scripts a voice.

- **TTS**: [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) (50 preset voices, 8 languages) on onnxruntime, int8
- **STT**: Whisper via [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (CTranslate2)
- **API**: REST + MCP (Streamable HTTP at `/mcp`) — same tools either way
- **Auth**: single bearer key over every route including `/mcp`; the docker image fails closed
- **Footprint**: 1.2 GB image, ~350 MiB RSS after a generation (the torch-based
  ancestor was 7.4 GB / 2.2 GiB)

## Install

### Docker

```sh
export VOICEBOX_API_KEY=$(openssl rand -hex 24)
docker compose -f docker-compose.headless.yml up -d --build
curl -H "Authorization: Bearer $VOICEBOX_API_KEY" http://127.0.0.1:17600/health
```

The Kokoro model is baked into the image (no first-request download); Whisper
downloads into a named volume on first transcription. Without a key the
container refuses to serve anything — deny by default.

### Homebrew (macOS, native)

```sh
bash verify-cli.sh   # builds + installs the formula from your working tree, tests it end to end
# or step by step — see INSTALL.md
vocald-server        # 127.0.0.1:17493, open loopback dev mode
VOICEBOX_API_KEY=$(openssl rand -hex 24) vocald-server --host 0.0.0.0
```

Data lives in `~/.voicebox`; model files (~115 MB) download on first
generation. See [INSTALL.md](INSTALL.md) for the full environment reference.

## API in 30 seconds

```sh
AUTH="Authorization: Bearer $VOICEBOX_API_KEY"

# create a preset voice
curl -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"name":"Bella","voice_type":"preset","preset_engine":"kokoro","preset_voice_id":"af_bella"}' \
  http://127.0.0.1:17600/profiles

# synthesize, then download the artifact
curl -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"profile_id":"<id>","text":"Hello from vocald."}' \
  http://127.0.0.1:17600/generate          # -> {"id": ...}
curl -H "$AUTH" -o hello.wav http://127.0.0.1:17600/audio/<id>

# transcribe
curl -X POST -H "$AUTH" -F file=@hello.wav http://127.0.0.1:17600/transcribe
```

Preset voice ids: `GET /profiles/presets/kokoro`.

## MCP

Point any MCP client (Claude Code, Cursor, …) at `http://host:port/mcp` with
the `Authorization: Bearer <key>` header. Tools:

| Tool | What it does |
|---|---|
| `voicebox.list_profiles` | List voices |
| `voicebox.create_profile` | Create a preset voice (`af_bella`, `am_adam`, …) |
| `voicebox.generate` | Synthesize and return `{generation_id, audio_url}` — download with the same bearer |
| `voicebox.speak` | Fire-and-forget synthesis (returns a poll URL) |
| `voicebox.transcribe` | Audio (base64) → text |
| `voicebox.list_captures` | Recent recordings with transcripts |

The tool names keep the `voicebox.` prefix for compatibility with existing
clients and skills.

## Podcast skill

vocald pairs with a [Claude Code](https://claude.com/claude-code) skill that
turns any file, URL, or topic into a NotebookLM-style two-host audio
conversation — the skill writes the dialogue, then voices each turn through
vocald's API and plays it locally. See
[`examples/podcast-skill/`](examples/podcast-skill/) for the skill definition;
drop it into `~/.claude/skills/podcast/` and run `/podcast <source>`.

## Limits, by design

Kokoro preset voices only — the voice-cloning engines and the LLM
"personality" rewrite from the upstream project are not included in this slim
build (requests degrade with clear errors, never crashes). If you need
cloning, use the upstream desktop app.

## Responsible use

Synthetic speech can be misused. See [RESPONSIBLE_USE.md](RESPONSIBLE_USE.md)
— in short: only voices you own or have permission to use, no impersonation,
no fraud.

## Credits & license

vocald is a headless, torch-free hard fork of
[jamiepine/voicebox](https://github.com/jamiepine/voicebox) (forked at
`b542768`), which provides the desktop app this server grew out of. MIT
license — see [LICENSE](LICENSE).
