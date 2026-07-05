"""FastAPI application factory, middleware, and lifecycle events."""

import asyncio
import logging
import os
import re
import subprocess
import sys
from contextlib import asynccontextmanager
from pathlib import Path


class ColoredFormatter(logging.Formatter):
    """Custom formatter to add colors matching uvicorn's style."""

    COLORS = {
        "DEBUG": "\033[36m",  # Cyan
        "INFO": "\033[32m",  # Green
        "WARNING": "\033[33m",  # Yellow
        "ERROR": "\033[31m",  # Red
        "CRITICAL": "\033[35m",  # Magenta
    }
    RESET = "\033[0m"

    def format(self, record):
        log_color = self.COLORS.get(record.levelname, self.RESET)
        record.levelname = f"{log_color}{record.levelname}{self.RESET}"
        return super().format(record)


# Configure logging to match uvicorn's format with colors
handler = logging.StreamHandler(sys.stderr)
handler.setFormatter(ColoredFormatter("%(levelname)s:     %(message)s"))
logging.basicConfig(
    level=logging.INFO,
    handlers=[handler],
)

logger = logging.getLogger(__name__)

# AMD GPU environment variables must be set before torch import
# Only set HSA_OVERRIDE_GFX_VERSION for older GPUs that need it.
# RDNA 3+ (gfx1100+) and RDNA 4 (gfx1200+) are natively supported by ROCm
# and the override can cause suboptimal performance or errors.
if not os.environ.get("HSA_OVERRIDE_GFX_VERSION"):
    try:
        result = subprocess.run(
            ["rocminfo"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            # Collect all GPUs found in rocminfo output
            gfx_versions = []
            for line in result.stdout.splitlines():
                line_lower = line.lower()
                if "gfx" in line_lower:
                    match = re.search(r"(gfx\d+)", line_lower)
                    if match:
                        gfx_versions.append(match.group(1))

            if gfx_versions:
                # Check if any GPU needs the override (RDNA 2 and older)
                # Use the oldest GPU (lowest gfx number) for the decision
                try:
                    gfx_nums = []
                    for v in gfx_versions:
                        m = re.search(r"\d+", v)
                        if m:
                            gfx_nums.append(int(m.group()))
                    if gfx_nums:
                        oldest_num = min(gfx_nums)
                        oldest_gfx = gfx_versions[gfx_nums.index(oldest_num)]
                        if oldest_num < 1100:
                            os.environ["HSA_OVERRIDE_GFX_VERSION"] = "10.3.0"
                            logger.info(
                                "AMD GPU detected (%s), setting HSA_OVERRIDE_GFX_VERSION=10.3.0 for compatibility. All GPUs: %s",
                                oldest_gfx,
                                ", ".join(gfx_versions),
                            )
                        else:
                            logger.info(
                                "AMD GPU detected (%s), native ROCm support available, skipping HSA_OVERRIDE_GFX_VERSION. All GPUs: %s",
                                oldest_gfx,
                                ", ".join(gfx_versions),
                            )
                except (ValueError, AttributeError) as e:
                    logger.info("Could not parse GPU version from rocminfo output: %s", e)
    except (FileNotFoundError, subprocess.TimeoutExpired, Exception) as e:
        logger.info(
            "Could not detect AMD GPU via rocminfo, skipping automatic HSA_OVERRIDE_GFX_VERSION configuration: %s",
            e,
        )
if not os.environ.get("MIOPEN_LOG_LEVEL"):
    os.environ["MIOPEN_LOG_LEVEL"] = "4"

import secrets
import time

try:
    import torch
except ImportError:  # slim image: onnx/ctranslate2 inference, no torch
    torch = None

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from urllib.parse import quote

from . import __version__, config, database
from .services import tts, transcribe, llm
from .database import get_db
from .utils.platform_detect import get_backend_type
from .utils.progress import get_progress_manager
from .services.task_queue import create_background_task, init_queue
from .routes import register_routers


def safe_content_disposition(disposition_type: str, filename: str) -> str:
    """Build a Content-Disposition header safe for non-ASCII filenames.

    Uses RFC 5987 ``filename*`` parameter so browsers can decode UTF-8
    filenames while the ``filename`` fallback stays ASCII-only.
    """
    ascii_name = "".join(c for c in filename if c.isascii() and (c.isalnum() or c in " -_.")).strip() or "download"
    utf8_name = quote(filename, safe="")
    return f"{disposition_type}; filename=\"{ascii_name}\"; filename*=UTF-8''{utf8_name}"


# Last authed request (monotonic). Drives VOICEBOX_IDLE_UNLOAD_S; /health is
# excluded so the docker healthcheck doesn't hold models in memory forever.
_last_request_ts = time.monotonic()


def _touch_activity(scope) -> None:
    global _last_request_ts
    if scope["type"] == "http" and scope.get("path") != "/health":
        _last_request_ts = time.monotonic()


class ApiKeyAuthMiddleware:
    """Bearer-key gate over every route, including the /mcp mount.

    Enforced when VOICEBOX_API_KEY is set, or unconditionally when
    VOICEBOX_REQUIRE_AUTH=1 (the headless image bakes the latter in, so a
    missing key fails closed instead of exposing an open server). With
    neither set (desktop / dev), requests pass through untouched.

    Pure ASGI on purpose: BaseHTTPMiddleware buffers streaming bodies,
    which breaks the SSE status endpoint and MCP Streamable HTTP.
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] not in ("http", "websocket"):
            return await self.app(scope, receive, send)
        # ponytail: env read per request — keeps key rotation a restart-free
        # `docker compose up -d` concern and the middleware trivially testable
        key = os.environ.get("VOICEBOX_API_KEY", "")
        if not key and os.environ.get("VOICEBOX_REQUIRE_AUTH", "").lower() not in ("1", "true"):
            _touch_activity(scope)
            return await self.app(scope, receive, send)

        # Compare as bytes: a non-UTF-8 or non-ASCII header must yield a
        # clean 401, not a decode/TypeError 500.
        auth = next(
            (v for k, v in scope.get("headers", []) if k == b"authorization"),
            b"",
        )
        if key and secrets.compare_digest(auth, f"Bearer {key}".encode()):
            _touch_activity(scope)
            return await self.app(scope, receive, send)

        if scope["type"] == "websocket":
            await send({"type": "websocket.close", "code": 1008})
            return
        response = JSONResponse(
            {"detail": "Unauthorized"},
            status_code=401,
            headers={"WWW-Authenticate": "Bearer"},
        )
        await response(scope, receive, send)


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""
    from .mcp_server.server import build_mcp_server, compose_lifespan
    from .mcp_server.context import ClientIdMiddleware

    # Build the MCP app up-front so we can wire its lifespan into FastAPI's —
    # FastMCP's Streamable HTTP transport only works if its session manager
    # runs inside the parent ASGI lifespan.
    mcp = build_mcp_server()
    mcp_app = mcp.http_app(path="/", transport="http")

    @asynccontextmanager
    async def voicebox_lifespan(app: FastAPI):
        await _run_startup(app)
        try:
            yield
        finally:
            # Paired with _run_startup via try/finally: runs whether or
            # not the nested MCP lifespan entered cleanly, so a partial
            # startup still unloads whatever models were loaded.
            await _run_shutdown()

    # compose_lifespan enters factories in order (voicebox startup →
    # MCP startup) and exits in LIFO (MCP teardown first → models
    # unload last). That ordering matters on shutdown: FastMCP's
    # __aexit__ cancels in-flight session tasks, and we want that to
    # happen *before* _run_shutdown yanks the TTS / Whisper / LLM
    # models out from under any MCP request that was still generating.
    lifespan = compose_lifespan(voicebox_lifespan, mcp_app.router.lifespan_context)

    application = FastAPI(
        title="voicebox API",
        description="Headless Kokoro TTS API with MCP endpoint",
        version=__version__,
        lifespan=lifespan,
    )

    _configure_cors(application)
    application.add_middleware(ClientIdMiddleware)
    # Added last => outermost: auth runs before CORS, routes, and /mcp.
    application.add_middleware(ApiKeyAuthMiddleware)
    register_routers(application)
    application.mount("/mcp", mcp_app)
    logger.info("MCP: mounted at /mcp")

    return application


def _configure_cors(application: FastAPI) -> None:
    """CORS is opt-in: this headless build ships no browser client.

    Set VOICEBOX_CORS_ORIGINS (comma-separated) to allow browser callers;
    with it unset no CORS middleware is installed at all.
    """
    origins = [
        o.strip()
        for o in os.environ.get("VOICEBOX_CORS_ORIGINS", "").split(",")
        if o.strip()
    ]
    if not origins:
        return

    application.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )


def _get_gpu_status() -> str:
    """Return a human-readable string describing GPU availability."""
    backend_type = get_backend_type()
    if torch is None:
        if backend_type == "mlx":
            return "Metal (Apple Silicon via MLX)"
        return "None (CPU-only slim build, no torch)"
    if torch.cuda.is_available():
        from .backends.base import check_cuda_compatibility

        device_name = torch.cuda.get_device_name(0)
        compatible, _warning = check_cuda_compatibility()
        is_rocm = hasattr(torch.version, "hip") and torch.version.hip is not None
        if is_rocm:
            label = f"ROCm ({device_name})"
        else:
            label = f"CUDA ({device_name})"
        if not compatible:
            label += " [UNSUPPORTED - see logs]"
        return label
    elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        return "MPS (Apple Silicon)"
    elif backend_type == "mlx":
        return "Metal (Apple Silicon via MLX)"

    # Intel XPU (Arc / Data Center) via IPEX
    try:
        import intel_extension_for_pytorch  # noqa: F401

        if hasattr(torch, "xpu") and torch.xpu.is_available():
            try:
                xpu_name = torch.xpu.get_device_name(0)
            except Exception:
                xpu_name = "Intel GPU"
            return f"XPU ({xpu_name})"
    except ImportError:
        pass

    return "None (CPU only)"


async def _run_startup(application: FastAPI) -> None:
    """Database init, warnings, model-cache prep. Runs on lifespan entry."""
    import platform
    import sys

    logger.info("Voicebox v%s starting up", __version__)
    logger.info(
        "Python %s on %s %s (%s)",
        sys.version.split()[0],
        platform.system(),
        platform.release(),
        platform.machine(),
    )

    database.init_db()

    from .database.session import _db_path

    logger.info("Database: %s", _db_path)
    logger.info("Data directory: %s", config.get_data_dir())

    init_queue()

    # Mark stale "generating" records as failed -- leftovers from a killed process
    from sqlalchemy import text as sa_text

    db = next(get_db())
    try:
        result = db.execute(
            sa_text(
                "UPDATE generations SET status = 'failed', "
                "error = 'Server was shut down during generation' "
                "WHERE status IN ('generating', 'loading_model')"
            )
        )
        if result.rowcount > 0:
            logger.info("Marked %d stale generation(s) as failed", result.rowcount)

        from .database import VoiceProfile as DBVoiceProfile, Generation as DBGeneration

        profile_count = db.query(DBVoiceProfile).count()
        generation_count = db.query(DBGeneration).count()
        logger.info("Profiles: %d, Generations: %d", profile_count, generation_count)

        db.commit()
    except Exception as e:
        db.rollback()
        logger.warning("Could not clean up stale generations: %s", e)
    finally:
        db.close()

    backend_type = get_backend_type()
    logger.info("Backend: %s", backend_type.upper())
    logger.info("GPU: %s", _get_gpu_status())

    if torch is not None:
        from .backends.base import check_cuda_compatibility

        _compatible, _cuda_warning = check_cuda_compatibility()
        if not _compatible:
            logger.warning("GPU COMPATIBILITY: %s", _cuda_warning)

    try:
        progress_manager = get_progress_manager()
        progress_manager._set_main_loop(asyncio.get_running_loop())
    except Exception as e:
        logger.warning("Could not initialize progress manager event loop: %s", e)

    try:
        from huggingface_hub import constants as hf_constants

        cache_dir = Path(hf_constants.HF_HUB_CACHE)
        cache_dir.mkdir(parents=True, exist_ok=True)
        logger.info("Model cache: %s", cache_dir)
    except Exception as e:
        logger.warning("Could not create HuggingFace cache directory: %s", e)

    idle_s = int(os.environ.get("VOICEBOX_IDLE_UNLOAD_S", "0") or "0")
    if idle_s > 0:
        create_background_task(_idle_unload_loop(idle_s))
        logger.info("Idle unload: models release after %ds without requests", idle_s)

    logger.info("Ready")


async def _idle_unload_loop(idle_s: int) -> None:
    """Free model memory after ``idle_s`` seconds without authed requests.

    ponytail: activity = last HTTP request, not per-model use — a generation
    still running past idle_s could be unloaded mid-run. Kokoro finishes in
    seconds; set VOICEBOX_IDLE_UNLOAD_S well above your longest generation.
    """
    while True:
        await asyncio.sleep(min(60, idle_s))
        if time.monotonic() - _last_request_ts <= idle_s:
            continue
        for label, is_loaded, unload in (
            ("TTS", lambda: tts.get_tts_model().is_loaded(), tts.unload_tts_model),
            ("Whisper", lambda: transcribe.get_whisper_model().is_loaded(), transcribe.unload_whisper_model),
            ("LLM", lambda: llm.get_llm_model().is_loaded(), llm.unload_llm_model),
        ):
            try:
                if is_loaded():
                    logger.info("Idle %ds — unloading %s model", idle_s, label)
                    unload()
            except Exception:
                logger.exception("Idle unload of %s model failed", label)


async def _run_shutdown() -> None:
    """Unload models on lifespan exit."""
    logger.info("Voicebox server shutting down...")
    try:
        tts.unload_tts_model()
    except Exception:
        logger.exception("Failed to unload TTS model")
    try:
        transcribe.unload_whisper_model()
    except Exception:
        logger.exception("Failed to unload Whisper model")
    try:
        llm.unload_llm_model()
    except Exception:
        logger.exception("Failed to unload LLM model")


app = create_app()
