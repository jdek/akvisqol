# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

# Static TensorFlow Lite 2.11 + XNNPACK (upstream's pin); nixpkgs' is broken.
# Downloads pinned to the commits TFLite's CMake names. Its own abseil uses a
# different inline namespace from nixpkgs', so both can share a binary.
{ lib, stdenv, cmake, fetchFromGitHub, fetchFromGitLab, fetchzip }:

let
  gh = owner: repo: rev: hash: fetchFromGitHub { inherit owner repo rev hash; };
  src = gh "tensorflow" "tensorflow" "v2.11.0" "sha256-OYh61/83yv+ycivylfdS8yFUIUAk8euAPvmfjPzldGs=";
  deps = {
    abseil-cpp = gh "abseil" "abseil-cpp" "273292d1cfc0a94a65082ee350509af1d113344d" "sha256-cnvLcBaznltTHJ5FSTuHhsRMmsDbJ9gyvhrBOdul288=";
    eigen = fetchFromGitLab {
      owner = "libeigen";
      repo = "eigen";
      rev = "3bb6a48d8c171cf20b5f8e48bfb4e424fbd4f79e";
      hash = "sha256-k71DoEsx8JpC9AlQ0cCRI0fWMIWFBFL/Yscx+2iBtNM=";
    };
    farmhash = gh "google" "farmhash" "0d859a811870d10f53a594927d0d0b97573ad06d" "sha256-J0AhHVOvPFT2SqvQ+evFiBoVfdHthZSBXzAhUepARfA=";
    fft2d = fetchzip {
      url = "https://storage.googleapis.com/mirror.tensorflow.org/github.com/petewarden/OouraFFT/archive/v1.0.tar.gz";
      hash = "sha256-mkG6jWuMVzCB433qk2wW/HPA9vp/LivPTDa2c0hFir4=";
    };
    flatbuffers = gh "google" "flatbuffers" "v2.0.6" "sha256-0bJ0n/5yzj6lHXLKJzHUS0Bnlmys+X7pY/3LGapVh6k=";
    fp16_headers = gh "Maratyszcza" "FP16" "0a92994d729ff76a58f692d3028ca1b64b145d91" "sha256-m2d9bqZoGWzuUPGkd29MsrdscnJRtuIkLIMp3fMmtRY=";
    gemmlowp = gh "google" "gemmlowp" "fda83bdc38b118cc6b56753bd540caa49e570745" "sha256-tE+w72sfudZXWyMxG6CGMqXYswve57/cpvwrketEd+k=";
    ruy = gh "google" "ruy" "841ea4172ba904fe3536789497f9565f2ef64129" "sha256-KtduRl9HUxUhNdgm+M8nU55zwbt1P+QRRLoePFRwh9g=";
    cpuinfo = gh "pytorch" "cpuinfo" "5e63739504f0f8e18e941bd63b2d6d42536c7d90" "sha256-5no9LkQIIOIidvhera5lIbnOUkcZQtW4nIUqXSLnWHA=";
    # Required by TFLite's CMake on every architecture.
    neon2sse = fetchzip {
      url = "https://storage.googleapis.com/mirror.tensorflow.org/github.com/intel/ARM_NEON_2_x86_SSE/archive/a15b489e1222b2087007546b4912e21293ea86ff.tar.gz";
      hash = "sha256-299ZptvdTmCnIuVVBkrpf5ZTxKPwgcGUob81tEI91F0=";
    };
    xnnpack = gh "google" "XNNPACK" "e8f74a9763aa36559980a0c2f37f587794995622" "sha256-+SvG24jtD6tk/b3lQdMkoqrlI6GoOkHuc6ILMMnPLdg=";
  };
  # XNNPACK's and FP16's downloads (psimd is archived at this commit).
  xnnpackDeps = {
    PSIMD = gh "Maratyszcza" "psimd" "072586a71b55b7f8c584153d223e95687148a900" "sha256-lV+VZi2b4SQlRYrhKx9Dxc6HlDEFz3newvcBjTekupo=";
    FXDIV = gh "Maratyszcza" "FXdiv" "b408327ac2a15ec3e43352421954f5b1967701d1" "sha256-BEjscsejYVhRxDAmah5DT3+bglp8G5wUTTYL7+HjWds=";
    PTHREADPOOL = gh "Maratyszcza" "pthreadpool" "545ebe9f225aec6dca49109516fac02e973a3de2" "sha256-sBpMElc8kUYV6EfLD+OmrZZzeN6NDdu3U4/cInAny7M=";
    FP16 = deps.fp16_headers;
  };
in
stdenv.mkDerivation {
  pname = "tensorflow-lite-static";
  version = "2.11.0";
  inherit src;

  nativeBuildInputs = [ cmake ];
  # tensorflow/ has a Bazel BUILD file; macOS file systems fold case.
  cmakeBuildDir = "cmake-build";

  # Some of these CMake projects write next to their sources.
  preConfigure = ''
    mkdir -p "$NIX_BUILD_TOP/deps"
    ${lib.concatStrings (lib.mapAttrsToList (n: p: ''
      cp -r --no-preserve=mode ${p} "$NIX_BUILD_TOP/deps/${n}"
    '') (deps // lib.mapAttrs' (n: lib.nameValuePair "xnn-${n}") xnnpackDeps))}
    # flatbuffers 2.0.6's span assigns to a const member, which current
    # clang rejects (fixed upstream in 2.0.8 the same way).
    substituteInPlace "$NIX_BUILD_TOP/deps/flatbuffers/include/flatbuffers/stl_emulation.h" \
      --replace-fail "  const size_type count_;" "  size_type count_;"
    # abseil 2022 passes -Xarch_x86_64 -msse4.1 on Apple clang, which the
    # cc wrapper does not filter; use its per-CMAKE_SYSTEM_PROCESSOR flags.
    substituteInPlace "$NIX_BUILD_TOP/deps/abseil-cpp/absl/copts/AbseilConfigureCopts.cmake" \
      --replace-fail "if(APPLE AND CMAKE_CXX_COMPILER_ID MATCHES [[Clang]])" "if(FALSE)"
    # std::abs is no longer a template in current libc++.
    substituteInPlace tensorflow/lite/kernels/elementwise.cc \
      --replace-fail "std::abs<float>," "[](float x) { return std::abs(x); }," \
      --replace-fail "std::abs<int32_t>(" "std::abs("
    cmakeDir=$PWD/tensorflow/lite
    cmakeFlagsArray+=(
      ${lib.concatStrings (lib.mapAttrsToList (n: _: ''
        "-DFETCHCONTENT_SOURCE_DIR_${lib.toUpper n}=$NIX_BUILD_TOP/deps/${n}"
      '') deps)}
      ${lib.concatStrings (lib.mapAttrsToList (n: _: ''
        "-D${n}_SOURCE_DIR=$NIX_BUILD_TOP/deps/xnn-${n}"
      '') xnnpackDeps)}
      # One cpuinfo for TFLite and XNNPACK; it builds clog from its deps/.
      "-DCPUINFO_SOURCE_DIR=$NIX_BUILD_TOP/deps/cpuinfo"
      "-DCLOG_SOURCE_DIR=$NIX_BUILD_TOP/deps/cpuinfo/deps/clog"
    )
  '';

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
    # 2022-era dependencies declare cmake_minimum_required < 3.5.
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    "-DTFLITE_ENABLE_XNNPACK=ON"
    "-DTFLITE_ENABLE_GPU=OFF"
    "-DTFLITE_ENABLE_NNAPI=OFF"
    "-DTFLITE_ENABLE_EXTERNAL_DELEGATE=OFF"
    "-DXNNPACK_BUILD_TESTS=OFF"
    "-DXNNPACK_BUILD_BENCHMARKS=OFF"
  ] ++ lib.optionals stdenv.hostPlatform.isDarwin [
    # Otherwise abseil 2022 picks x86 SSE flags on Apple silicon.
    "-DCMAKE_OSX_ARCHITECTURES=${stdenv.hostPlatform.darwinArch}"
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/include
    find . -name '*.a' -exec cp {} $out/lib/ \;
    (cd $NIX_BUILD_TOP/source && find tensorflow -name '*.h' -exec install -Dm644 {} $out/include/{} \;)
    cp -r $NIX_BUILD_TOP/deps/flatbuffers/include/flatbuffers $out/include/
    runHook postInstall
  '';

  meta = {
    description = "TensorFlow Lite 2.11 (CMake, XNNPACK) static libraries for tests/bench/google";
    license = lib.licenses.asl20;
  };
}
