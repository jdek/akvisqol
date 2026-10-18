# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

"""Drop-in replacement for the `visqol-python` (3.8.0) API.

    api = VisqolApi()
    api.create(mode="audio")
    print(api.measure("reference.wav", "degraded.wav").moslqo)

`create(backend=...)` is an extension.
"""

from __future__ import annotations

import logging
import os
import threading
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Callable

import numpy as np
from numpy.typing import NDArray

from . import _native

logger = logging.getLogger(__name__)

_VALID_MODES = frozenset({"audio", "speech"})

# (completed_count, total_count) -> None
ProgressCallback = Callable[[int, int], None]


def _empty() -> NDArray[np.float64]:
    return np.array([], dtype=np.float64)


@dataclass
class PatchSimilarityResult:
    """Result of comparing a reference patch with a degraded patch."""

    similarity: float = 0.0
    freq_band_means: NDArray[np.float64] = field(default_factory=_empty)
    freq_band_stddevs: NDArray[np.float64] = field(default_factory=_empty)
    freq_band_deg_energy: NDArray[np.float64] = field(default_factory=_empty)
    ref_patch_start_time: float = 0.0
    ref_patch_end_time: float = 0.0
    deg_patch_start_time: float = 0.0
    deg_patch_end_time: float = 0.0

    def __str__(self) -> str:
        return (
            f"PatchSimilarityResult(sim={self.similarity:.4f}, "
            f"ref=[{self.ref_patch_start_time:.3f}-{self.ref_patch_end_time:.3f}], "
            f"deg=[{self.deg_patch_start_time:.3f}-{self.deg_patch_end_time:.3f}])"
        )

    def __repr__(self) -> str:
        return (
            f"PatchSimilarityResult(similarity={self.similarity!r}, "
            f"freq_band_means=<{len(self.freq_band_means)} bands>)"
        )


@dataclass
class SimilarityResult:
    """Complete result of a ViSQOL similarity comparison."""

    moslqo: float = 0.0
    vnsim: float = 0.0
    fvnsim: NDArray[np.float64] = field(default_factory=_empty)
    fvnsim10: NDArray[np.float64] = field(default_factory=_empty)
    fstdnsim: NDArray[np.float64] = field(default_factory=_empty)
    fvdegenergy: NDArray[np.float64] = field(default_factory=_empty)
    center_freq_bands: NDArray[np.float64] = field(default_factory=_empty)
    patch_sims: list[PatchSimilarityResult] = field(default_factory=list)

    def __str__(self) -> str:
        return f"SimilarityResult(moslqo={self.moslqo:.4f}, vnsim={self.vnsim:.4f})"

    def __repr__(self) -> str:
        return (
            f"SimilarityResult(moslqo={self.moslqo!r}, vnsim={self.vnsim!r}, "
            f"fvnsim=<{len(self.fvnsim)} bands>, "
            f"patch_sims=<{len(self.patch_sims)} patches>)"
        )


class AudioSignal:
    """Container for audio signal data."""

    __slots__ = ("data", "sample_rate")

    def __init__(self, data: NDArray[np.floating], sample_rate: int) -> None:
        self.data: NDArray[np.float64] = np.asarray(data, dtype=np.float64).ravel()
        self.sample_rate: int = int(sample_rate)
        if self.sample_rate <= 0:
            raise ValueError(f"sample_rate must be positive, got {self.sample_rate}")

    @property
    def duration(self) -> float:
        """Duration in seconds."""
        return len(self.data) / self.sample_rate

    @property
    def num_samples(self) -> int:
        return len(self.data)

    def __len__(self) -> int:
        return len(self.data)


def _convert(ptr) -> SimilarityResult:
    try:
        r = ptr.contents
        nb = r.num_bands
        patches = []
        for i in range(r.num_patches):
            p = r.patch_sims[i]
            patches.append(PatchSimilarityResult(
                similarity=p.similarity,
                freq_band_means=_native.vec(p.freq_band_means, nb),
                freq_band_stddevs=_native.vec(p.freq_band_stddevs, nb),
                freq_band_deg_energy=_native.vec(p.freq_band_deg_energy, nb),
                ref_patch_start_time=p.ref_patch_start_time,
                ref_patch_end_time=p.ref_patch_end_time,
                deg_patch_start_time=p.deg_patch_start_time,
                deg_patch_end_time=p.deg_patch_end_time,
            ))
        fvnsim, fvnsim10 = _native.vec(r.fvnsim, nb), _native.vec(r.fvnsim10, nb)
        fstdnsim, fvdegenergy = _native.vec(r.fstdnsim, nb), _native.vec(r.fvdegenergy, nb)
        return SimilarityResult(
            moslqo=r.moslqo,
            vnsim=r.vnsim,
            fvnsim=fvnsim,
            fvnsim10=fvnsim10,
            fstdnsim=fstdnsim,
            fvdegenergy=fvdegenergy,
            center_freq_bands=_native.vec(r.center_freq_bands, nb),
            patch_sims=patches,
        )
    finally:
        _native.free(ptr)


def _raise(e: _native.NativeError) -> None:
    if e.code == _native.E_IO:
        raise FileNotFoundError(str(e)) from None
    if e.code in (_native.E_INVALID_ARGUMENT, _native.E_SIGNAL):
        raise ValueError(str(e)) from None
    raise RuntimeError(str(e)) from None


class VisqolApi:
    """Public API for ViSQOL audio quality assessment (visqol-python compatible)."""

    def __init__(self) -> None:
        self._ctx: _native.Context | None = None
        self._lock = threading.Lock()

    def create(
        self,
        mode: str = "audio",
        model_path: str | None = None,
        search_window: int = 60,
        use_unscaled_speech: bool = False,
        use_lattice_model: bool | None = None,
        lattice_model_path: str | None = None,
        disable_global_alignment: bool = False,
        disable_realignment: bool = False,
        *,
        backend: str | None = None,
    ) -> None:
        """Initialise with the given configuration.

        Speech mode uses the lattice model unless `use_lattice_model` is False.
        `backend`: "cpu", "metal", "cuda" or "vulkan" (default `$VISQOL_BACKEND` or "cpu").
        """
        mode_lower = mode.lower()
        if mode_lower not in _VALID_MODES:
            raise ValueError(f"Invalid mode {mode!r}. Must be one of {sorted(_VALID_MODES)}.")
        if search_window <= 0:
            raise ValueError(f"search_window must be a positive integer, got {search_window}.")
        if model_path is not None and not os.path.isfile(model_path):
            raise FileNotFoundError(f"SVR model file not found: {model_path}")
        if lattice_model_path is not None and not os.path.isfile(lattice_model_path):
            raise FileNotFoundError(f"Lattice model file not found: {lattice_model_path}")
        speech = mode_lower == "speech"
        lattice = speech and use_lattice_model is not False
        try:
            ctx = _native.Context(
                mode=_native.MODE_SPEECH if speech else _native.MODE_AUDIO,
                search_window_radius=search_window,
                use_unscaled_speech_mos_mapping=use_unscaled_speech,
                disable_global_alignment=disable_global_alignment,
                disable_realignment=disable_realignment,
                use_lattice_model=lattice,
                model_path=lattice_model_path if speech else model_path,
                backend=(backend or os.environ.get("VISQOL_BACKEND", "cpu")).lower(),
            )
        except _native.NativeError as e:
            _raise(e)
        with self._lock:
            if self._ctx is not None:
                self._ctx.close()
            self._ctx = ctx

    def _require(self) -> _native.Context:
        if self._ctx is None:
            raise RuntimeError("VisqolApi must be created (call .create()) before measuring.")
        return self._ctx

    def measure(self, ref_path: str, deg_path: str) -> SimilarityResult:
        """Compare two WAV files."""
        ctx = self._require()
        for p, what in ((ref_path, "Reference"), (deg_path, "Degraded")):
            if not os.path.isfile(p):
                raise FileNotFoundError(f"{what} audio file not found: {p}")
        with self._lock:
            try:
                ptr = ctx.measure_files(os.fspath(ref_path), os.fspath(deg_path))
            except _native.NativeError as e:
                _raise(e)
        return _convert(ptr)

    def measure_from_arrays(
        self,
        ref_array: NDArray[np.floating],
        deg_array: NDArray[np.floating],
        sample_rate: int,
    ) -> SimilarityResult:
        """Compare two 1-D signals at a shared sample rate."""
        ctx = self._require()
        for a, name in ((ref_array, "ref_array"), (deg_array, "deg_array")):
            if not isinstance(a, np.ndarray):
                raise TypeError(f"{name} must be a numpy array, got {type(a).__name__}")
            if a.size == 0:
                raise ValueError(f"{name} must not be empty.")
        if sample_rate <= 0:
            raise ValueError(f"sample_rate must be a positive integer, got {sample_rate}.")
        ref = _native.as_signal(np.asarray(ref_array).ravel(), "ref_array")
        deg = _native.as_signal(np.asarray(deg_array).ravel(), "deg_array")
        with self._lock:
            try:
                ptr = ctx.measure(ref, deg, int(sample_rate))
            except _native.NativeError as e:
                _raise(e)
        return _convert(ptr)

    def measure_batch(
        self,
        file_pairs: Sequence[tuple[str, str]],
        *,
        max_workers: int | None = None,
        parallel: bool = True,
        progress_callback: ProgressCallback | None = None,
    ) -> list[SimilarityResult | Exception]:
        """Score many WAV pairs; results (or the exception for a failed pair) in input order.

        `max_workers` native threads (default: all cores), or one if not `parallel`.
        """
        ctx = self._require()
        total = len(file_pairs)
        if total == 0:
            return []
        threads = 1 if not parallel else (max_workers or 0)
        # Chunk only to report progress.
        workers = threads or (os.cpu_count() or 1)
        chunk = total if progress_callback is None else max(workers * 2, 1)
        results: list[SimilarityResult | Exception] = []
        for lo in range(0, total, chunk):
            part = file_pairs[lo:lo + chunk]
            refs = [os.fspath(r) for r, _ in part]
            degs = [os.fspath(d) for _, d in part]
            with self._lock:
                raw = ctx.measure_files_batch(refs, degs, threads)
            for i, r in enumerate(raw):
                if isinstance(r, _native.NativeError):
                    logger.warning("Pair %d/%d failed: %s", lo + i + 1, total, r)
                    results.append(r)
                else:
                    results.append(_convert(r))
            if progress_callback is not None:
                progress_callback(len(results), total)
        return results
