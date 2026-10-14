# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

# Upstream ViSQOL + timing driver, deps pinned as upstream's WORKSPACE. abseil and
# protobuf from nixpkgs: upstream's pins no longer build with current compilers.
{ lib, stdenv, callPackage, cmake, abseil-cpp, protobuf, fetchFromGitHub, fetchgit, fetchzip, path
, python3, lto ? false
, withPython ? false
}:

let
  visqol = fetchFromGitHub {
    owner = "google";
    repo = "visqol";
    rev = "38d0b0163e441047d4429bf07ad09e5b9031d02c";
    hash = "sha256-0wTP7hko/4a8FMKu5Yarw+ut2piGjGoMMBdeiFuYR6Q=";
  };
  libsvm = fetchFromGitHub {
    owner = "cjlin1";
    repo = "libsvm";
    rev = "v324";
    hash = "sha256-qLz/3OqXHQY/zW2RJQmJySKvmZ7Nb4PeNRgPXK8HuJ0=";
  };
  pffft = fetchgit {
    url = "https://bitbucket.org/jpommier/pffft.git";
    rev = "7c3b5a7dc510a0f513b9c5b6dc5b56f7aeeda422";
    hash = "sha256-X+7ZDXaURWpNLh0PuEw4VhbUpGupgjwWezcraLJYcgo=";
  };
  # Headers only, as upstream (no BLAS/LAPACK wrapper library).
  armadillo = fetchzip {
    url = "mirror://sourceforge/arma/armadillo-14.2.3.tar.xz";
    hash = "sha256-iA+Xo35nld171B/apBCaYfxHPotouachYuNrLx175/0=";
  };
  py = python3.pkgs;
  # Upstream's lattice mapper links TensorFlow Lite 2.11 with XNNPACK.
  tflite = callPackage ./tflite.nix { };
  # nixpkgs carries pybind11_protobuf only inside or-tools' recipe.
  pybind11-protobuf = py.callPackage "${path}/pkgs/by-name/or/or-tools/pybind11-protobuf.nix" {
    abseil-cpp_202508 = abseil-cpp;
    inherit protobuf; # C++, not python3.pkgs.protobuf
  };
in
stdenv.mkDerivation {
  pname = "google-visqol" + lib.optionalString withPython "-python" + lib.optionalString lto "-lto";
  version = "3.3.3-unstable-38d0b01";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./CMakeLists.txt ./visqol_google_bench.cc ./stub ];
  };

  nativeBuildInputs = [ cmake protobuf ];
  buildInputs = [ abseil-cpp protobuf ]
    ++ lib.optionals withPython [ python3 py.pybind11 py.pybind11-abseil pybind11-protobuf ];

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DVISQOL_SRC=${visqol}"
    "-DLIBSVM_SRC=${libsvm}"
    "-DPFFFT_SRC=${pffft}"
    "-DARMADILLO_INCLUDE=${armadillo}/include"
    "-DTFLITE_PREFIX=${tflite}"
    (lib.cmakeBool "GOOGLE_VISQOL_LTO" lto)
    (lib.cmakeBool "GOOGLE_VISQOL_PYTHON" withPython)
  ] ++ lib.optionals withPython [
    "-DGOOGLE_VISQOL_PYTHON_SITE=${python3.sitePackages}"
    "-DPython_EXECUTABLE=${python3.interpreter}"
  ];
  passthru = { inherit tflite; } // lib.optionalAttrs withPython { pythonModule = python3; };

  meta = {
    description = "Google ViSQOL (C++) with a batch timing driver";
    license = lib.licenses.asl20;
    mainProgram = "visqol_google_bench";
  };
}
