"""
Whisper STT backend via faster-whisper (CTranslate2) — torch-free.

Drop-in replacement for the old transformers/torch Whisper backend: same
size names (base/small/medium/large/turbo), same method surface
(load_model/_is_model_cached/transcribe/unload_model/is_loaded/model_size).
Models download from HuggingFace into the standard HF cache on first use.
"""

import asyncio
import logging
import os
from typing import Optional

from .base import is_model_cached, model_load_progress

logger = logging.getLogger(__name__)

# CTranslate2 conversions of the OpenAI Whisper weights, keyed by the same
# size names the REST/MCP contract already exposes.
FASTER_WHISPER_REPOS = {
    "base": "Systran/faster-whisper-base",
    "small": "Systran/faster-whisper-small",
    "medium": "Systran/faster-whisper-medium",
    "large": "Systran/faster-whisper-large-v3",
    "turbo": "deepdml/faster-whisper-large-v3-turbo-ct2",
}


class FasterWhisperSTTBackend:
    """CPU Whisper via CTranslate2. int8 by default (fast, small)."""

    def __init__(self, model_size: str = "base"):
        self.model = None
        self.model_size = model_size
        self.compute_type = os.environ.get("VOICEBOX_WHISPER_COMPUTE", "int8")

    def is_loaded(self) -> bool:
        return self.model is not None

    def _repo(self, model_size: str) -> str:
        return FASTER_WHISPER_REPOS.get(
            model_size, f"Systran/faster-whisper-{model_size}"
        )

    def _is_model_cached(self, model_size: str) -> bool:
        return is_model_cached(self._repo(model_size), required_files=["model.bin"])

    async def load_model_async(self, model_size: Optional[str] = None):
        if model_size is None:
            model_size = self.model_size
        if self.model is not None and self.model_size == model_size:
            return
        await asyncio.to_thread(self._load_model_sync, model_size)

    # Alias kept for callers that use the old name
    load_model = load_model_async

    def _load_model_sync(self, model_size: str):
        progress_model_name = f"whisper-{model_size}"
        is_cached = self._is_model_cached(model_size)

        with model_load_progress(progress_model_name, is_cached):
            from faster_whisper import WhisperModel

            logger.info(
                "Loading faster-whisper %s (compute_type=%s)...",
                model_size,
                self.compute_type,
            )
            self.model = WhisperModel(
                self._repo(model_size), device="cpu", compute_type=self.compute_type
            )

        self.model_size = model_size
        logger.info("Whisper model %s loaded", model_size)

    def unload_model(self):
        if self.model is not None:
            self.model = None
            logger.info("Whisper model unloaded")

    async def transcribe(
        self,
        audio_path: str,
        language: Optional[str] = None,
        model_size: Optional[str] = None,
    ) -> str:
        await self.load_model_async(model_size)

        def _transcribe_sync():
            model = self.model
            if model is None:  # idle-unload raced us — reload
                self._load_model_sync(model_size or self.model_size)
                model = self.model
            segments, _info = model.transcribe(audio_path, language=language)
            return "".join(segment.text for segment in segments).strip()

        return await asyncio.to_thread(_transcribe_sync)
