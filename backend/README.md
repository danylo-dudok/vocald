# backend

The vocald server: a FastAPI app exposing REST + MCP for Kokoro TTS
(onnxruntime) and Whisper STT (faster-whisper). Torch-free.

## Layout

```
backend/
├── app.py            # app factory, auth middleware, lifespan, idle unload
├── main.py           # uvicorn entry (backend.main:app)
├── cli.py            # vocald-server console script (pip/brew installs)
├── config.py         # data-dir resolution
├── models.py         # pydantic request/response schemas
├── routes/           # REST endpoints (profiles, generations, audio, transcription, …)
├── services/         # business logic (profiles, generation queue, history, …)
├── backends/         # engine layer: kokoro_backend (onnx), fasterwhisper_backend
├── mcp_server/       # FastMCP server mounted at /mcp
├── database/         # SQLAlchemy models + sqlite session
└── tests/            # pytest suite (not shipped in the docker image)
```

## Run for development

```sh
pip install -e .            # from the repo root
vocald-server               # 127.0.0.1:17493, data in ~/.voicebox
# or: uvicorn backend.main:app --port 17493
```

Set `VOICEBOX_API_KEY` to exercise the auth path; unset means open loopback
dev mode. `pytest backend/tests`, lint config in `backend/pyproject.toml`
(ruff).
