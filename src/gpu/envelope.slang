// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// `envelope.upperEnvelope` of both sides of each row, in REAL (double, or
// float where the device has no f64), packed into the complex rows the lag
// FFT takes. Passes over blocks of `block` samples (a multiple of the
// thread-group size, dividing n): sums, means, alternating sums about the
// mean, their scale, then the envelopes, kept in `env` (up to each side's
// length) for rescoring.
//
// Rows are `first ..` of `rows`; `part` and `stats` are per side
// (row * 2 + side), `stats` holding mean and nyquist / N.
import tables;
import zimt;

typealias real = REAL;

static const uint ENV_THREADS = 64;

groupshared real acc[ENV_THREADS];

// Uniform per thread group: every thread calls it.
real groupSum(real v, uint lane)
{
    acc[lane] = v;
    GroupMemoryBarrierWithGroupSync();
    for (uint s = ENV_THREADS / 2; s > 0; s >>= 1) {
        if (lane < s) acc[lane] += acc[lane + s];
        GroupMemoryBarrierWithGroupSync();
    }
    return acc[0];
}

real at(Side v, RO<real> signals, uint i) { return i < v.pad ? real(0) : signals[v.start + i - v.pad]; }

Side side(RO<LagRow> rows, uint row, uint s) { return s == 0 ? rows[row].a : rows[row].b; }

real envelopeAt(Side v, RO<real> signals, uint i, real mean, real nyq)
{
    if (i >= v.total()) return real(0);
    real t = (i & 1) == 0 ? nyq : -nyq;
    return abs(real(2) * ((at(v, signals, i) - mean) - t) - real(0.000001l)) + mean;
}

[shader("compute")]
[numthreads(ENV_THREADS, 1, 1)]
void env_sums(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> signals,
    uniform RO<LagRow> rows,
    uniform RW<real> part,
    uniform uint first,
    uniform uint log2_n,
    uniform uint block,
    uniform uint total)
{
    uint g = zimt_index(tid) / ENV_THREADS;
    uint lane = tid.x % ENV_THREADS;
    if (g >= total) return;
    uint blocks = (1u << log2_n) / block;
    uint s = g / blocks;
    Side v = side(rows, first + s / 2, s % 2);
    real sum = 0;
    for (uint i = (g % blocks) * block + lane, k = 0; k < block / ENV_THREADS; i += ENV_THREADS, k++) {
        if (i < v.total()) sum += at(v, signals, i);
    }
    sum = groupSum(sum, lane);
    if (lane == 0) part[g] = sum;
}

// mode 0: mean = Σ / (pad + len); mode 1: nyquist / N, N = max(2^⌈log2(pad + len)⌉, 32).
[shader("compute")]
[numthreads(ENV_THREADS, 1, 1)]
void env_reduce(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<LagRow> rows,
    uniform RO<real> part,
    uniform RW<real> stats,
    uniform uint first,
    uniform uint log2_n,
    uniform uint block,
    uniform uint sides,
    uniform uint mode)
{
    uint g = zimt_index(tid) / ENV_THREADS;
    uint lane = tid.x % ENV_THREADS;
    if (g >= sides) return;
    uint blocks = (1u << log2_n) / block;
    real s = 0;
    for (uint b = lane; b < blocks; b += ENV_THREADS) s += part[g * blocks + b];
    s = groupSum(s, lane);
    if (lane != 0) return;
    uint total = side(rows, first + g / 2, g % 2).total();
    if (mode == 0) {
        stats[g * 2] = s / real(total);
        return;
    }
    // Halving is exact.
    uint log2_big = max(total <= 1 ? 0 : firstbithigh(total - 1) + 1, 5);
    for (uint k = 0; k < log2_big; k++) s *= real(0.5);
    stats[g * 2 + 1] = s;
}

[shader("compute")]
[numthreads(ENV_THREADS, 1, 1)]
void env_nyq(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> signals,
    uniform RO<LagRow> rows,
    uniform RO<real> stats,
    uniform RW<real> part,
    uniform uint first,
    uniform uint log2_n,
    uniform uint block,
    uniform uint total)
{
    uint g = zimt_index(tid) / ENV_THREADS;
    uint lane = tid.x % ENV_THREADS;
    if (g >= total) return;
    uint blocks = (1u << log2_n) / block;
    uint s = g / blocks;
    Side v = side(rows, first + s / 2, s % 2);
    real mean = stats[s * 2];
    real sum = 0;
    for (uint i = (g % blocks) * block + lane, k = 0; k < block / ENV_THREADS; i += ENV_THREADS, k++) {
        if (i >= v.total()) continue;
        real d = at(v, signals, i) - mean;
        sum += (i & 1) == 0 ? d : -d;
    }
    sum = groupSum(sum, lane);
    if (lane == 0) part[g] = sum;
}

// Also Σ env² over both sides per (row, block), for the f32 error bound.
[shader("compute")]
[numthreads(ENV_THREADS, 1, 1)]
void env_write(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> signals,
    uniform RO<LagRow> rows,
    uniform RO<real> stats,
    uniform RW<real> env,
    uniform RW<float2> z,
    uniform RW<real> energy,
    uniform uint first,
    uniform uint log2_n,
    uniform uint block,
    uniform uint total)
{
    uint g = zimt_index(tid) / ENV_THREADS;
    uint lane = tid.x % ENV_THREADS;
    if (g >= total) return;
    uint n = 1u << log2_n;
    uint blocks = n / block;
    uint row = g / blocks;
    Side a = rows[first + row].a;
    Side b = rows[first + row].b;
    real e = 0;
    for (uint i = (g % blocks) * block + lane, k = 0; k < block / ENV_THREADS; i += ENV_THREADS, k++) {
        real ea = envelopeAt(a, signals, i, stats[row * 4], stats[row * 4 + 1]);
        real eb = envelopeAt(b, signals, i, stats[row * 4 + 2], stats[row * 4 + 3]);
        if (i < a.total()) env[(row * 2) * n + i] = ea;
        if (i < b.total()) env[(row * 2 + 1) * n + i] = eb;
        z[row * n + i] = float2(float(ea), float(eb));
        e += ea * ea + eb * eb;
    }
    e = groupSum(e, lane);
    if (lane == 0) energy[g] = e;
}

// params[row].slack = `xcorr.refineSlack`: Σ env² · slack_scale (= 2 · tol · n).
[shader("compute")]
[numthreads(ENV_THREADS, 1, 1)]
void lag_params(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> energy,
    uniform RW<LagParams> params,
    uniform uint log2_n,
    uniform uint block,
    uniform uint num_rows,
    uniform float slack_scale)
{
    uint row = zimt_index(tid) / ENV_THREADS;
    uint lane = tid.x % ENV_THREADS;
    if (row >= num_rows) return;
    uint blocks = (1u << log2_n) / block;
    real e = 0;
    for (uint b = lane; b < blocks; b += ENV_THREADS) e += energy[row * blocks + b];
    e = groupSum(e, lane);
    if (lane == 0) params.p[row].slack = float(e * real(slack_scale));
}

// f32 copies of f64 signals, for the spectrograms.
[shader("compute")]
[numthreads(64, 1, 1)]
void to_f32(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> x,
    uniform RW<float> y,
    uniform uint n)
{
    uint i = zimt_index(tid);
    if (i < n) y[i] = float(x[i]);
}
