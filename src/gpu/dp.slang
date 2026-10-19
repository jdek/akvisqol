// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// `dp.findOptimalDegPatchesFromSims` on the device: the recurrence over each
// pair's NSIM table and the backtrack, then the matched patches' NSIM rows
// and, after `nsim_bands`, their similarities. Ties and the zeroed tables
// follow the CPU.
import tables;
import zimt;

typealias real = REAL;

static const uint NO_BACK = 0xffffffffu;

#if EXACT
static const real NEG_INF = asdouble(0x00000000u, 0xFFF00000u);
#else
static const real NEG_INF = asfloat(0xFF800000u);
#endif

static const uint DP_THREADS = 256;

groupshared real seg_max[DP_THREADS];
groupshared int seg_idx[DP_THREADS];

// Running max, `>=` as the CPU scans: later entries win ties.
void keep(inout real m, inout int idx, real v, int j)
{
    if (v >= m) {
        m = v;
        idx = j;
    }
}

// dp, bt and matches: zeroed; dp and bt rows `deg_frames` wide from each
// pair's `table`, sims laid out the same (`PatchSearch.row`). One thread
// group per pair: rows in order, each row's running maximum over the
// previous row a blockwise prefix scan.
[shader("compute")]
[numthreads(DP_THREADS, 1, 1)]
void dp_search(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<DpPair> pairs,
    uniform RO<PatchSearch> patches,
    uniform RO<real> sims,
    uniform RW<real> dp,
    uniform RW<uint> bt,
    uniform RW<Match> matches,
    uniform uint num_pairs)
{
    uint k = zimt_index(tid) / DP_THREADS;
    uint lane = tid.x % DP_THREADS;
    if (k >= num_pairs) return;
    DpPair pr = pairs[k];
    uint w = pr.deg_frames;

    for (uint pi = 0; pi < pr.patches; pi++) {
        PatchSearch ps = patches[pr.first + pi];
        uint row = pr.table + pi * w;
        if (pi == 0) {
            for (uint s = ps.lo + lane; s <= ps.hi; s += DP_THREADS) {
                dp[row + s] = sims[row + s];
                bt[row + s] = NO_BACK;
            }
            AllMemoryBarrierWithGroupSync();
            continue;
        }
        uint prev_row = row - w;
        uint from = patches[pr.first + pi - 1].lo;
        // This thread's entries [from + lane·span, ..+ span) of [from, hi].
        uint span = (ps.hi + 1 - from + DP_THREADS - 1) / DP_THREADS;
        uint first = from + lane * span;
        uint end = min(first + span, ps.hi + 1);
        real m = NEG_INF;
        int idx = -1;
        for (uint j = first; j < end; j++) keep(m, idx, dp[prev_row + j], int(j));
        seg_max[lane] = m;
        seg_idx[lane] = idx;
        GroupMemoryBarrierWithGroupSync();
        // Prefix over the segments before this one.
        real rm = NEG_INF;
        int ri = -1;
        for (uint t = 0; t < lane; t++) if (seg_idx[t] >= 0) keep(rm, ri, seg_max[t], seg_idx[t]);
        for (uint s = first; s < end; s++) {
            real no_move = dp[prev_row + s];
            if (s >= ps.lo) {
                real similarity = sims[row + s] + rm;
                int past = ri;
                if (no_move > similarity) {
                    similarity = no_move;
                    past = int(s);
                }
                dp[row + s] = similarity;
                bt[row + s] = past < 0 ? NO_BACK : uint(past);
            }
            keep(rm, ri, no_move, int(s));
        }
        AllMemoryBarrierWithGroupSync();
    }

    if (lane != 0) return;
    uint last = pr.patches - 1;
    PatchSearch lp = patches[pr.first + last];
    real best = NEG_INF;
    uint cur = 0;
    for (uint off = lp.lo; off <= lp.hi; off++) {
        real v = dp[pr.table + last * w + off];
        if (v > best) {
            best = v;
            cur = off;
        }
    }
    for (int p = int(last); p >= 0; p--) {
        uint back = bt[pr.table + uint(p) * w + cur];
        Match mt = { cur, 1, back != cur ? 1 : 0 };
        matches[pr.first + uint(p)] = mt;
        if (back == NO_BACK) break;
        cur = back;
    }
}

// The NSIM row of each visited match: its ref patch against the deg patch
// at the matched offset.
[shader("compute")]
[numthreads(64, 1, 1)]
void match_rows(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<PatchSearch> patches,
    uniform RO<Match> matches,
    uniform RW<PatchPair> rows,
    uniform RW<uint> active,
    uniform uint num_patches,
    uniform uint patch_size)
{
    uint m = zimt_index(tid);
    if (m >= num_patches) return;
    PatchSearch ps = patches[m];
    PatchPair pp = { ps.ref_off, ps.ref_frames, ps.ref_frame, ps.deg_off, ps.deg_frames, matches[m].deg_frame, patch_size };
    rows[m] = pp;
    active[m] = matches[m].visited;
}

// similarity = mean of the band means; an invalid match keeps its stddevs
// and energies but zeroes its means and similarity.
[shader("compute")]
[numthreads(64, 1, 1)]
void match_finalize(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<Match> matches,
    uniform RW<real> stats,
    uniform RW<real> similarity,
    uniform uint num_patches,
    uniform uint num_bands)
{
    uint m = zimt_index(tid);
    if (m >= num_patches || matches[m].visited == 0) return;
    bool valid = matches[m].valid != 0;
    real sum = 0;
    for (uint b = 0; b < num_bands; b++) {
        sum += stats[(m * num_bands + b) * 3];
        if (!valid) stats[(m * num_bands + b) * 3] = 0;
    }
    similarity[m] = valid ? sum / real(num_bands) : real(0);
}
