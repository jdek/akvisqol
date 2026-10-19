// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Gammatone backward: ∂L/∂samples of each degraded frame from ∂L/∂rms of
// its cells, in REAL, through the direct form (gammatone_common's EXACT).
//
// rms = sqrt(Σy²/n) gives ∂L/∂y = g·y / (n·rms); the cascade is linear
// and time-invariant, so its adjoint is the same cascade run backwards in
// time. The forward runs once saving the state every BLOCK samples, then
// each block, last first, is recomputed and run back through the adjoint.
// One thread group per frame, a band per lane; lanes sum the bands' sample
// gradients in group memory.
//
// coeffs: (num_bands, 8) — s1n0, s1n1, s2n1, s3n1, s4n1, a0, d1, d2.
// grads: (frames, window_size), each frame's ∂L/∂samples.
import tables;
import zimt;

typealias real = REAL;

static const uint LANES = 32;
static const uint BLOCK = 64;
static const uint MAX_WINDOW = 4096;

groupshared real part[LANES][BLOCK];

struct Cascade
{
    real s[8];

    __init() { for (uint k = 0; k < 8; k++) s[k] = 0; }

    [mutating]
    real step(real x, real c[8])
    {
        real f1 = c[0] * x + s[0];
        s[0] = c[1] * x + s[1] - c[6] * f1;
        s[1] = -(c[7] * f1);
        real f2 = c[5] * f1 + s[2];
        s[2] = c[2] * f1 + s[3] - c[6] * f2;
        s[3] = -(c[7] * f2);
        real f3 = c[5] * f2 + s[4];
        s[4] = c[3] * f2 + s[5] - c[6] * f3;
        s[5] = -(c[7] * f3);
        real f4 = c[5] * f3 + s[6];
        s[6] = c[4] * f3 + s[7] - c[6] * f4;
        s[7] = -(c[7] * f4);
        return f4;
    }
}

// Each stage b0 + b1·z⁻¹ over 1 + d1·z⁻¹ + d2·z⁻², backwards in time:
// v = g - d1·r1 - d2·r2, g_in = b0·v + b1·r1.
struct Adjoint
{
    real r1[4];
    real r2[4];

    __init() { for (uint k = 0; k < 4; k++) { r1[k] = 0; r2[k] = 0; } }

    [mutating]
    real step(real g, real c[8])
    {
        for (int k = 3; k >= 0; k--) {
            real b0 = k == 0 ? c[0] : c[5];
            real b1 = c[1 + k];
            real v = g - c[6] * r1[k] - c[7] * r2[k];
            g = b0 * v + b1 * r1[k];
            r2[k] = r1[k];
            r1[k] = v;
        }
        return g;
    }
}

real sampleAt(RO<real> signals, FrameGrad fr, uint i)
{
    int t = fr.start + int(i);
    return t >= int(fr.lo) && t < int(fr.hi) ? signals[uint(t)] : real(0);
}

[shader("compute")]
[numthreads(LANES, 1, 1)]
void gammatone_bwd(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> signals,
    uniform RO<FrameGrad> frames,
    uniform RO<real> coeffs,
    uniform RO<real> hann,
    uniform RO<real> grad,
    uniform RW<real> grads,
    uniform uint num_frames,
    uniform uint num_bands,
    uniform uint window_size)
{
    uint frame = zimt_index(tid) / LANES;
    uint band = tid.x % LANES;
    if (frame >= num_frames) return;
    FrameGrad fr = frames[frame];

    real c[8];
    for (uint k = 0; k < 8; k++) c[k] = band < num_bands ? coeffs[band * 8 + k] : real(0);
    real g = band < num_bands ? grad[fr.grad + band * fr.stride] : real(0);
    bool on = g != real(0);
    uint blocks = (window_size + BLOCK - 1) / BLOCK;

    real saved[MAX_WINDOW / BLOCK * 8];
    real scale = 0;
    if (on) {
        Cascade f = Cascade();
        real sum_sq = 0;
        for (uint i = 0; i < window_size; i++) {
            if (i % BLOCK == 0) for (uint k = 0; k < 8; k++) saved[i / BLOCK * 8 + k] = f.s[k];
            real y = f.step(sampleAt(signals, fr, i) * hann[i], c);
            sum_sq += y * y;
        }
        real rms = sqrt(sum_sq / real(window_size));
        if (rms > real(0)) scale = g / (rms * real(window_size));
    }

    Adjoint adj = Adjoint();
    real y[BLOCK];
    for (int blk = int(blocks) - 1; blk >= 0; blk--) {
        uint first = uint(blk) * BLOCK;
        uint n = min(BLOCK, window_size - first);
        if (scale != real(0)) {
            Cascade f = Cascade();
            for (uint k = 0; k < 8; k++) f.s[k] = saved[uint(blk) * 8 + k];
            for (uint i = 0; i < n; i++) y[i] = f.step(sampleAt(signals, fr, first + i) * hann[first + i], c);
            for (int i = int(n) - 1; i >= 0; i--) {
                uint at = first + uint(i);
                int t = fr.start + int(at);
                real gs = adj.step(scale * y[i], c) * hann[at];
                part[band][i] = t >= int(fr.lo) && t < int(fr.hi) ? gs : real(0);
            }
        } else {
            for (uint i = 0; i < n; i++) part[band][i] = 0;
        }
        GroupMemoryBarrierWithGroupSync();
        for (uint i = band; i < n; i += LANES) {
            real sum = 0;
            for (uint b = 0; b < num_bands; b++) sum += part[b][i];
            grads[fr.out + first + i] = sum;
        }
        GroupMemoryBarrierWithGroupSync();
    }
}

// Each pair's aligned deg gradient: per sample, the frames covering it.
// grads: as gammatone_bwd's; out: each pair's at its `out`.
[shader("compute")]
[numthreads(64, 1, 1)]
void signal_grad(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<SignalGrad> signals,
    uniform RO<FrameRun> runs,
    uniform RO<real> grads,
    uniform RW<real> out,
    uniform uint num_signals,
    uniform uint max_len,
    uniform uint window_size,
    uniform uint hop_size)
{
    uint id = zimt_index(tid);
    uint p = id / max_len;
    uint i = id % max_len;
    if (p >= num_signals) return;
    SignalGrad sg = signals[p];
    if (i >= sg.len) return;
    int t = int(sg.start + i);
    real sum = 0;
    for (uint r = 0; r < sg.runs; r++) {
        FrameRun run = runs[sg.first_run + r];
        int rel = t - run.start;
        if (rel < 0) continue;
        // Frames k with k·hop <= rel < k·hop + window.
        int last = min(rel / int(hop_size), int(run.count) - 1);
        for (int k = last; k >= 0 && rel - k * int(hop_size) < int(window_size); k--) {
            sum += grads[run.out + uint(k) * window_size + uint(rel - k * int(hop_size))];
        }
    }
    out[sg.out + i] = sum;
}
