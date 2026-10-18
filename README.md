# akvisqol

Google's [ViSQOL](https://github.com/google/visqol) v3.3.3 in Zig: a fast,
conformant reimplementation with optional Metal, CUDA and Vulkan backends, and
drop-in replacements for the C++ and Python APIs. The project and its
packages are `akvisqol`; the drop-in surfaces keep upstream's names
(`import visqol`, the `visqol` CLI, `libvisqol`).

- **Conformant**: within ~1e-13 MOS of Google's C++ on the CPU, C++ quirks
  included ([Verification](#verification)).
- **Fast**: 20–39× Google's C++ and Python on the same cores, 77–86× with
  Metal on audio, 4–6× visqol-python ([Performance](#performance)).
- **Drop-in**: Google's `visqol_lib_py`, visqol-python's `VisqolApi`, and
  Google's C++ `VisqolManager` / `VisqolApi`.
- **Self-contained**: the SVR and lattice models are embedded, and the
  lattice model runs on a built-in TFLite interpreter.

## Usage

### CLI

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/visqol --reference_file ref.wav --degraded_file deg.wav
./zig-out/bin/visqol --batch_input_csv pairs.csv --results_csv out.csv --backend metal
```

Flags match upstream's (`--use_speech_mode`, `--use_lattice_model`,
`--search_window_radius`, `--disable_global_alignment`, …), plus
`--backend cpu|metal|cuda|vulkan` and `--threads N`. Batches use all cores by
default.

### C and Zig

`zig build` installs `libvisqol` (shared and static) and
[`visqol.h`](src/include/visqol.h): `visqol_create`, `visqol_measure`,
`visqol_measure_files`, `visqol_measure_batch`, … Zig projects can
`@import("visqol")`.

### Python

`pip install akvisqol` installs one `visqol` package that serves both
Python APIs unchanged. It replaces visqol-python's `visqol` package and
CLI, so don't install both in one environment. Wheels cover Linux (glibc
2.17+ and musl), macOS 13+ (with Metal) and Windows; building from source
needs zig 0.17 on PATH (or `VISQOL_ZIG`).

Google's `visqol_lib_py`:

```python
from visqol import visqol_lib_py
from visqol.pb2 import visqol_config_pb2

config = visqol_config_pb2.VisqolConfig()
config.audio.sample_rate = 48000
config.options.svr_model_path = visqol_lib_py.DefaultAudioModelFile()
api = visqol_lib_py.VisqolApi()
api.Create(config)
print(api.Measure(reference, degraded).moslqo)  # 1-D float64 arrays
```

[visqol-python](https://pypi.org/project/visqol-python/) 3.8.0:

```python
from visqol import VisqolApi

api = VisqolApi()
api.create(mode="audio")
result = api.measure("reference.wav", "degraded.wav")
```

Extensions to both: `backend="metal"` (or `VISQOL_BACKEND`), native-thread
batches (`MeasureBatch`, `measure_batch`), and `visqol.available_backends()`.
Native calls release the GIL; use one instance per thread. Speech mode
uses the lattice model by default with no extra packages.

### C++

[`src/cpp/`](src/cpp/) keeps upstream's headers and types
(`visqol_api.h`, `visqol_manager.h`, `absl::StatusOr<SimilarityResultMsg>`);
link `visqol::cpp`. Google's own benchmark driver builds against it
unchanged ([`tests/bench/visqol-cpp`](tests/bench/visqol-cpp/)).
Differences: `Run` takes `Span<const double>`s and a sample rate instead
of upstream's internal `AudioSignal`, `RunBatch` is added, and
`VISQOL_BACKEND` selects a GPU.

## Performance

Seconds per pair on an Apple M1 (4P + 4E cores), from
`nix develop .#bench -c python3 tests/bench/compare.py`. Each
implementation runs through its own API at its best (Google's Python
module and visqol-python through process pools), WAV decoding included,
startup subtracted. Audio: Google's ten 48 kHz conformance pairs. Speech:
the CA01 pair at 16 kHz.

| API | implementation | startup (s) | audio, 1T | audio, 8T | speech, 1T | speech, 8T | lattice, 8T |
|---|---|---:|---:|---:|---:|---:|---:|
| CLI / C | **this, CPU** | 0.01 | **0.346** | **0.081** | **0.055** | **0.013** | **0.012** |
| CLI / C | **this, Metal** | 0.05 | – | **0.030** | **0.013** | **0.006** | **0.006** |
| C++ | **this** | 0.03 | **0.349** | **0.079** | **0.056** | **0.012** | **0.012** |
| C++ | Google v3.3.3 | 0.01 | 13.410 | 2.589 | 1.445 | 0.257 | 0.249 |
| C++ | Google v3.3.3, LTO | 0.05 | 11.806 | 2.304 | 1.377 | 0.246 | 0.243 |
| `visqol_lib_py` | **this** | 0.12 | **0.350** | **0.080** | **0.056** | **0.012** | **0.012** |
| `visqol_lib_py` | Google | 0.10 | 13.587 | 2.571 | 1.423 | 0.248 | 0.249 |
| visqol-python | **this** | 0.11 | **0.350** | **0.083** | **0.056** | **0.013** | **0.013** |
| visqol-python | 3.8.0 + numba | 0.96 | 1.798 | 0.402 | 0.226 | 0.071 | 0.071 |

About 80% of Google's time is its gammatone IIR (`SignalFilter::Filter`):
scalar, with the filter state in a heap `valarray` so every step's
dependency goes through memory, and fresh allocations per frame and band.
This implementation runs the same recurrences in the same order, in
registers and vectorised across frames. Google is built as upstream
ships it (header-only Armadillo, no `-march`; CMake `-O3` where Bazel
uses `-O2`); this implementation also targets the baseline CPU. Each
workload runs twice, in alternating order, and the faster run counts.

## Verification

Largest |ΔMOS| over 50 audio, 73 speech and 64 lattice scores, against
Google's C++ on the same pairs and against Google's conformance values:

| implementation | vs C++: audio | speech | lattice | vs conformance: audio | speech | lattice |
|---|---:|---:|---:|---:|---:|---:|
| **this, CPU** (every API) | 8.1e-14 | 5.7e-13 | 3.2e-05 | 7.3e-14 | 5.7e-13 | 3.3e-06 |
| **this, Metal** | 5.1e-07 | 1.2e-07 | 3.0e-05 | 5.1e-07 | 1.2e-07 | 5.5e-06 |
| Google C++ / `visqol_lib_py` | 0 | 0 | 0 | 1.1e-14 | 0 | 3.6e-05 |
| visqol-python 3.8.0 | 1.2e-04 | 1.1e-03 | 2.4e-03 | 1.2e-04 | 1.1e-03 | 2.4e-03 |

- **Metal** kernels are f32 (see [Backends](#backends)). CUDA and Vulkan
  match the CPU bit for bit in f64, and within ~1e-7 (balanced) or ~5e-7
  (fast) in f32.
- **Lattice** gaps come from the summation order of the model's 4,096-term
  dot products. The built-in interpreter uses TFLite's builtin-kernel
  order (sequential f32 FMA); Google's build uses XNNPACK. Both are well
  inside upstream's 1e-4 tolerance. Against ai-edge-litert's builtin
  kernels the interpreter is identical on 10 of 11 inputs and within
  2.4e-6 on the last.

`zig build test` runs unit and conformance tests, and the GPU kernel tests
on every backend built in;
`src/python/tests` and `src/cpp/tests` cover the wrappers (conformance,
batching, errors, GPU parity at 1e-5).

## Building

| tier | adds | needs | build |
|---|---|---|---|
| 1 | `libvisqol`, `visqol.h`, CLI, Python package | zig 0.17 | `zig build -Doptimize=ReleaseFast`, `pip install .`, `nix build .#akvisqol` |
| 2 | C++ API | CMake, abseil, protobuf | `nix build .#akvisqol-cpp`, or CMake below |
| 3 | Google's C++ (± LTO, with TFLite 2.11), visqol-python, for comparison | nix | `nix develop .#bench -c python3 tests/bench/compare.py` |

```sh
zig build -Doptimize=ReleaseFast --prefix "$PWD/zig-out"
nix develop .#cpp -c sh -c 'cmake -S src/cpp -B build/cpp -DCMAKE_PREFIX_PATH=$PWD/zig-out \
    -DCMAKE_BUILD_TYPE=Release && cmake --build build/cpp && ctest --test-dir build/cpp'
```

Build options: `-Dmetal` (default on when the macOS Metal Toolchain
works), `-Dcuda`, `-Dstrip`, `-Dgammatone-lanes=N` (frames per SIMD vector
in the CPU filterbank; default two native vectors).

Wheels for other platforms cross-compile from any host:
`VISQOL_TARGET=aarch64-linux-musl uv build --wheel` (default: the host, with
glibc 2.17 on Linux). macOS wheels with Metal need a macOS host.

## Backends

| backend | flag | notes |
|---|---|---|
| `cpu` | always | f64 reference |
| `metal` | `-Dmetal` | needs the Xcode Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) |
| `cuda` | `-Dcuda` | needs `slangc` with NVRTC to build (`nix develop .#cuda`) and fetches the CUDA headers; loads `libcuda` at run time |
| `vulkan` | `-Dvulkan` | Vulkan 1.2 with `VK_KHR_push_descriptor`; fetches the Vulkan headers to build; loads the Vulkan loader at run time; not on musl |

The model talks to an `Accelerator` interface ([`src/accel.zig`](src/accel.zig))
covering the three hot spots: gammatone spectrograms, the DP
patch-similarity matrix, and the alignment cross-correlation.
[`src/gpu/engine.zig`](src/gpu/engine.zig) implements it with Slang kernels
on [zimt](zimt/README.md), a standalone Slang compute runtime that
generates typed Zig bindings from Slang reflection.

Batches spread over several GPU lanes (zimt devices: streams on CUDA,
queues on Vulkan and Metal) so worker threads overlap their transfers and
kernels; up to 4 on CUDA and 2 elsewhere, `VISQOL_GPU_LANES=N` to change.
Alignment lag peaks are found on the GPU and only candidates return.

GPU kernels are f32; normalisation, DP, statistics and quality mapping
stay f64 on the CPU. Gammatone filters run in delta form (direct form
loses ~1e-3 relative accuracy in the 50 Hz band in f32), and alignment
lags found by the f32 FFT are rescored in f64, so they are exact.

## Development

```sh
nix develop                       # zig 0.17, slangc, uv
tests/fetch_data.sh               # upstream conformance audio → tests/data/
zig build test                    # unit + conformance (-Dmetal=false for CPU only)
zig build python -Doptimize=ReleaseFast
PYTHONPATH=src/python python -m pytest src/python/tests   # the shell's numpy, protobuf, pytest
zig build shaders                 # regenerate src/gpu/generated/ (needs slangc, spirv-val)
zig build pb2                     # regenerate src/python/visqol/pb2
```

Generated MSL and reflection JSON are checked in, so the Metal build
needs no Slang; `xcrun metal` compiles them with IEEE math. The build
probes `/usr/bin/xcrun metal` (10 s timeout, nix SDK variables unset)
first; if the toolchain is missing, the default build drops Metal with a
warning and `-Dmetal=true` fails.

CUDA kernels compile to PTX with `slangc`, which loads NVRTC. The driver
library is `dlopen`ed rather than linked, so a CUDA build runs on machines
without an NVIDIA driver and reports `cuda` unavailable there.

Vulkan runs the checked-in SPIR-V, so it needs no Slang either; its API
bindings come from the Khronos headers through translate-c, fetched as a
lazy package dependency only for `-Dvulkan` builds. The loader is
`dlopen`ed too. `ZIMT_VULKAN_DEVICE=<index|name>` picks a device (e.g.
`llvmpipe` for Mesa's lavapipe), and `ZIMT_VULKAN_VALIDATION=1` runs under
the Khronos validation layer with synchronisation checks, failing on any
error; see [zimt](zimt/README.md#vulkan).

## Limitations

- No resampling, as upstream: both signals must share a sample rate.
  Audio mode expects 48 kHz (`allow_unsupported_sample_rates` overrides),
  and speech mode warns above 16 kHz.
- CUDA and Vulkan have been run only on Linux (RTX 3080, and lavapipe for
  Vulkan); their Windows paths and AMD/Intel Vulkan drivers are untested.
- The TFLite interpreter covers the 18 float ops in
  [`src/tflite.zig`](src/tflite.zig), enough for upstream's lattice model.

## License

Apache 2.0, as upstream. `src/model/` and `src/cpp/proto/` are from
google/visqol. Every file carries SPDX tags, inline or in
[`REUSE.toml`](REUSE.toml); check with
`uvx --from 'reuse[charset-normalizer]' reuse lint`.
