# Google ViSQOL (C++) for side-by-side comparison

Builds upstream [google/visqol](https://github.com/google/visqol) at the
revision whose conformance scores this project reproduces
(`38d0b01`, v3.3.3), plus `visqol_google_bench`: a small driver that
scores the same `reference,degraded` CSV as `visqol --batch_input_csv`
and reports wall time.

```sh
nix build .#google-visqol -o result-google            # as upstream ships it
nix build .#google-visqol-lto -o result-google-lto    # + link-time optimisation
result-google/bin/visqol_google_bench --batch_input_csv pairs.csv \
    [--threads N] [--results_csv out.csv] [--use_speech_mode]

# Upstream's pybind11 module, in an interpreter with protobuf and numpy:
nix build .#google-visqol-python -o result-google-py  # or -python-lto
result-google-py/bin/python3 -c 'from visqol import visqol_lib_py'
```

The same driver also builds, unchanged, against this project's C++ API
(`nix build .#visqol-cpp-bench`, see [`../visqol-cpp`](../visqol-cpp/)).
`../compare.py` runs all of these; see the main README's Performance
section.

How this differs from upstream's own Bazel build:

- **Dependencies.** Sources are pinned exactly as in upstream's
  `WORKSPACE` (libsvm 3.24, pffft `7c3b5a7`, header-only Armadillo
  14.2.3). abseil and protobuf come from nixpkgs, because upstream's pins
  (abseil 20211102, protobuf 3.19) no longer build with current
  compilers. Neither is on a hot path.
- **Lattice model.** Upstream's TFLite lattice mapper is built as is,
  against TensorFlow Lite 2.11 (the version upstream's `WORKSPACE` pins)
  with the XNNPACK delegate, from [`tflite.nix`](tflite.nix). TFLite's
  CMake build replaces Bazel, with every dependency pinned to the commit
  TFLite's CMake modules name. Four fixes let 2022-era sources build with
  current clang and CMake: a CMake policy minimum, flatbuffers 2.0.6's
  `const` span member, abseil's x86 flags on Apple silicon, and
  `std::abs<float>` in one kernel. The timing driver maps speech with the
  exponential fit unless `--use_lattice_model` is given.
- **Python module.** `python/visqol_lib_py.cc` is built with CMake
  instead of Bazel. It uses pybind11_abseil from nixpkgs and
  pybind11_protobuf from nixpkgs' or-tools recipe, and installs in
  upstream's `setup.py` layout (`visqol/visqol_lib_py*.so`,
  `visqol/pb2`, `visqol/model`). The bindings do not release the GIL,
  so parallel use needs processes.
- **Threads.** `--threads N` runs N workers, each with its own
  `VisqolManager`; the default `1` matches upstream's CLI. Wall time
  includes model loading and WAV decoding, as for the Zig CLI.
- **Optimisation.** Upstream's build has no LTO, so the `AMatrix`
  element accessors, defined out of line in `amatrix.cc`, are real
  function calls in the hot loops. The `-lto` variant lets the compiler
  inline them.

Outside nix, configure `CMakeLists.txt` with `-DVISQOL_SRC=…`,
`-DLIBSVM_SRC=…`, `-DPFFFT_SRC=…` and `-DARMADILLO_INCLUDE=…`, and have
abseil and protobuf CMake packages installed.
