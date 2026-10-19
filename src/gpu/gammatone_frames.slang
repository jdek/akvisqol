// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Gammatone RMS spectrogram, one thread per (frame, band).
import df;
import gammatone_common;
import tables;
import zimt;

struct Samples : IFrame
{
    RO<real> signals;
#if BALANCED
    RO<real> signals_lo;
#endif
    uint start;

#if BALANCED
    Sample at(uint i) { return DF(signals[start + i], signals_lo[start + i]); }
#else
    Sample at(uint i) { return signals[start + i]; }
#endif
}

[shader("compute")]
[numthreads(64, 1, 1)]
void gammatone_frames(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> signals,
#if BALANCED
    uniform RO<real> signals_lo,
#endif
    uniform RO<Frame> frames,
    uniform RO<real> coeffs,
    uniform RO<real> hann,
    uniform RW<real> out,
    uniform uint num_frames,
    uniform uint num_bands,
    uniform uint window_size)
{
    uint gid = zimt_index(tid);
    uint band = gid % num_bands;
    uint frame = gid / num_bands;
    if (frame >= num_frames) return;

    Frame fr = frames[frame];
#if BALANCED
    Samples s = { signals, signals_lo, fr.start };
#else
    Samples s = { signals, fr.start };
#endif
    out[fr.out + band * fr.stride] = gammatone_rms(s, band, coeffs, hann, window_size);
}
