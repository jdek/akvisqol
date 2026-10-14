# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

# The upstream timing driver built against src/cpp/.
{ lib, stdenv, cmake, abseil-cpp, protobuf, visqol }:

stdenv.mkDerivation {
  pname = "visqol-cpp-bench";
  inherit (visqol) version;
  src = lib.fileset.toSource {
    root = ../../..;
    fileset = lib.fileset.unions [
      ../../../src/cpp
      ../google/visqol_google_bench.cc
      ./CMakeLists.txt
    ];
  };
  sourceRoot = "source/tests/bench/visqol-cpp";

  nativeBuildInputs = [ cmake protobuf ];
  buildInputs = [ abseil-cpp protobuf visqol ];
  cmakeFlags = [ "-DCMAKE_BUILD_TYPE=Release" "-DCMAKE_PREFIX_PATH=${visqol}" ];

  meta = {
    description = "visqol_google_bench over libvisqol's google/visqol C++ API";
    license = lib.licenses.asl20;
    mainProgram = "visqol_cpp_bench";
  };
}
