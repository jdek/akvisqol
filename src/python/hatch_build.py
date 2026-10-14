# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

"""Hatch hook: build libvisqol with Zig and bundle it into the wheel.

Env:
  VISQOL_ZIG          zig executable (default: `zig` on PATH; 0.17.x)
  VISQOL_ZIG_FLAGS    extra `zig build` flags, e.g. "-Dcuda=true"
  VISQOL_TARGET       Zig target to build the wheel for (default: host; on
                      Linux `<arch>-linux-gnu.2.17`). Zig cross-compiles, so
                      Linux (glibc or musl) and Windows wheels build from any
                      host; macOS wheels with Metal need a macOS host.
"""

from __future__ import annotations

import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

# build.zig's default macOS deployment target (zimt.metal_min_macos).
MACOS_MIN = "13.0"
# Oldest glibc for Linux wheels: manylinux2014.
GLIBC_MIN = "2.17"

ARCHES = {"arm64": "aarch64", "amd64": "x86_64", "x64": "x86_64"}


def host_target() -> str:
    arch = platform.machine().lower()
    arch = ARCHES.get(arch, arch)
    if sys.platform == "darwin":
        return f"{arch}-macos.{MACOS_MIN}"
    if sys.platform == "win32":
        return f"{arch}-windows-gnu"
    return f"{arch}-linux-gnu.{GLIBC_MIN}"


def wheel_platforms(target: str) -> tuple[str, list[str]]:
    """(shared library name, wheel platform tags) for a Zig target triple."""
    m = re.fullmatch(r"(\w+)-(\w+)(?:\.([\d.]+)(?:\.\.\.[\d.]+)?)?(?:-(\w+)(?:\.([\d.]+))?)?", target)
    if not m:
        raise RuntimeError(f"VISQOL_TARGET={target!r}: expected <arch>-<os>[.version][-<abi>[.version]]")
    arch, os_, os_ver, abi, abi_ver = m.groups()
    if os_ == "macos":
        major, minor = ((os_ver or MACOS_MIN).split(".") + ["0"])[:2]
        mac_arch = "arm64" if arch == "aarch64" else arch
        return "libvisqol.dylib", [f"macosx_{major}_{minor}_{mac_arch}"]
    if os_ == "windows":
        return "visqol.dll", [{"x86_64": "win_amd64", "aarch64": "win_arm64"}[arch]]
    if os_ == "linux":
        if abi == "musl":
            # Zig ships musl 1.2.
            return "libvisqol.so", [f"musllinux_1_2_{arch}"]
        major, minor = (abi_ver or GLIBC_MIN).split(".")[:2]
        tags = [f"manylinux_{major}_{minor}_{arch}"]
        if (major, minor) == ("2", "17"):
            tags.append(f"manylinux2014_{arch}")
        return "libvisqol.so", tags
    raise RuntimeError(f"VISQOL_TARGET={target!r}: no wheel platform for OS {os_!r}")


class ZigBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version, build_data):
        if self.target_name != "wheel":
            return
        root = Path(self.root)
        zig = os.environ.get("VISQOL_ZIG") or shutil.which("zig")
        if not zig:
            raise RuntimeError("zig (0.17.x) is required to build visqol; set VISQOL_ZIG or put zig on PATH")
        flags = shlex.split(os.environ.get("VISQOL_ZIG_FLAGS", ""))
        target = os.environ.get("VISQOL_TARGET") or host_target()
        name, platforms = wheel_platforms(target)
        built = root / "src" / "python" / "visqol" / "_lib" / name
        built.unlink(missing_ok=True)
        cmd = [zig, "build", "python", "-Doptimize=ReleaseFast", "-Dstrip=true", f"-Dtarget={target}", *flags]
        subprocess.run(cmd, cwd=root, check=True)
        build_data["force_include"][str(built)] = f"visqol/_lib/{name}"
        build_data["pure_python"] = False
        # ctypes, not an extension module: py3-none works for every Python 3.
        build_data["tag"] = f"py3-none-{'.'.join(platforms)}"
