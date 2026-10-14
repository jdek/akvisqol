# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

"""Speed and agreement of this ViSQOL against upstream and visqol-python.

    nix develop .#bench -c python3 tests/bench/compare.py [--repeat 4] [--only REGEX]

Startup is a one-pair run minus the marginal per-pair cost, subtracted once
from each wall time. Agreement is max |dMOS| against upstream C++ and the
conformance values.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNNER = Path(__file__).resolve().parent / "runner.py"
AUDIO_DIR = "tests/data/conformance_testdata_subset"
SPEECH_DIR = "tests/data/clean_speech"
VISQOL_PYTHON_VERSION = "3.8.0"

# Upstream conformance values.
AUDIO_CASES = [
    ("strauss48_stereo.wav", "strauss48_stereo_lp35.wav", 1.3888791489130758),
    ("steely48_stereo.wav", "steely48_stereo_lp7.wav", 2.2501683734385183),
    ("sopr48_stereo.wav", "sopr48_stereo_256kbps_aac.wav", 4.68228969737946),
    ("ravel48_stereo.wav", "ravel48_stereo_128kbps_opus.wav", 4.465141897255348),
    ("moonlight48_stereo.wav", "moonlight48_stereo_128kbps_aac.wav", 4.684292801646114),
    ("harpsichord48_stereo.wav", "harpsichord48_stereo_96kbps_mp3.wav", 4.22374532766003),
    ("guitar48_stereo.wav", "guitar48_stereo_64kbps_aac.wav", 4.349722308064298),
    ("glock48_stereo.wav", "glock48_stereo_48kbps_aac.wav", 4.332452943882108),
    ("contrabassoon48_stereo.wav", "contrabassoon48_stereo_24kbps_aac.wav", 2.346868205375293),
    ("castanets48_stereo.wav", "castanets48_stereo.wav", 4.732101253042348),
]
# Speech mode: exponential mapping, then TF-Lattice.
SPEECH_CASES = [("CA01_01.wav", "transcoded_CA01_01.wav", 3.374505555111911)]
SPEECH_LATTICE_EXPECTED = 3.3129234313964844
SPEECH_SINGLE = 9  # with the one-pair run, gives startup cost
SPEECH_PER_THREAD = 8  # all-core speech pairs per thread


@dataclass
class Impl:
    name: str
    api: str  # "CLI", "C++", "visqol_lib_py", "visqol-python"
    ours: bool
    kind: str  # "native" (CSV results) or a runner.py API
    exe: list[str] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)
    extra: list[str] = field(default_factory=list)
    exponential_args: list[str] = field(default_factory=list)
    lattice_args: list[str] = field(default_factory=lambda: ["--use_lattice_model"])
    single: bool = True  # has a one-thread configuration
    note: str = ""


def env_path(var: str) -> Path | None:
    v = os.environ.get(var)
    return Path(v) if v else None


def visqol_python_env(build: Path) -> Path:
    venv = build / "visqol-python"
    py = venv / "bin" / "python"
    uv = shutil.which("uv")
    if uv is None:
        sys.exit("uv not found; run inside `nix develop .#bench`")
    if not py.exists():
        subprocess.run([uv, "venv", "-q", "--python", "3.13", str(venv)], check=True)
    # ai-edge-litert enables its lattice mapping.
    subprocess.run([uv, "pip", "install", "-q", "--python", str(py),
                    f"visqol-python=={VISQOL_PYTHON_VERSION}", "numba", "ai-edge-litert"], check=True)
    return py


def implementations(build: Path) -> list[Impl]:
    prefix = env_path("VISQOL_PREFIX")
    if prefix is None:
        sys.exit("VISQOL_PREFIX is not set; run inside `nix develop .#bench`")
    ours_py_env = {"PYTHONPATH": str(ROOT / "src" / "python"),
                   "VISQOL_LIBRARY": str(prefix / "lib" / ("libvisqol.dylib" if sys.platform == "darwin"
                                                           else "libvisqol.so"))}
    impls = [
        # CLI defaults to lattice in speech mode, like upstream.
        Impl("visqol (cpu)", "CLI", True, "native", [str(prefix / "bin" / "visqol"), "--backend", "cpu"],
             exponential_args=["--nouse_lattice_model"], lattice_args=[]),
    ]
    if sys.platform == "darwin":
        impls.append(Impl("visqol (metal)", "CLI", True, "native",
                          [str(prefix / "bin" / "visqol"), "--backend", "metal"], single=False,
                          exponential_args=["--nouse_lattice_model"], lattice_args=[]))
    if p := env_path("VISQOL_CPP_BENCH"):
        impls.append(Impl("visqol C++ API", "C++", True, "native", [str(p / "bin" / "visqol_cpp_bench")]))
    for var, name in (("GOOGLE_VISQOL", "Google C++"), ("GOOGLE_VISQOL_LTO", "Google C++ (LTO)")):
        if p := env_path(var):
            impls.append(Impl(name, "C++", False, "native", [str(p / "bin" / "visqol_google_bench")]))
    impls.append(Impl("visqol visqol_lib_py", "visqol_lib_py", True, "google", [sys.executable],
                      ours_py_env, ["--pool", "thread"], note="threads (ctypes drops the GIL)"))
    for var, name in (("GOOGLE_VISQOL_PYTHON", "Google visqol_lib_py"),
                      ("GOOGLE_VISQOL_PYTHON_LTO", "Google visqol_lib_py (LTO)")):
        if p := env_path(var):
            impls.append(Impl(name, "visqol_lib_py", False, "google", [str(p / "bin" / "python3")],
                              extra=["--pool", "process"], note="process pool (bindings hold the GIL)"))
    impls.append(Impl("visqol VisqolApi", "visqol-python", True, "visqol-python", [sys.executable],
                      ours_py_env, note="measure_batch: native threads"))
    impls.append(Impl(f"visqol-python {VISQOL_PYTHON_VERSION} + numba", "visqol-python", False,
                      "visqol-python", [str(visqol_python_env(build))],
                      note="measure_batch: process pool"))
    return impls


def write_pairs(path: Path, cases, directory: str, repeat: int) -> list[tuple[str, str]]:
    pairs = [(f"{directory}/{r}", f"{directory}/{d}") for r, d, _ in cases] * repeat
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["reference", "degraded"])
        w.writerows(pairs)
    return pairs


def run(impl: Impl, pairs_csv: Path, n: int, threads: int, mapping: str | None, tmp: Path):
    """`mapping`: None (audio), "exponential" or "lattice" (speech).
    Returns (seconds, [moslqo or None])."""
    out = tmp / "out"
    out.unlink(missing_ok=True)
    env = {**os.environ, **impl.env}
    if impl.kind == "native":
        argv = [*impl.exe, "--batch_input_csv", str(pairs_csv), "--results_csv", str(out),
                "--threads", str(threads)]
        if mapping:
            argv += ["--use_speech_mode",
                     *(impl.lattice_args if mapping == "lattice" else impl.exponential_args)]
    else:
        argv = [*impl.exe, str(RUNNER), impl.kind, str(pairs_csv), str(out), "--threads", str(threads),
                *impl.extra]
        if mapping:
            argv += ["--speech", *(["--lattice"] if mapping == "lattice" else [])]
        if impl.kind == "visqol-python" and not impl.ours and threads == 1:
            env["NUMBA_NUM_THREADS"] = "1"  # its numba kernels are prange-parallel
    t0 = time.perf_counter()
    p = subprocess.run(argv, cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    secs = time.perf_counter() - t0
    if not out.exists():
        print(f"  {impl.name} failed ({p.returncode}): {p.stderr.strip()[-500:]}", file=sys.stderr)
        return secs, [None] * n
    if impl.kind == "native":
        with open(out) as f:
            mos = [float(r["moslqo"]) for r in csv.DictReader(f)]
        if len(mos) != n:  # failed pairs are omitted from the CSV
            print(f"  {impl.name}: {n - len(mos)} pair(s) failed: {p.stderr.strip()[-500:]}", file=sys.stderr)
            return secs, [None] * n
        return secs, mos
    with open(out) as f:
        res = json.load(f)
    if any(res["errors"]):
        print(f"  {impl.name}: {next(e for e in res['errors'] if e)}", file=sys.stderr)
    return secs, res["moslqo"]


def max_delta(a, b):
    if not a or not b or any(v is None for v in a) or any(v is None for v in b):
        return None
    return max(abs(x - y) for x, y in zip(a, b))


def fmt_d(x):
    return "—" if x is None else ("0" if x == 0 else f"{x:.1e}")


def machine() -> str:
    cpu = platform.processor()
    if sys.platform == "darwin":
        cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True,
                             text=True).stdout.strip() or cpu
    return f"{cpu}, {os.cpu_count()} cores, {platform.system()} {platform.release()}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repeat", type=int, default=4, help="all-core runs score the audio pairs this many times")
    ap.add_argument("--threads", type=int, default=os.cpu_count() or 1)
    ap.add_argument("--only", help="regex: implementations to run (Google C++ always runs as the reference)")
    ap.add_argument("--rounds", type=int, default=2, help="runs per workload, alternating order; best counts")
    ap.add_argument("--skip-single", action="store_true", help="skip the one-thread runs")
    ap.add_argument("--json", type=Path, default=ROOT / "build" / "bench" / "compare.json")
    a = ap.parse_args()

    build = ROOT / "build" / "bench"
    build.mkdir(parents=True, exist_ok=True)
    impls = implementations(build)
    if a.only:
        impls = [i for i in impls if re.search(a.only, i.name) or i.name == "Google C++"]
    tmp = Path(tempfile.mkdtemp(dir=build))
    audio1 = write_pairs(tmp / "audio1.csv", AUDIO_CASES, AUDIO_DIR, 1)
    audioN = write_pairs(tmp / "audioN.csv", AUDIO_CASES, AUDIO_DIR, a.repeat)
    speech1 = write_pairs(tmp / "speech1.csv", SPEECH_CASES, SPEECH_DIR, SPEECH_SINGLE)
    speechN = write_pairs(tmp / "speechN.csv", SPEECH_CASES, SPEECH_DIR, SPEECH_PER_THREAD * a.threads)
    write_pairs(tmp / "one.csv", SPEECH_CASES, SPEECH_DIR, 1)
    write_pairs(tmp / "warm.csv", AUDIO_CASES[-1:], AUDIO_DIR, 1)

    # (key, csv, pairs, threads, speech mapping, needs a one-thread configuration)
    EXP, LAT = "exponential", "lattice"
    workloads = [("one", tmp / "one.csv", 1, 1, EXP, False)]
    if not a.skip_single:
        workloads.append(("audio 1 thread", tmp / "audio1.csv", len(audio1), 1, None, True))
    workloads.append((f"audio {a.threads} threads", tmp / "audioN.csv", len(audioN), a.threads, None, False))
    workloads.append(("speech 1 thread", tmp / "speech1.csv", len(speech1), 1, EXP, False))
    workloads.append((f"speech {a.threads} threads", tmp / "speechN.csv", len(speechN), a.threads, EXP, False))
    workloads.append((f"lattice {a.threads} threads", tmp / "speechN.csv", len(speechN), a.threads, LAT, False))

    # Alternate order each round to avoid warm/cold bias; fastest round counts.
    results: dict[str, dict] = {i.name: {} for i in impls}
    for rnd in range(a.rounds):
        for impl in (impls if rnd % 2 == 0 else impls[::-1]):
            if rnd == 0:
                print(f"{impl.name}: warm-up", file=sys.stderr)
                run(impl, tmp / "warm.csv", 1, 1, None, tmp)
            r = results[impl.name]
            for key, csv_path, n, th, mapping, needs_single in workloads:
                if needs_single and not impl.single:
                    continue
                secs, mos = run(impl, csv_path, n, th, mapping, tmp)
                print(f"{impl.name}: round {rnd + 1}: {key}: {secs:.2f} s", file=sys.stderr)
                prev = r.get(key)
                if prev and (d := max_delta(prev["moslqo"], mos)):
                    print(f"  {impl.name}: {key}: scores differ between rounds by up to {d:.1e}",
                          file=sys.stderr)
                if prev is None or secs < prev["seconds"]:
                    r[key] = {"seconds": secs, "pairs": n, "moslqo": mos, "rounds": [*(prev or {}).get("rounds", []), secs]}
                else:
                    prev["rounds"].append(secs)

    ref = results.get("Google C++", {})
    expect_audio = [c[2] for c in AUDIO_CASES]
    expect_speech = [c[2] for c in SPEECH_CASES]
    keys = [k for k, *_ in workloads if k != "one"]
    speech_keys = [k for k in keys if k.startswith("speech")]
    lattice_keys = [k for k in keys if k.startswith("lattice")]

    def startup(r):
        one, many = r.get("one"), r.get("speech 1 thread")
        if not one or not many:
            return None
        marginal = (many["seconds"] - one["seconds"]) / (many["pairs"] - 1)
        return max(0.0, one["seconds"] - marginal)

    print(f"\n{machine()}. Best of {a.rounds} round(s). Audio: {len(audio1)} pairs on 1 thread; the same "
          f"pairs ×{a.repeat} on {a.threads} threads. Speech (exponential mapping): {len(speech1)} "
          f"pairs on 1 thread, {len(speechN)} on {a.threads} threads; lattice: the same "
          f"{len(speechN)} with the TF-Lattice mapping.\n")
    print("Startup: seconds before the first pair (process, imports, model, JIT). Other columns: wall "
          "seconds per pair with startup subtracted once (lower is better); scaling = 1-thread / "
          "all-thread time per pair.\n")
    cols = ["startup"] + [k for k in keys if k.startswith("audio")] + ["scaling"] + speech_keys + lattice_keys
    print("| API | implementation | " + " | ".join(cols) + " | notes |")
    print("|---|---|" + "---:|" * len(cols) + "---|")
    single, multi = ("audio 1 thread", f"audio {a.threads} threads")
    for impl in sorted(impls, key=lambda i: (["CLI", "C++", "visqol_lib_py", "visqol-python"].index(i.api),
                                             not i.ours)):
        r = results[impl.name]
        s0 = startup(r)
        per = {k: (v["seconds"] - (s0 or 0.0)) / v["pairs"] for k, v in r.items()
               if k != "one" and None not in v["moslqo"]}
        cells = []
        for c in cols:
            if c == "startup":
                cells.append("—" if s0 is None else f"{s0:.2f}")
            elif c == "scaling":
                cells.append(f"{per[single] / per[multi]:.1f}×" if single in per and multi in per else "—")
            else:
                cells.append(f"{per[c]:.3f}" if c in per else "—")
        name = f"**{impl.name}**" if impl.ours else impl.name
        print(f"| {impl.api} | {name} | " + " | ".join(cells) + f" | {impl.note} |")

    print("\nMax |ΔMOS|\n")
    print("| implementation | vs Google C++ (audio) | vs Google C++ (speech) | vs Google C++ (lattice) |"
          " vs conformance (audio) | vs conformance (speech) | vs conformance (lattice) |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for impl in impls:
        r = results[impl.name]
        audio = [r[k]["moslqo"] for k in keys if k.startswith("audio") and k in r]
        speech = [r[k]["moslqo"] for k in speech_keys if k in r]
        lattice = [r[k]["moslqo"] for k in lattice_keys if k in r]

        def vs_google(prefix):
            pairs = [(r[k]["moslqo"], ref[k]["moslqo"]) for k in keys if k.startswith(prefix) and k in r and k in ref]
            return max((d for x, y in pairs if (d := max_delta(x, y)) is not None), default=None)

        d_ga, d_gs, d_gl = vs_google("audio"), vs_google("speech"), vs_google("lattice")
        d_ca = max((d for x in audio if (d := max_delta(x, expect_audio * (len(x) // len(expect_audio))))
                    is not None), default=None)
        d_cs = max((d for x in speech if (d := max_delta(x, expect_speech * len(x))) is not None), default=None)
        d_cl = max((d for x in lattice if (d := max_delta(x, [SPEECH_LATTICE_EXPECTED] * len(x))) is not None),
                   default=None)
        print(f"| {impl.name} | {fmt_d(d_ga)} | {fmt_d(d_gs)} | {fmt_d(d_gl)} | {fmt_d(d_ca)} | {fmt_d(d_cs)} "
              f"| {fmt_d(d_cl)} |")

    a.json.parent.mkdir(parents=True, exist_ok=True)
    a.json.write_text(json.dumps({"machine": machine(), "results": results}, indent=1))
    print(f"\nraw results: {a.json.relative_to(ROOT) if a.json.is_relative_to(ROOT) else a.json}",
          file=sys.stderr)
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
