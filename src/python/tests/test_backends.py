# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

"""GPU backends (f32) against the f64 CPU path.

Scores must stay well inside upstream's 1e-4 tolerance; alignment lags are exact
(f32 nominates candidates, rescored in f64).
"""

import numpy as np
import pytest

import visqol
from visqol import visqol_lib_py
from visqol.pb2 import visqol_config_pb2

from test_visqol_lib_py import AUDIO_CASES, read_wav_mono

PARITY_TOL = 1e-5

GPU_BACKENDS = [b for b in visqol.available_backends() if b != "cpu"]

pytestmark = pytest.mark.skipif(not GPU_BACKENDS, reason="no GPU backend built/available")


def api(backend, speech=False):
    config = visqol_config_pb2.VisqolConfig()
    config.audio.sample_rate = 16000 if speech else 48000
    config.options.use_speech_scoring = speech
    config.options.svr_model_path = (visqol_lib_py.DefaultSpeechModelFile() if speech
                                     else visqol_lib_py.DefaultAudioModelFile())
    a = visqol_lib_py.VisqolApi(backend=backend)
    a.Create(config)
    return a


def assert_close(cpu, gpu):
    assert abs(cpu.moslqo - gpu.moslqo) < PARITY_TOL
    assert abs(cpu.vnsim - gpu.vnsim) < PARITY_TOL
    np.testing.assert_allclose(gpu.fvnsim, cpu.fvnsim, rtol=0, atol=PARITY_TOL)
    assert len(gpu.patch_sims) == len(cpu.patch_sims)
    for c, g in zip(cpu.patch_sims, gpu.patch_sims):
        assert (c.ref_patch_start_time, c.deg_patch_start_time) == (g.ref_patch_start_time, g.deg_patch_start_time)
        assert abs(c.similarity - g.similarity) < 10 * PARITY_TOL


@pytest.fixture(scope="module")
def audio_pairs(request):
    from conftest import TESTDATA
    d = TESTDATA / "conformance_testdata_subset"
    if not (d / AUDIO_CASES[0][0]).is_file():
        pytest.skip("conformance audio missing; run tests/fetch_data.sh")
    return [(read_wav_mono(d / r)[0], read_wav_mono(d / g)[0]) for r, g, _ in AUDIO_CASES]


@pytest.mark.parametrize("backend", GPU_BACKENDS)
def test_audio_batch_parity(backend, audio_pairs):
    cpu = api("cpu").MeasureBatch(audio_pairs)
    gpu = api(backend).MeasureBatch(audio_pairs)
    for c, g in zip(cpu, gpu):
        assert_close(c, g)


@pytest.mark.parametrize("backend", GPU_BACKENDS)
def test_batch_matches_single(backend, audio_pairs):
    a = api(backend)
    batch = a.MeasureBatch(audio_pairs[:3])
    for (ref, deg), b in zip(audio_pairs[:3], batch):
        assert a.Measure(ref, deg).moslqo == b.moslqo


@pytest.mark.parametrize("backend", GPU_BACKENDS)
def test_speech_parity(backend, testdata):
    cs = testdata / "clean_speech"
    for deg in ("transcoded_CA01_01.wav", "CA01_01.wav"):
        runs = []
        for b in ("cpu", backend):
            m = visqol_lib_py.VisqolManager(backend=b)
            m.Init(visqol_lib_py.FilePath(visqol_lib_py.DefaultSpeechModelFile()), True, False, 60, False, False, False)
            runs.append(m.Run(str(cs / "CA01_01.wav"), str(cs / deg)))
        assert_close(*runs)
