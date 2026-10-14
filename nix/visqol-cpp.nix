# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

# google/visqol's C++ API over libvisqol.
{ lib, stdenv, cmake, abseil-cpp, protobuf, visqol }:

stdenv.mkDerivation {
  pname = "akvisqol-cpp";
  inherit (visqol) version;
  src = lib.fileset.toSource {
    root = ../.;
    fileset = ../src/cpp;
  };
  sourceRoot = "source/src/cpp";

  nativeBuildInputs = [ cmake protobuf ];
  buildInputs = [ abseil-cpp protobuf ];
  propagatedBuildInputs = [ visqol abseil-cpp protobuf ];
  cmakeFlags = [ "-DCMAKE_PREFIX_PATH=${visqol}" ];

  # Unit checks only; conformance audio is not in the sandbox.
  doCheck = true;

  meta = {
    description = "google/visqol C++ API backed by libvisqol";
    license = lib.licenses.asl20;
  };
}
