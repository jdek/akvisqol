# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

# libvisqol, the CLI and the Zig module. Metal only if the host's Metal Toolchain works.
{ lib, stdenvNoCC, zig_0_17, fixDarwinDylibNames, cctools }:

stdenvNoCC.mkDerivation {
  pname = "akvisqol";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [ ../build.zig ../build.zig.zon ../src ../zimt ../LICENSES ];
  };

  nativeBuildInputs = [ zig_0_17.hook ] ++ lib.optionals stdenvNoCC.hostPlatform.isDarwin [ fixDarwinDylibNames cctools ];
  dontUseZigCheck = true;
  # ReleaseFast instead of the hook's ReleaseSafe.
  dontSetZigDefaultFlags = true;
  # -Dcpu overrides build.zig's default target; restate zimt's metal_min_macos.
  zigBuildFlags = [ "--release=fast" "-Dcpu=baseline" ]
    ++ lib.optional stdenvNoCC.hostPlatform.isDarwin
      "-Dtarget=${stdenvNoCC.hostPlatform.parsed.cpu.name}-macos.13.0";
  # Zig skips the macOS SDK when NIX_CFLAGS_COMPILE / NIX_LDFLAGS are set.
  preBuild = ''
    unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
  '';

  meta = {
    description = "Fast ViSQOL (Zig) with optional Metal/CUDA backends";
    license = lib.licenses.asl20;
    mainProgram = "visqol";
  };
}
