"""
Kokoro TTS backend — ONNX Runtime implementation (torch-free).

Wraps kokoro-onnx (int8-quantized Kokoro-82M) for fast CPU text-to-speech.
24kHz output, Apache 2.0 license. Voices are pre-built style vectors keyed
by voice id inside a single voices .bin file baked into the docker image.

The public surface (class name, KOKORO_VOICES, voice_prompt dict contract)
matches the previous torch implementation, so the registry, profile service
and generation pipeline are untouched.
"""

import asyncio
import logging
import os
import threading
from typing import Optional

import numpy as np

from .base import (
    combine_voice_prompts as _combine_voice_prompts,
    model_load_progress,
)

logger = logging.getLogger(__name__)

KOKORO_SAMPLE_RATE = 24000

# Default voice if none specified
KOKORO_DEFAULT_VOICE = "af_heart"

# All available Kokoro voices: (voice_id, display_name, gender, lang_code)
KOKORO_VOICES = [
    # American English female
    ("af_alloy", "Alloy", "female", "en"),
    ("af_aoede", "Aoede", "female", "en"),
    ("af_bella", "Bella", "female", "en"),
    ("af_heart", "Heart", "female", "en"),
    ("af_jessica", "Jessica", "female", "en"),
    ("af_kore", "Kore", "female", "en"),
    ("af_nicole", "Nicole", "female", "en"),
    ("af_nova", "Nova", "female", "en"),
    ("af_river", "River", "female", "en"),
    ("af_sarah", "Sarah", "female", "en"),
    ("af_sky", "Sky", "female", "en"),
    # American English male
    ("am_adam", "Adam", "male", "en"),
    ("am_echo", "Echo", "male", "en"),
    ("am_eric", "Eric", "male", "en"),
    ("am_fenrir", "Fenrir", "male", "en"),
    ("am_liam", "Liam", "male", "en"),
    ("am_michael", "Michael", "male", "en"),
    ("am_onyx", "Onyx", "male", "en"),
    ("am_puck", "Puck", "male", "en"),
    ("am_santa", "Santa", "male", "en"),
    # British English female
    ("bf_alice", "Alice", "female", "en"),
    ("bf_emma", "Emma", "female", "en"),
    ("bf_isabella", "Isabella", "female", "en"),
    ("bf_lily", "Lily", "female", "en"),
    # British English male
    ("bm_daniel", "Daniel", "male", "en"),
    ("bm_fable", "Fable", "male", "en"),
    ("bm_george", "George", "male", "en"),
    ("bm_lewis", "Lewis", "male", "en"),
    # Spanish
    ("ef_dora", "Dora", "female", "es"),
    ("em_alex", "Alex", "male", "es"),
    ("em_santa", "Santa", "male", "es"),
    # French
    ("ff_siwis", "Siwis", "female", "fr"),
    # Hindi
    ("hf_alpha", "Alpha", "female", "hi"),
    ("hf_beta", "Beta", "female", "hi"),
    ("hm_omega", "Omega", "male", "hi"),
    ("hm_psi", "Psi", "male", "hi"),
    # Italian
    ("if_sara", "Sara", "female", "it"),
    ("im_nicola", "Nicola", "male", "it"),
    # Japanese
    ("jf_alpha", "Alpha", "female", "ja"),
    ("jf_gongitsune", "Gongitsune", "female", "ja"),
    ("jf_nezumi", "Nezumi", "female", "ja"),
    ("jf_tebukuro", "Tebukuro", "female", "ja"),
    ("jm_kumo", "Kumo", "male", "ja"),
    # Portuguese
    ("pf_dora", "Dora", "female", "pt"),
    ("pm_alex", "Alex", "male", "pt"),
    ("pm_santa", "Santa", "male", "pt"),
    # Chinese
    ("zf_xiaobei", "Xiaobei", "female", "zh"),
    ("zf_xiaoni", "Xiaoni", "female", "zh"),
    ("zf_xiaoxiao", "Xiaoxiao", "female", "zh"),
    ("zf_xiaoyi", "Xiaoyi", "female", "zh"),
]

_VALID_VOICE_IDS = {voice_id for voice_id, _n, _g, _l in KOKORO_VOICES}

# Map our ISO language codes to kokoro-onnx (espeak-style) lang codes
LANG_CODE_MAP = {
    "en": "en-us",
    "es": "es",
    "fr": "fr-fr",
    "hi": "hi",
    "it": "it",
    "pt": "pt-br",
    "ja": "ja",
    "zh": "cmn",
}

# Release assets baked into the docker image and auto-downloaded by
# native (brew/pip) installs on first use.
_KOKORO_ONNX_URL = (
    "https://github.com/thewh1teagle/kokoro-onnx/releases/download/"
    "model-files-v1.0/kokoro-v1.0.int8.onnx"
)
_KOKORO_VOICES_URL = (
    "https://github.com/thewh1teagle/kokoro-onnx/releases/download/"
    "model-files-v1.0/voices-v1.0.bin"
)


class KokoroTTSBackend:
    """Kokoro-82M TTS backend on onnxruntime — tiny, fast, torch-free."""

    def __init__(self):
        self._kokoro = None
        # Serializes load AND create: kokoro-onnx phonemizes via espeak-ng,
        # which is not thread-safe — /generate/stream bypasses the task
        # queue, so two requests can hit this backend concurrently.
        self._lock = threading.Lock()
        self.model_size = "default"
        # Env overrides (the docker image sets these to the baked files);
        # otherwise files live under <data-dir>/models/kokoro and are
        # downloaded on first use.
        self._env_model = os.environ.get("VOICEBOX_KOKORO_ONNX_MODEL")
        self._env_voices = os.environ.get("VOICEBOX_KOKORO_ONNX_VOICES")

    @property
    def model_path(self) -> str:
        if self._env_model:
            return self._env_model
        return str(self._default_dir() / "kokoro.onnx")

    @property
    def voices_path(self) -> str:
        if self._env_voices:
            return self._env_voices
        return str(self._default_dir() / "voices.bin")

    @staticmethod
    def _default_dir():
        from .. import config

        return config.get_data_dir() / "models" / "kokoro"

    def is_loaded(self) -> bool:
        return self._kokoro is not None

    def _get_model_path(self, model_size: str) -> str:
        return self.model_path

    def _is_model_cached(self, model_size: str = "default") -> bool:
        """'Cached' = both files exist (image-baked or previously fetched)."""
        return os.path.isfile(self.model_path) and os.path.isfile(self.voices_path)

    async def load_model(self, model_size: str = "default") -> None:
        if self._kokoro is not None:
            return
        await asyncio.to_thread(self._load_locked)

    def _load_locked(self):
        with self._lock:
            if self._kokoro is None:
                self._load_model_sync()

    def _ensure_files(self):
        """Fetch model + voices into the data dir when absent.

        Only the default (data-dir) layout auto-downloads. Explicit env
        paths that point at missing files are a config error — fail loudly
        rather than writing files somewhere the operator didn't choose.
        """
        if self._is_model_cached():
            return
        if self._env_model or self._env_voices:
            raise RuntimeError(
                "Kokoro ONNX model files missing "
                f"({self.model_path}, {self.voices_path}) but "
                "VOICEBOX_KOKORO_ONNX_MODEL / _VOICES are set — fix the "
                "paths or unset them to auto-download into the data dir. "
                "Files: github.com/thewh1teagle/kokoro-onnx/releases."
            )
        import urllib.error
        import urllib.request

        target_dir = self._default_dir()
        target_dir.mkdir(parents=True, exist_ok=True)
        for url, dest in (
            (_KOKORO_ONNX_URL, self.model_path),
            (_KOKORO_VOICES_URL, self.voices_path),
        ):
            if os.path.isfile(dest):
                continue
            logger.info("Downloading %s -> %s", url, dest)
            tmp = f"{dest}.part"
            try:
                urllib.request.urlretrieve(url, tmp)  # noqa: S310 — pinned https URLs
                os.replace(tmp, dest)
            except urllib.error.HTTPError as exc:
                raise RuntimeError(
                    f"Kokoro model download failed: HTTP {exc.code} for {url}. "
                    "The release asset may have moved — see "
                    "github.com/thewh1teagle/kokoro-onnx/releases "
                    "(mirror: huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX)."
                ) from exc
            finally:
                if os.path.isfile(tmp):
                    os.unlink(tmp)

    def _load_model_sync(self):
        self._ensure_files()
        with model_load_progress("kokoro", True):
            import onnxruntime as ort
            from kokoro_onnx import Kokoro

            # Explicit thread caps: onnxruntime sizes its pool from the HOST
            # core count, which thrashes inside a cpu-limited container.
            # Measured on a 4-cpu cgroup: default 5.6s -> intra_op=2 3.3s.
            threads = int(os.environ.get("VOICEBOX_ONNX_THREADS", "2") or "2")
            sess_options = ort.SessionOptions()
            sess_options.intra_op_num_threads = threads
            sess_options.inter_op_num_threads = 1
            session = ort.InferenceSession(
                self.model_path,
                sess_options=sess_options,
                providers=["CPUExecutionProvider"],
            )
            logger.info(
                "Loading Kokoro-82M (onnx, intra_op=%d) from %s...",
                threads,
                self.model_path,
            )
            self._kokoro = Kokoro.from_session(session, self.voices_path)
        logger.info("Kokoro-82M (onnx) loaded")

    def unload_model(self) -> None:
        with self._lock:
            if self._kokoro is not None:
                self._kokoro = None
                logger.info("Kokoro (onnx) unloaded")

    async def create_voice_prompt(
        self,
        audio_path: str,
        reference_text: str,
        use_cache: bool = True,
    ) -> tuple[dict, bool]:
        """Kokoro has no cloning — fall back to the default preset voice.

        Preset profiles bypass this: the profile service builds their
        voice_prompt dict directly.
        """
        return {
            "voice_type": "preset",
            "preset_engine": "kokoro",
            "preset_voice_id": KOKORO_DEFAULT_VOICE,
        }, False

    async def combine_voice_prompts(
        self,
        audio_paths: list[str],
        reference_texts: list[str],
    ) -> tuple[np.ndarray, str]:
        """Combine voice prompts — base implementation (audio concatenation)."""
        return await _combine_voice_prompts(
            audio_paths, reference_texts, sample_rate=KOKORO_SAMPLE_RATE
        )

    async def generate(
        self,
        text: str,
        voice_prompt: dict,
        language: str = "en",
        seed: Optional[int] = None,
        instruct: Optional[str] = None,
    ) -> tuple[np.ndarray, int]:
        """Generate audio from text.

        ``seed`` and ``instruct`` are ignored — ONNX inference is
        deterministic and Kokoro has no instruction conditioning.
        """
        await self.load_model()

        voice = (
            voice_prompt.get("preset_voice_id")
            or voice_prompt.get("kokoro_voice")
            or KOKORO_DEFAULT_VOICE
        )
        if voice not in _VALID_VOICE_IDS:
            raise ValueError(
                f"Unknown kokoro voice '{voice}'. "
                "See GET /profiles/presets/kokoro for valid voice ids."
            )
        lang = LANG_CODE_MAP.get(language, "en-us")
        if voice.startswith(("bf_", "bm_")):
            lang = "en-gb"  # British voices sound wrong through the US G2P

        def _generate_sync():
            with self._lock:
                kokoro = self._kokoro
                if kokoro is None:  # idle-unload raced us — reload
                    self._load_model_sync()
                    kokoro = self._kokoro
                samples, sr = kokoro.create(text, voice=voice, speed=1.0, lang=lang)
            samples = np.asarray(samples)
            if samples.size == 0:
                # 1 second of silence as fallback, matching old behavior
                return np.zeros(KOKORO_SAMPLE_RATE, dtype=np.float32), KOKORO_SAMPLE_RATE
            return samples.astype(np.float32), int(sr)

        return await asyncio.to_thread(_generate_sync)
