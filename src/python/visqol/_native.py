# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

"""ctypes binding to libvisqol (see src/include/visqol.h)."""

from __future__ import annotations

import ctypes
import os
import sys
from ctypes import POINTER, c_char_p, c_double, c_int, c_int32, c_size_t, c_uint8, c_uint32, c_void_p
from pathlib import Path

import numpy as np

MODE_AUDIO = 0
MODE_SPEECH = 1

BACKENDS = {"cpu": 0, "metal": 1, "cuda": 2, "vulkan": 3}

OK = 0
E_INVALID_ARGUMENT = -1
E_OUT_OF_MEMORY = -2
E_IO = -3
E_MODEL = -4
E_SIGNAL = -5
E_BACKEND = -6
E_INTERNAL = -7


class Options(ctypes.Structure):
    _fields_ = [
        ("mode", c_uint32),
        ("search_window_radius", c_int32),
        ("use_unscaled_speech_mos_mapping", c_uint8),
        ("disable_global_alignment", c_uint8),
        ("disable_realignment", c_uint8),
        ("use_lattice_model", c_uint8),
        ("model_path", c_char_p),
        ("backend", c_uint32),
        ("_reserved1", c_uint32),
    ]


class Patch(ctypes.Structure):
    _fields_ = [
        ("similarity", c_double),
        ("ref_patch_start_time", c_double),
        ("ref_patch_end_time", c_double),
        ("deg_patch_start_time", c_double),
        ("deg_patch_end_time", c_double),
        ("freq_band_means", POINTER(c_double)),
        ("freq_band_stddevs", POINTER(c_double)),
        ("freq_band_deg_energy", POINTER(c_double)),
    ]


class Result(ctypes.Structure):
    _fields_ = [
        ("moslqo", c_double),
        ("vnsim", c_double),
        ("alignment_lag_s", c_double),
        ("num_bands", c_size_t),
        ("fvnsim", POINTER(c_double)),
        ("fvnsim10", POINTER(c_double)),
        ("fstdnsim", POINTER(c_double)),
        ("fvdegenergy", POINTER(c_double)),
        ("center_freq_bands", POINTER(c_double)),
        ("num_patches", c_size_t),
        ("patch_sims", POINTER(Patch)),
    ]


def _lib_names() -> list[str]:
    if sys.platform == "darwin":
        return ["libvisqol.dylib"]
    if sys.platform == "win32":
        return ["visqol.dll"]
    return ["libvisqol.so"]


def _load() -> ctypes.CDLL:
    override = os.environ.get("VISQOL_LIBRARY")
    candidates = [Path(override)] if override else []
    here = Path(__file__).resolve().parent
    for name in _lib_names():
        candidates.append(here / "_lib" / name)
        # Dev checkout: <repo>/zig-out/lib.
        candidates.append(here.parents[2] / "zig-out" / "lib" / name)
    for c in candidates:
        if c.is_file():
            return ctypes.CDLL(str(c))
    raise ImportError(
        "libvisqol not found; build it with `zig build python -Doptimize=ReleaseFast` "
        "or set VISQOL_LIBRARY. Looked in: " + ", ".join(str(c) for c in candidates)
    )


lib = _load()

lib.visqol_abi_version.restype = c_uint32
lib.visqol_version.restype = c_char_p
lib.visqol_last_error.restype = c_char_p
lib.visqol_available_backends.restype = c_uint32
lib.visqol_options_default.argtypes = [POINTER(Options)]
lib.visqol_create.argtypes = [POINTER(Options), POINTER(c_void_p)]
lib.visqol_create.restype = c_int
lib.visqol_destroy.argtypes = [c_void_p]
lib.visqol_destroy.restype = None
lib.visqol_measure.argtypes = [
    c_void_p, POINTER(c_double), c_size_t, POINTER(c_double), c_size_t, c_uint32, POINTER(POINTER(Result)),
]
lib.visqol_measure.restype = c_int
lib.visqol_measure_files.argtypes = [c_void_p, c_char_p, c_char_p, POINTER(POINTER(Result))]
lib.visqol_measure_files.restype = c_int
lib.visqol_measure_batch.argtypes = [
    c_void_p, c_size_t,
    POINTER(POINTER(c_double)), POINTER(c_size_t),
    POINTER(POINTER(c_double)), POINTER(c_size_t),
    c_uint32, c_uint32, POINTER(POINTER(Result)), POINTER(c_int32),
]
lib.visqol_measure_batch.restype = c_int
lib.visqol_measure_files_batch.argtypes = [
    c_void_p, c_size_t, POINTER(c_char_p), POINTER(c_char_p), c_uint32, POINTER(POINTER(Result)), POINTER(c_int32),
]
lib.visqol_measure_files_batch.restype = c_int
lib.visqol_result_free.argtypes = [POINTER(Result)]
lib.visqol_result_free.restype = None

ABI_VERSION = 1
if lib.visqol_abi_version() != ABI_VERSION:
    raise ImportError(
        f"libvisqol ABI {lib.visqol_abi_version()} does not match the Python bindings ({ABI_VERSION})")

__version__ = lib.visqol_version().decode()


class NativeError(RuntimeError):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


def last_error(code: int) -> NativeError:
    return NativeError(code, (lib.visqol_last_error() or b"").decode(errors="replace"))


def available_backends() -> list[str]:
    mask = lib.visqol_available_backends()
    return [name for name, bit in BACKENDS.items() if mask & (1 << bit)]


def as_signal(x, name: str) -> np.ndarray:
    a = np.ascontiguousarray(x, dtype=np.float64)
    if a.ndim != 1:
        raise ValueError(f"{name} must be a 1-D mono signal, got shape {a.shape}")
    return a


def _ptr(a: np.ndarray):
    return a.ctypes.data_as(POINTER(c_double))


class Context:
    """Owns a `visqol_ctx`. Not thread-safe; callers serialise access."""

    def __init__(self, *, mode: int, search_window_radius: int, use_unscaled_speech_mos_mapping: bool,
                 disable_global_alignment: bool, disable_realignment: bool,
                 use_lattice_model: bool, model_path: str | None, backend: str):
        if backend not in BACKENDS:
            raise ValueError(f"unknown backend {backend!r}; expected one of {sorted(BACKENDS)}")
        opts = Options()
        lib.visqol_options_default(ctypes.byref(opts))
        opts.mode = mode
        opts.search_window_radius = search_window_radius
        opts.use_unscaled_speech_mos_mapping = int(bool(use_unscaled_speech_mos_mapping))
        opts.disable_global_alignment = int(bool(disable_global_alignment))
        opts.disable_realignment = int(bool(disable_realignment))
        opts.use_lattice_model = int(bool(use_lattice_model))
        opts.model_path = os.fsencode(model_path) if model_path else None
        opts.backend = BACKENDS[backend]
        handle = c_void_p()
        rc = lib.visqol_create(ctypes.byref(opts), ctypes.byref(handle))
        if rc != OK:
            raise last_error(rc)
        self._handle = handle

    def close(self) -> None:
        if getattr(self, "_handle", None):
            lib.visqol_destroy(self._handle)
            self._handle = None

    def __del__(self):
        self.close()

    def measure(self, ref: np.ndarray, deg: np.ndarray, sample_rate: int) -> "ctypes._Pointer[Result]":
        out = POINTER(Result)()
        rc = lib.visqol_measure(self._handle, _ptr(ref), ref.size, _ptr(deg), deg.size, sample_rate, ctypes.byref(out))
        if rc != OK:
            raise last_error(rc)
        return out

    def measure_files(self, ref_path: str, deg_path: str) -> "ctypes._Pointer[Result]":
        out = POINTER(Result)()
        rc = lib.visqol_measure_files(self._handle, os.fsencode(ref_path), os.fsencode(deg_path), ctypes.byref(out))
        if rc != OK:
            raise last_error(rc)
        return out

    def measure_batch(self, refs: list[np.ndarray], degs: list[np.ndarray], sample_rate: int, num_threads: int):
        n = len(refs)
        ref_ptrs = (POINTER(c_double) * n)(*[_ptr(a) for a in refs])
        deg_ptrs = (POINTER(c_double) * n)(*[_ptr(a) for a in degs])
        ref_lens = (c_size_t * n)(*[a.size for a in refs])
        deg_lens = (c_size_t * n)(*[a.size for a in degs])
        outs = (POINTER(Result) * n)()
        status = (c_int32 * n)()
        lib.visqol_measure_batch(self._handle, n, ref_ptrs, ref_lens, deg_ptrs, deg_lens,
                                 sample_rate, num_threads, outs, status)
        return _collect(outs, status, n)

    def measure_files_batch(self, ref_paths: list[str], deg_paths: list[str], num_threads: int):
        n = len(ref_paths)
        refs = (c_char_p * n)(*[os.fsencode(p) for p in ref_paths])
        degs = (c_char_p * n)(*[os.fsencode(p) for p in deg_paths])
        outs = (POINTER(Result) * n)()
        status = (c_int32 * n)()
        lib.visqol_measure_files_batch(self._handle, n, refs, degs, num_threads, outs, status)
        return _collect(outs, status, n)


def _collect(outs, status, n: int) -> list:
    """Per-pair `Result` pointers, or `NativeError` for failed pairs."""
    return [outs[i] if status[i] == OK else NativeError(status[i], f"pair {i}: error code {status[i]}")
            for i in range(n)]


def free(result) -> None:
    lib.visqol_result_free(result)


def vec(ptr, n: int) -> np.ndarray:
    return np.ctypeslib.as_array(ptr, shape=(n,)).copy()
