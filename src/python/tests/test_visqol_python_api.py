# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

"""visqol-python compatible API (`from visqol import VisqolApi`)."""

import subprocess
import sys

import numpy as np
import pytest

import visqol
from visqol import PatchSimilarityResult, SimilarityResult, VisqolApi

from test_visqol_lib_py import AUDIO_CASES, TOL, read_wav_mono


def audio_api(**kw):
    api = VisqolApi()
    api.create(mode="audio", **kw)
    return api


def test_exports():
    for name in ("VisqolApi", "SimilarityResult", "PatchSimilarityResult", "AudioSignal", "ProgressCallback"):
        assert hasattr(visqol, name)


def test_create_errors(tmp_path):
    with pytest.raises(ValueError):
        VisqolApi().create(mode="music")
    with pytest.raises(ValueError):
        VisqolApi().create(search_window=0)
    with pytest.raises(FileNotFoundError):
        VisqolApi().create(model_path=str(tmp_path / "missing.txt"))
    with pytest.raises(RuntimeError):
        VisqolApi().measure("a.wav", "b.wav")


def test_measure_missing_file(tmp_path):
    with pytest.raises(FileNotFoundError):
        audio_api().measure(str(tmp_path / "a.wav"), str(tmp_path / "b.wav"))


@pytest.mark.parametrize("ref,deg,expected", AUDIO_CASES[:4], ids=[c[0] for c in AUDIO_CASES[:4]])
def test_measure_conformance(testdata, ref, deg, expected):
    d = testdata / "conformance_testdata_subset"
    r = audio_api().measure(str(d / ref), str(d / deg))
    assert isinstance(r, SimilarityResult)
    assert abs(r.moslqo - expected) < TOL
    assert len(r.fvnsim) == len(r.fvnsim10) == len(r.fstdnsim) == len(r.center_freq_bands) == 32
    p = r.patch_sims[0]
    assert isinstance(p, PatchSimilarityResult)
    assert len(p.freq_band_means) == len(p.freq_band_stddevs) == len(p.freq_band_deg_energy) == 32
    # Patch similarity is the mean of its per-band means.
    assert abs(p.similarity - float(np.mean(p.freq_band_means))) < 1e-9


def test_measure_from_arrays_matches_files(testdata):
    d = testdata / "conformance_testdata_subset"
    ref, sr = read_wav_mono(d / "guitar48_stereo.wav")
    deg, _ = read_wav_mono(d / "guitar48_stereo_64kbps_aac.wav")
    api = audio_api()
    a = api.measure_from_arrays(ref, deg, sr)
    f = api.measure(str(d / "guitar48_stereo.wav"), str(d / "guitar48_stereo_64kbps_aac.wav"))
    assert a.moslqo == f.moslqo
    with pytest.raises(TypeError):
        api.measure_from_arrays(list(ref), deg, sr)
    with pytest.raises(ValueError):
        api.measure_from_arrays(np.array([]), deg, sr)


def test_speech_mode(testdata):
    cs = testdata / "clean_speech"
    api = VisqolApi()
    api.create(mode="speech", use_lattice_model=False)
    r = api.measure(str(cs / "CA01_01.wav"), str(cs / "transcoded_CA01_01.wav"))
    assert len(r.fvnsim) == 21
    assert abs(r.moslqo - 3.374505555111911) < TOL


def test_speech_lattice(testdata):
    cs = testdata / "clean_speech"
    pairs = [(str(cs / "CA01_01.wav"), str(cs / "transcoded_CA01_01.wav"))]
    for kw in ({}, {"use_lattice_model": True}):  # on by default
        api = VisqolApi()
        api.create(mode="speech", **kw)
        expected = visqol.visqol_lib_py.ConformanceSpeechCA01TranscodedValue()
        assert abs(api.measure(*pairs[0]).moslqo - expected) < TOL
        assert abs(api.measure_batch(pairs)[0].moslqo - expected) < TOL
    with pytest.raises(FileNotFoundError):
        VisqolApi().create(mode="speech", lattice_model_path="missing.tflite")


@pytest.mark.parametrize("parallel", [True, False])
def test_measure_batch(testdata, tmp_path, parallel):
    d = testdata / "conformance_testdata_subset"
    pairs = [(str(d / r), str(d / g)) for r, g, _ in AUDIO_CASES[:4]]
    pairs.insert(2, (str(tmp_path / "missing.wav"), pairs[0][1]))
    progress = []
    out = audio_api().measure_batch(pairs, parallel=parallel, max_workers=2,
                                    progress_callback=lambda done, total: progress.append((done, total)))
    assert len(out) == 5
    assert isinstance(out[2], Exception)
    expected = [c[2] for c in AUDIO_CASES[:4]]
    got = [r.moslqo for i, r in enumerate(out) if i != 2]
    assert all(abs(g - e) < TOL for g, e in zip(got, expected))
    assert progress and progress[-1] == (5, 5)


def test_cli(testdata):
    d = testdata / "conformance_testdata_subset"
    out = subprocess.run(
        [sys.executable, "-m", "visqol", "--reference", str(d / "guitar48_stereo.wav"),
         "--degraded", str(d / "guitar48_stereo_64kbps_aac.wav")],
        check=True, capture_output=True, text=True).stdout
    mos = float(out.split("MOS-LQO:")[1].split()[0])
    assert abs(mos - 4.349722308064298) < TOL
