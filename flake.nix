# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

{
  description = "ViSQOL in Zig, with Metal/CUDA acceleration and drop-in google/visqol and visqol-python APIs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      googlePythonFor = pkgs: args: pkgs.python3.buildEnv.override {
        extraLibs = [
          (pkgs.callPackage ./tests/bench/google/package.nix (args // { withPython = true; }))
          pkgs.python3.pkgs.protobuf
          pkgs.python3.pkgs.pybind11-abseil # status module
          pkgs.python3.pkgs.numpy
        ];
      };
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in {
      # Tiers (README "Building"): 1 = akvisqol, 2 = akvisqol-cpp, 3 = benchmarks.
      packages = forAllSystems (pkgs: let googlePython = googlePythonFor pkgs; in rec {
        akvisqol = pkgs.callPackage ./nix/visqol.nix { };
        default = akvisqol;
        akvisqol-cpp = pkgs.callPackage ./nix/visqol-cpp.nix { visqol = akvisqol; };
        # Tier 3: upstream ViSQOL at the conformance revision, with a timing driver.
        tensorflow-lite-static = pkgs.callPackage ./tests/bench/google/tflite.nix { };
        google-visqol = pkgs.callPackage ./tests/bench/google/package.nix { };
        # Upstream's Bazel build has no LTO.
        google-visqol-lto = pkgs.callPackage ./tests/bench/google/package.nix { lto = true; };
        google-visqol-python = googlePython { };
        google-visqol-python-lto = googlePython { lto = true; };
        visqol-cpp-bench = pkgs.callPackage ./tests/bench/visqol-cpp/package.nix { visqol = akvisqol; };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [ zig_0_17 shader-slang uv python3 ];
          # Zig skips the macOS SDK when these are set.
          shellHook = ''
            unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
          '';
        };
        cpp = pkgs.mkShell {
          packages = with pkgs; [ cmake abseil-cpp protobuf ];
        };
        # `nix develop .#bench -c python3 tests/bench/compare.py`; visqol-python comes from PyPI via uv.
        bench = let p = self.packages.${pkgs.stdenv.hostPlatform.system}; in pkgs.mkShellNoCC {
          packages = [
            (pkgs.python3.withPackages (ps: [ ps.numpy ps.protobuf ]))
            pkgs.uv
          ];
          VISQOL_PREFIX = p.akvisqol;
          VISQOL_CPP_BENCH = p.visqol-cpp-bench;
          GOOGLE_VISQOL = p.google-visqol;
          GOOGLE_VISQOL_LTO = p.google-visqol-lto;
          GOOGLE_VISQOL_PYTHON = p.google-visqol-python;
          GOOGLE_VISQOL_PYTHON_LTO = p.google-visqol-python-lto;
        };
      });
    };
}
