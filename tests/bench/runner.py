# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

"""Scores a pairs CSV through one Python ViSQOL API, under whichever
`visqol` package the interpreter resolves. Run by compare.py.

    python runner.py {google,visqol-python} PAIRS.csv OUT.json
        [--threads N] [--pool process|thread] [--speech [--lattice]]
"""

import argparse
import csv
import json
import os
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor

_manager = None


LATTICE_MODEL = "lattice_tcditugenmeetpackhref_ls2_nl60_lr12_bs2048_learn.005_ep2400_train1_7_raw.tflite"


def _google_manager(mode):
    """`mode` = (speech, lattice)."""
    speech, lattice = mode
    from visqol import visqol_lib_py
    # pybind11_protobuf needs the result message type imported.
    from visqol.pb2 import similarity_result_pb2  # noqa: F401

    import visqol
    # Upstream ships models in visqol/model; ours via Default*ModelFile.
    name = LATTICE_MODEL if lattice else "libsvm_nu_svr_model.txt"
    model = os.path.join(os.path.dirname(visqol.__file__), "model", name)
    if not os.path.isfile(model):
        model = (visqol_lib_py.DefaultSpeechModelFile() if lattice else visqol_lib_py.DefaultAudioModelFile())
    m = visqol_lib_py.VisqolManager()
    m.Init(visqol_lib_py.FilePath(model), speech, False, 60, lattice, False, False)
    return m


def _google_init(mode):
    global _manager
    _manager = _google_manager(mode)


def _google_run(pair):
    from visqol import visqol_lib_py

    try:
        return _manager.Run(visqol_lib_py.FilePath(pair[0]), visqol_lib_py.FilePath(pair[1])).moslqo
    except Exception as e:  # noqa: BLE001
        return e


def run_google(pairs, threads, pool, mode):
    if threads == 1:
        _google_init(mode)
        return [_google_run(p) for p in pairs]
    if pool == "thread":
        # One manager per thread, as upstream's threaded test does.
        import threading
        local = threading.local()

        def run(pair):
            from visqol import visqol_lib_py
            if not hasattr(local, "m"):
                local.m = _google_manager(mode)
            try:
                return local.m.Run(visqol_lib_py.FilePath(pair[0]), visqol_lib_py.FilePath(pair[1])).moslqo
            except Exception as e:  # noqa: BLE001
                return e

        with ThreadPoolExecutor(threads) as ex:
            return list(ex.map(run, pairs))
    with ProcessPoolExecutor(threads, initializer=_google_init, initargs=(mode,)) as ex:
        return list(ex.map(_google_run, pairs))


def run_visqol_python(pairs, threads, mode):
    from visqol import VisqolApi

    speech, lattice = mode
    api = VisqolApi()
    kw = {"use_lattice_model": lattice} if speech else {}
    api.create(mode="speech" if speech else "audio", **kw)
    out = api.measure_batch(pairs, parallel=threads > 1, max_workers=threads)
    return [r if isinstance(r, Exception) else r.moslqo for r in out]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("api", choices=["google", "visqol-python"])
    ap.add_argument("pairs")
    ap.add_argument("out")
    ap.add_argument("--threads", type=int, default=1)
    ap.add_argument("--pool", choices=["process", "thread"], default="process")
    ap.add_argument("--speech", action="store_true")
    ap.add_argument("--lattice", action="store_true", help="speech mode: the TF-Lattice mapping")
    a = ap.parse_args()
    with open(a.pairs) as f:
        pairs = [(r["reference"], r["degraded"]) for r in csv.DictReader(f)]
    mode = (a.speech, a.speech and a.lattice)
    if a.api == "google":
        res = run_google(pairs, a.threads, a.pool, mode)
    else:
        res = run_visqol_python(pairs, a.threads, mode)
    with open(a.out, "w") as f:
        json.dump({
            "moslqo": [None if isinstance(r, Exception) else float(r) for r in res],
            "errors": [str(r) if isinstance(r, Exception) else None for r in res],
        }, f)


if __name__ == "__main__":
    main()
