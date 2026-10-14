# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

"""Drop-in replacement for google/visqol's `visqol_lib_py` pybind module.

Non-OK `absl::Status` raises `StatusNotOk`. Extensions:
`VisqolApi(backend=...)` / `VISQOL_BACKEND`, `VisqolApi.MeasureBatch`.
"""

from __future__ import annotations

import logging
import os
import threading
from pathlib import Path
from typing import Iterable, Sequence

import numpy as np

from . import _native
from .pb2 import similarity_result_pb2, visqol_config_pb2

__doc__ = "ViSQOL plugin (Zig implementation; API-compatible with google/visqol)\n\n" + __doc__

_log = logging.getLogger("visqol")

# Wheels ship the models in visqol/model; a source checkout reads <repo>/src/model.
_MODEL_DIR = next(
    (d for d in (Path(__file__).resolve().parent / "model", Path(__file__).resolve().parents[2] / "model")
     if (d / "libsvm_nu_svr_model.txt").is_file()),
    Path(__file__).resolve().parent / "model",
)
_AUDIO_MODEL = "libsvm_nu_svr_model.txt"
_SPEECH_MODEL = "lattice_tcditugenmeetpackhref_ls2_nl60_lr12_bs2048_learn.005_ep2400_train1_7_raw.tflite"

_SAMPLE_RATE_AUDIO = 48000
_SAMPLE_RATE_SPEECH = 16000
_DURATION_MISMATCH_TOLERANCE = 1.0


class StatusNotOk(RuntimeError):
    """Raised where upstream returns a non-OK `absl::Status`."""

    def __init__(self, message: str, code: str = "INVALID_ARGUMENT"):
        super().__init__(f"{code}: {message}")
        self.message = message
        self.code = code


def ConformanceSpeechCA01TranscodedValue() -> float:
    return 3.3129234313964844


def DefaultSpeechModelFile() -> str:
    return str(_MODEL_DIR / _SPEECH_MODEL)


def DefaultAudioModelFile() -> str:
    return str(_MODEL_DIR / _AUDIO_MODEL)


class FilePath:
    def __init__(self, path: str | os.PathLike):
        self._path = os.fspath(path)

    def Path(self) -> str:
        return self._path

    def __fspath__(self) -> str:
        return self._path

    def __repr__(self) -> str:
        return f"FilePath({self._path!r})"


def _default_backend() -> str:
    return os.environ.get("VISQOL_BACKEND", "cpu").lower()


class _Engine:
    """Shared machinery behind VisqolApi and VisqolManager."""

    def __init__(self, *, speech: bool, unscaled: bool, search_window: int, lattice: bool,
                 model_path: str, disable_global_alignment: bool = False,
                 disable_realignment: bool = False, backend: str | None = None):
        self.speech = speech
        lattice = bool(lattice)
        if lattice and not speech:
            _log.warning("Lattice models are not yet supported for audio mode, falling back to SVR model.")
        # SVR model in audio mode, lattice model in speech+lattice mode.
        path = model_path if (not speech or lattice) else None
        if path and not os.path.isfile(path):
            if speech:
                raise StatusNotOk(f"Could not build TFLite FlatBufferModel from path: {path}")
            raise StatusNotOk(f"Failed to load the SVR model file: {path}", "INVALID_ARGUMENT")
        try:
            self.ctx = _native.Context(
                mode=_native.MODE_SPEECH if speech else _native.MODE_AUDIO,
                search_window_radius=search_window,
                use_unscaled_speech_mos_mapping=unscaled,
                disable_global_alignment=disable_global_alignment,
                disable_realignment=disable_realignment,
                use_lattice_model=speech and lattice,
                model_path=path,
                backend=backend or _default_backend(),
            )
        except _native.NativeError as e:
            raise StatusNotOk(str(e)) from None
        self.lock = threading.Lock()

    def warn_inputs(self, ref_len: int, deg_len: int, sample_rate: int) -> None:
        if abs(ref_len - deg_len) / sample_rate > _DURATION_MISMATCH_TOLERANCE:
            _log.warning(
                "Mismatch in duration between reference and degraded signal. "
                "Reference is %.2f seconds. Degraded is %.2f seconds.",
                ref_len / sample_rate, deg_len / sample_rate)
        if self.speech and sample_rate > _SAMPLE_RATE_SPEECH:
            _log.warning("Input audio sample rate is above 16kHz, which may have undesired effects "
                         "for speech mode.  Consider resampling to 16kHz.")
        elif not self.speech and sample_rate != _SAMPLE_RATE_AUDIO:
            _log.warning("Input audio sample rate is not 48kHz, which may have undesired effects "
                         "for audio mode.  Consider resampling to 48kHz.")

    def to_msg(self, res) -> similarity_result_pb2.SimilarityResultMsg:
        try:
            return _to_msg(res.contents)
        finally:
            _native.free(res)

    def measure(self, ref, deg, sample_rate: int):
        with self.lock:
            try:
                res = self.ctx.measure(ref, deg, sample_rate)
            except _native.NativeError as e:
                raise StatusNotOk(str(e), _status_code(e.code)) from None
        return self.to_msg(res)


def _status_code(code: int) -> str:
    return {
        _native.E_SIGNAL: "CANCELLED",
        _native.E_IO: "NOT_FOUND",
        _native.E_OUT_OF_MEMORY: "RESOURCE_EXHAUSTED",
        _native.E_BACKEND: "UNAVAILABLE",
        _native.E_INTERNAL: "INTERNAL",
    }.get(code, "INVALID_ARGUMENT")


def _to_msg(r) -> similarity_result_pb2.SimilarityResultMsg:
    nb = r.num_bands
    fvnsim = _native.vec(r.fvnsim, nb)
    fvnsim10 = _native.vec(r.fvnsim10, nb)
    fstdnsim = _native.vec(r.fstdnsim, nb)
    fvdegenergy = _native.vec(r.fvdegenergy, nb)
    msg = similarity_result_pb2.SimilarityResultMsg()
    msg.moslqo = r.moslqo
    msg.vnsim = r.vnsim
    msg.fvnsim.extend(fvnsim.tolist())
    msg.fvnsim10.extend(fvnsim10.tolist())
    msg.fstdnsim.extend(fstdnsim.tolist())
    msg.fvdegenergy.extend(fvdegenergy.tolist())
    msg.center_freq_bands.extend(_native.vec(r.center_freq_bands, nb).tolist())
    for i in range(r.num_patches):
        p = r.patch_sims[i]
        pm = msg.patch_sims.add()
        pm.similarity = p.similarity
        pm.ref_patch_start_time = p.ref_patch_start_time
        pm.ref_patch_end_time = p.ref_patch_end_time
        pm.deg_patch_start_time = p.deg_patch_start_time
        pm.deg_patch_end_time = p.deg_patch_end_time
        pm.freq_band_means.extend(_native.vec(p.freq_band_means, nb).tolist())
    msg.alignment_lag_s = r.alignment_lag_s
    return msg


class VisqolApi:
    """Mirror of `Visqol::VisqolApi`."""

    def __init__(self, backend: str | None = None):
        self._backend = backend
        self._engine: _Engine | None = None
        self._sample_rate = 0

    def Create(self, config: visqol_config_pb2.VisqolConfig) -> None:
        if not config.HasField("audio"):
            raise StatusNotOk("Audio info must be supplied for config.")
        sample_rate = config.audio.sample_rate
        if sample_rate == 0:
            raise StatusNotOk("The sample rate for the signals must be set.")

        speech = unscaled = allow_sr = False
        search_window = 60
        lattice = True
        model_file = ""
        if config.HasField("options"):
            o = config.options
            speech = o.use_speech_scoring
            unscaled = o.use_unscaled_speech_mos_mapping
            allow_sr = o.allow_unsupported_sample_rates
            lattice = o.use_lattice_model
            model_file = o.svr_model_path
            if o.search_window_radius:
                search_window = o.search_window_radius
        if not model_file:
            model_file = DefaultSpeechModelFile() if speech else DefaultAudioModelFile()

        if sample_rate != _SAMPLE_RATE_AUDIO and not speech and not allow_sr:
            raise StatusNotOk(
                "Currently, 48k is the only sample rate supported by ViSQOL Audio. "
                "See README for details of overriding.")

        self._engine = _Engine(speech=speech, unscaled=unscaled, search_window=search_window,
                               lattice=lattice, model_path=model_file, backend=self._backend)
        self._sample_rate = sample_rate

    def _require(self) -> _Engine:
        if self._engine is None:
            raise StatusNotOk("VisqolManager must be initialized before use.", "ABORTED")
        return self._engine

    def Measure(self, reference, degraded) -> similarity_result_pb2.SimilarityResultMsg:
        eng = self._require()
        ref = _native.as_signal(reference, "reference")
        deg = _native.as_signal(degraded, "degraded")
        eng.warn_inputs(ref.size, deg.size, self._sample_rate)
        return eng.measure(ref, deg, self._sample_rate)

    def MeasureBatch(self, pairs: Iterable[tuple[Sequence[float], Sequence[float]]],
                     num_threads: int = 0) -> list[similarity_result_pb2.SimilarityResultMsg]:
        """Score many (reference, degraded) pairs; raises `StatusNotOk` if any fails."""
        eng = self._require()
        refs, degs = [], []
        for ref, deg in pairs:
            refs.append(_native.as_signal(ref, "reference"))
            degs.append(_native.as_signal(deg, "degraded"))
        if not refs:
            return []
        with eng.lock:
            raw = eng.ctx.measure_batch(refs, degs, self._sample_rate, num_threads)
        out, err = [], None
        for r in raw:
            if isinstance(r, _native.NativeError):
                err = err or r
                out.append(None)
            else:
                out.append(eng.to_msg(r))
        if err is not None:
            raise StatusNotOk(str(err), _status_code(err.code))
        return out


class VisqolManager:
    """Mirror of `Visqol::VisqolManager` (file-path based)."""

    def __init__(self, backend: str | None = None):
        self._backend = backend
        self._engine: _Engine | None = None

    def Init(self, similarity_to_quality_mapper_model, use_speech_mode: bool, use_unscaled_speech: bool,
             search_window: int, use_lattice_model: bool = True, disable_global_alignment: bool = False,
             disable_realignment: bool = False) -> None:
        model = similarity_to_quality_mapper_model
        model_path = model.Path() if isinstance(model, FilePath) else os.fspath(model)
        self._engine = _Engine(
            speech=use_speech_mode, unscaled=use_unscaled_speech, search_window=search_window,
            lattice=use_lattice_model, model_path=model_path,
            disable_global_alignment=disable_global_alignment,
            disable_realignment=disable_realignment, backend=self._backend)

    def Run(self, ref_signal_path, deg_signal_path) -> similarity_result_pb2.SimilarityResultMsg:
        if self._engine is None:
            raise StatusNotOk("VisqolManager must be initialized before use.", "ABORTED")
        rp = ref_signal_path.Path() if isinstance(ref_signal_path, FilePath) else os.fspath(ref_signal_path)
        dp = deg_signal_path.Path() if isinstance(deg_signal_path, FilePath) else os.fspath(deg_signal_path)
        eng = self._engine
        with eng.lock:
            try:
                res = eng.ctx.measure_files(rp, dp)
            except _native.NativeError as e:
                raise StatusNotOk(str(e), _status_code(e.code)) from None
        msg = eng.to_msg(res)
        msg.reference_filepath = rp
        msg.degraded_filepath = dp
        return msg
