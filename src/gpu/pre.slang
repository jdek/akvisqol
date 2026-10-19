// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Global alignment and SPL matching (`realign.applyLag`,
// `audio.scaleToMatchSpl`). The host reads the energies with the lags and
// forms the CPU's factor; `apply_lag` writes the aligned, scaled degraded
// signal.
import df;
import tables;
import zimt;

typealias real = REAL;

static const uint THREADS = 64;

groupshared real acc[THREADS];

// Sums of squares in blocks of `block` samples (a multiple of THREADS) of
// each ref (side 0) and degraded signal as `applyLag` aligns it by
// lags[pair] (side 1), for the host to add up: energy[(pair * 2 + side) *
// blocks + block index].
[shader("compute")]
[numthreads(THREADS, 1, 1)]
void spl_energy(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> signals,
    uniform RO<PairSignals> pairs,
    uniform RO<int> lags,
    uniform RW<real> energy,
    uniform uint num_pairs,
    uniform uint block,
    uniform uint blocks)
{
    uint g = zimt_index(tid) / THREADS;
    uint lane = tid.x % THREADS;
    if (g >= num_pairs * 2 * blocks) return;
    uint side = g / blocks;
    PairSignals ps = pairs[side / 2];
    uint from = ps.ref_off;
    uint to = ps.ref_off + ps.ref_len;
    if (side % 2 == 1) {
        int lag = lags[side / 2];
        // Dropped leading samples; prepended zeros add nothing.
        bool shift = lag < 0 && uint(-lag) <= ps.ref_len / 2;
        from = ps.deg_off + (shift ? min(uint(-lag), ps.deg_len) : 0);
        to = ps.deg_off + ps.deg_len;
    }
    real e = 0;
    for (uint i = from + (g % blocks) * block + lane, k = 0; k < block / THREADS && i < to; i += THREADS, k++) e += signals[i] * signals[i];
    acc[lane] = e;
    GroupMemoryBarrierWithGroupSync();
    for (uint s = THREADS / 2; s > 0; s >>= 1) {
        if (lane < s) acc[lane] += acc[lane + s];
        GroupMemoryBarrierWithGroupSync();
    }
    if (lane == 0) energy[g] = acc[0];
}

// out[a.out_off + i] = (zeros, then deg from `skip`) · factor, per alignment.
// BALANCED: in two-float, signals and out with their lo parts, factors
// hi and lo per pair.
[shader("compute")]
[numthreads(64, 1, 1)]
void apply_lag(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> signals,
    uniform RO<Alignment> alignments,
    uniform RO<real> factors,
    uniform RW<real> out,
#if BALANCED
    uniform RW<real> lo,
#endif
    uniform uint num_pairs,
    uniform uint max_len)
{
    uint id = zimt_index(tid);
    uint k = id / max_len;
    uint i = id % max_len;
    if (k >= num_pairs) return;
    Alignment a = alignments[k];
    if (i >= a.len) return;
#if BALANCED
    DF x = DF(0);
    if (i >= a.zeros) {
        uint src = a.deg_off + a.skip + i - a.zeros;
        x = mul(DF(signals[src], lo[src]), DF(factors[k * 2], factors[k * 2 + 1]));
    }
    out[a.out_off + i] = x.hi;
    lo[a.out_off + i] = x.lo;
#else
    out[a.out_off + i] = i < a.zeros ? real(0) : signals[a.deg_off + a.skip + i - a.zeros] * factors[k];
#endif
}
