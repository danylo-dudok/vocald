"""Console entry point for the vocald server (brew / pip installs).

Same server as ``python -m backend.main`` but with install-friendly
defaults: loopback bind, the standard port, and a persistent per-user
data dir instead of ./data relative to whatever CWD happens to be.
"""

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="vocald-server",
        description="vocald — headless TTS/STT server (REST + /mcp)",
    )
    parser.add_argument(
        "--host",
        type=str,
        default="127.0.0.1",
        help="Host to bind to (use 0.0.0.0 for remote access — set VOICEBOX_API_KEY first)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=17493,
        help="Port to bind to (default: 17493)",
    )
    parser.add_argument(
        "--data-dir",
        type=str,
        default=str(Path.home() / ".voicebox"),
        help="Data directory for database, profiles, generated audio and models (default: ~/.voicebox)",
    )
    args = parser.parse_args()

    # Import lazily: --help must not pay the FastAPI/onnx import cost.
    from . import config, database

    config.set_data_dir(args.data_dir)
    database.init_db()

    import uvicorn

    uvicorn.run(
        "backend.main:app",
        host=args.host,
        port=args.port,
        reload=False,
    )


if __name__ == "__main__":
    main()
