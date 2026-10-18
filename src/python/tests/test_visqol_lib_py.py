# SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
# SPDX-License-Identifier: Apache-2.0

"""Ports of google/visqol python/visqol_lib_py_test.py plus conformance."""

import logging
import sys
import wave
from concurrent import futures

import numpy as np
import pytest

from visqol import visqol_lib_py
from visqol.pb2 import similarity_result_pb2, visqol_config_pb2

TOL = 0.0001  # upstream CONFORMANCE_TOLERANCE

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

def read_wav_mono(path):
    with wave.open(str(path)) as w:
        assert w.getsampwidth() == 2
        x = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float64) / 32768.0
        return x.reshape(-1, w.getnchannels()).mean(axis=1), w.getframerate()


def manager(speech, lattice=False, unscaled=False):
    m = visqol_lib_py.VisqolManager()
    model = visqol_lib_py.DefaultSpeechModelFile() if speech else visqol_lib_py.DefaultAudioModelFile()
    m.Init(visqol_lib_py.FilePath(model), speech, unscaled, 60, lattice, False, False)
    return m


def test_docstring():
    assert "ViSQOL" in visqol_lib_py.__doc__


def test_visqol_api_sine():
    config = visqol_config_pb2.VisqolConfig()
    config.audio.sample_rate = 48000
    config.options.svr_model_path = visqol_lib_py.DefaultAudioModelFile()
    api = visqol_lib_py.VisqolApi()
    api.Create(config)
    sin_ref = np.sin(np.linspace(0.0, 1000, 48000 * 2))
    noisy_deg = sin_ref + np.random.default_rng(0).normal(size=sin_ref.shape)
    r = api.Measure(sin_ref, noisy_deg)
    assert isinstance(r, similarity_result_pb2.SimilarityResultMsg)
    assert 1.0 <= r.moslqo < 5.0
    assert len(r.fvnsim) == len(r.fvnsim10) == len(r.center_freq_bands) == 32
    assert len(r.patch_sims) > 0 and len(r.patch_sims[0].freq_band_means) == 32


def test_create_errors():
    api = visqol_lib_py.VisqolApi()
    with pytest.raises(visqol_lib_py.StatusNotOk):
        api.Create(visqol_config_pb2.VisqolConfig())
    config = visqol_config_pb2.VisqolConfig()
    config.audio.sample_rate = 44100
    config.options.svr_model_path = visqol_lib_py.DefaultAudioModelFile()
    with pytest.raises(visqol_lib_py.StatusNotOk, match="48k"):
        api.Create(config)
    config.options.allow_unsupported_sample_rates = True
    api.Create(config)
    with pytest.raises(visqol_lib_py.StatusNotOk):
        visqol_lib_py.VisqolApi().Measure(np.zeros(10), np.zeros(10))


def test_too_short_signal_raises():
    config = visqol_config_pb2.VisqolConfig()
    config.audio.sample_rate = 48000
    api = visqol_lib_py.VisqolApi()
    api.Create(config)
    with pytest.raises(visqol_lib_py.StatusNotOk):
        api.Measure(np.zeros(100), np.zeros(100))


@pytest.mark.parametrize("ref,deg,expected", AUDIO_CASES, ids=[c[0] for c in AUDIO_CASES])
def test_audio_conformance(testdata, ref, deg, expected):
    d = testdata / "conformance_testdata_subset"
    r = manager(False).Run(visqol_lib_py.FilePath(str(d / ref)), visqol_lib_py.FilePath(str(d / deg)))
    assert abs(r.moslqo - expected) < TOL
    assert r.reference_filepath.endswith(ref)


def test_api_matches_manager(testdata):
    d = testdata / "conformance_testdata_subset"
    ref, sr = read_wav_mono(d / "guitar48_stereo.wav")
    deg, _ = read_wav_mono(d / "guitar48_stereo_64kbps_aac.wav")
    config = visqol_config_pb2.VisqolConfig()
    config.audio.sample_rate = sr
    config.options.svr_model_path = visqol_lib_py.DefaultAudioModelFile()
    api = visqol_lib_py.VisqolApi()
    api.Create(config)
    r = api.Measure(ref, deg)
    assert abs(r.moslqo - 4.349722308064298) < TOL


def test_short_patches(testdata):
    d = testdata / "conformance_testdata_subset"
    s = testdata / "short_duration" / "5_second" / "guitar48_stereo_5_sec.wav"
    m = manager(False)
    assert abs(m.Run(str(d / "guitar48_stereo.wav"), str(s)).moslqo - 4.314508583690198) < TOL
    assert abs(m.Run(str(s), str(d / "guitar48_stereo.wav")).moslqo - 4.550791119387646) < TOL


@pytest.mark.parametrize("unscaled,deg,expected", [
    (False, "transcoded_CA01_01.wav", 3.374505555111911),
    (True, "CA01_01.wav", 4.015861169223797),
])
def test_speech_exponential(testdata, unscaled, deg, expected):
    cs = testdata / "clean_speech"
    r = manager(True, unscaled=unscaled).Run(str(cs / "CA01_01.wav"), str(cs / deg))
    assert len(r.fvnsim) == 21
    assert abs(r.moslqo - expected) < TOL


def test_speech_bad_degraded(testdata):
    a = testdata / "alignment"
    r = manager(True).Run(str(a / "reference.wav"), str(a / "degraded.wav"))
    assert abs(r.moslqo - 1.357521678867611) < TOL


@pytest.mark.parametrize("ref,deg,expected", [
    ("clean_speech/CA01_01.wav", "clean_speech/transcoded_CA01_01.wav", 3.3129234313964844),
    ("clean_speech/CA01_01.wav", "clean_speech/CA01_01.wav", 4.505550384521484),
    ("conformance_testdata_subset/guitar48_stereo.wav", "clean_speech/CA01_01.wav", 1.4982070922851562),
    ("alignment/reference.wav", "alignment/degraded.wav", 1.19293212890625),
])
def test_speech_lattice(testdata, ref, deg, expected):
    r = manager(True, lattice=True).Run(str(testdata / ref), str(testdata / deg))
    assert abs(r.moslqo - expected) < TOL


def test_lattice_matches_tflite(testdata):
    """Against TFLite builtin kernels; XNNPACK shifts this model by up to 5e-5."""
    if sys.platform != "darwin":
        pytest.skip("ai-edge-litert's non-macOS builtin kernels read ~6e-5 off its macOS ones")
    interp_mod = pytest.importorskip("ai_edge_litert.interpreter")
    interp = interp_mod.Interpreter(
        model_path=visqol_lib_py.DefaultSpeechModelFile(), num_threads=1,
        experimental_op_resolver_type=interp_mod.OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES)
    runner = interp.get_signature_runner("predict")
    d = testdata / "conformance_testdata_subset"
    pairs = [(testdata / "clean_speech" / "CA01_01.wav", testdata / "clean_speech" / "transcoded_CA01_01.wav")]
    pairs += [(d / r, d / g) for r, g, _ in AUDIO_CASES]
    m = manager(True, lattice=True)
    for ref, deg in pairs:
        r = m.Run(str(ref), str(deg))
        feeds = {"tau": np.array([0.5], np.float32)}
        for base, values in (("fvnsim", r.fvnsim), ("fvnsim10_", r.fvnsim10),
                             ("fstdnsim", r.fstdnsim), ("fvdegenergy", r.fvdegenergy)):
            for b, v in enumerate(values):
                feeds[f"{base}{b}"] = np.array([v], np.float32)
        expected = float(np.asarray(runner(**feeds)["predictions"]).reshape(-1)[0])
        assert abs(r.moslqo - expected) < 1e-5, (ref.name, deg.name)


def test_parallel(testdata):
    cs = testdata / "clean_speech"

    def run():
        return manager(True).Run(str(cs / "CA01_01.wav"), str(cs / "transcoded_CA01_01.wav")).moslqo

    with futures.ThreadPoolExecutor(4) as ex:
        scores = list(ex.map(lambda _: run(), range(4)))
    assert max(scores) - min(scores) == 0.0


def test_measure_batch_matches_single(testdata):
    d = testdata / "conformance_testdata_subset"
    pairs = [(read_wav_mono(d / r)[0], read_wav_mono(d / g)[0]) for r, g, _ in AUDIO_CASES[:4]]
    config = visqol_config_pb2.VisqolConfig()
    config.audio.sample_rate = 48000
    api = visqol_lib_py.VisqolApi()
    api.Create(config)
    batch = api.MeasureBatch(pairs)
    for (ref, deg), b in zip(pairs, batch):
        assert api.Measure(ref, deg).moslqo == b.moslqo
