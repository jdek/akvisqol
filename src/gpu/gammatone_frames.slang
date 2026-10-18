// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Gammatone RMS spectrogram (mirrors `filterBandRmsFresh` in gammatone.zig),
// one thread per (frame, band); f32, square sum blocked to keep error ~sqrt(n)·eps.
//
// Each biquad stage runs in delta form, since low-band poles near z = 1 make
// the direct f32 recursion lose ~1/(1 - r)^2 to cancellation:
//   dy = dy[n-1] + c2·dy[n-1] - e·y[n-1] + n0·dx + m1·x[n-1] + n2·x[n-2]
// with c2 = d2 - 1, e = 1 + d1 + d2, m1 = n0 + n1 formed in f64 on the host.
// Each stage's (y, dy) is the next one's (x, dx).
//
// frames:  (num_frames, 3) u32 — signal offset, out index of band 0, band stride.
// coeffs:  (num_bands, 8) f32 — stage 1 n0, m1, n2; m1 for stages 2-4; c2; e.
// coeffs2: (num_bands, 2) f32 — n0, n2 for stages 2-4.
import zimt;

[shader("compute")]
[numthreads(64, 1, 1)]
void gammatone_frames(
    uint3 tid: SV_DispatchThreadID,
    uniform StructuredBuffer<float> signals,
    uniform StructuredBuffer<uint> frames,
    uniform StructuredBuffer<float> coeffs,
    uniform StructuredBuffer<float> coeffs2,
    uniform StructuredBuffer<float> hann,
    uniform RWStructuredBuffer<float> out,
    uniform uint num_frames,
    uniform uint num_bands,
    uniform uint window_size)
{
    uint gid = zimt_index(tid);
    uint band = gid % num_bands;
    uint frame = gid / num_bands;
    if (frame >= num_frames) return;

    uint start = frames[frame * 3 + 0];
    uint out_idx = frames[frame * 3 + 1] + band * frames[frame * 3 + 2];

    float s1n0 = coeffs[band * 8 + 0];
    float s1m1 = coeffs[band * 8 + 1];
    float s1n2 = coeffs[band * 8 + 2];
    float s2m1 = coeffs[band * 8 + 3];
    float s3m1 = coeffs[band * 8 + 4];
    float s4m1 = coeffs[band * 8 + 5];
    float c2 = coeffs[band * 8 + 6];
    float e = coeffs[band * 8 + 7];
    float n0 = coeffs2[band * 2 + 0];
    float n2 = coeffs2[band * 2 + 1];

    float x1_1 = 0, x2_1 = 0, y_1 = 0, dy_1 = 0;
    float x1_2 = 0, x2_2 = 0, y_2 = 0, dy_2 = 0;
    float x1_3 = 0, x2_3 = 0, y_3 = 0, dy_3 = 0;
    float x1_4 = 0, x2_4 = 0, y_4 = 0, dy_4 = 0;
    float total = 0;
    float block = 0;
    for (uint i = 0; i < window_size; i++) {
        float x = signals[start + i] * hann[i];
        float dx = x - x1_1;

        dy_1 = dy_1 + c2 * dy_1 - e * y_1 + (s1n0 * dx + s1m1 * x1_1 + s1n2 * x2_1);
        x2_1 = x1_1; x1_1 = x;
        y_1 = y_1 + dy_1;

        dy_2 = dy_2 + c2 * dy_2 - e * y_2 + (n0 * dy_1 + s2m1 * x1_2 + n2 * x2_2);
        x2_2 = x1_2; x1_2 = y_1;
        y_2 = y_2 + dy_2;

        dy_3 = dy_3 + c2 * dy_3 - e * y_3 + (n0 * dy_2 + s3m1 * x1_3 + n2 * x2_3);
        x2_3 = x1_3; x1_3 = y_2;
        y_3 = y_3 + dy_3;

        dy_4 = dy_4 + c2 * dy_4 - e * y_4 + (n0 * dy_3 + s4m1 * x1_4 + n2 * x2_4);
        x2_4 = x1_4; x1_4 = y_3;
        y_4 = y_4 + dy_4;

        block += y_4 * y_4;
        if ((i & 63) == 63) {
            total += block;
            block = 0;
        }
    }
    total += block;
    out[out_idx] = sqrt(total / float(window_size));
}
