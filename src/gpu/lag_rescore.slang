// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// After `lag_cands`: each candidate's f64 dot product of the envelopes
// (`xcorr.rescore`), in chunks of `chunk` terms per thread group,
// then the row's lag, as `refineLag` picks it. More than `cap`
// candidates: status 1, for the host to search instead.
//
// env: per group row, sides a and b at (row * 2 + side) * n (env_write).
// part: (rows, cap, chunks) chunk sums.
import tables;
import zimt;

static const uint THREADS = 64;

groupshared double acc[THREADS];

[shader("compute")]
[numthreads(THREADS, 1, 1)]
void lag_rescore(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<double> env,
    uniform RO<LagRow> rows,
    uniform RO<uint> count,
    uniform RO<int> cands,
    uniform RW<double> part,
    uniform uint first,
    uniform uint log2_n,
    uniform uint num_rows,
    uniform uint chunk,
    uniform uint chunks,
    uniform uint cap)
{
    uint g = zimt_index(tid) / THREADS;
    uint lane = tid.x % THREADS;
    if (g >= num_rows * chunks) return;
    uint row = g / chunks;
        uint c = count[row];
    if (c > cap) return;
    uint n = 1u << log2_n;
    int la = int(rows[first + row].a.total());
    int lb = int(rows[first + row].b.total());
    int lo = int((g % chunks) * chunk);
    for (uint k = 0; k < c; k++) {
        int lag = cands[row * cap + k];
        // Σ_t a[t + lag]·b[t] over the overlap.
        uint a = (row * 2) * n + uint(max(lag, 0));
        uint b = (row * 2 + 1) * n + uint(max(-lag, 0));
        int hi = min(lo + int(chunk), lag >= 0 ? min(la - lag, lb) : min(la, lb + lag));
        double s = 0;
        for (int t = lo + int(lane); t < hi; t += int(THREADS)) s += env[a + uint(t)] * env[b + uint(t)];
        acc[lane] = s;
        GroupMemoryBarrierWithGroupSync();
        for (uint h = THREADS / 2; h > 0; h >>= 1) {
            if (lane < h) acc[lane] += acc[lane + h];
            GroupMemoryBarrierWithGroupSync();
        }
        if (lane == 0) part[(row * cap + k) * chunks + g % chunks] = acc[0];
        GroupMemoryBarrierWithGroupSync();
    }
}

// The first of the largest |score| in ascending lag order.
[shader("compute")]
[numthreads(64, 1, 1)]
void lag_pick(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<uint> count,
    uniform RO<int> cands,
    uniform RO<double> part,
    uniform RW<int> lags,
    uniform RW<uint> status,
    uniform uint first,
    uniform uint num_rows,
    uniform uint chunks,
    uniform uint cap)
{
    uint row = zimt_index(tid);
    if (row >= num_rows) return;
    uint c = count[row];
    if (c > cap) {
        lags[first + row] = 0;
        status[first + row] = 1;
        return;
    }
    double best = -1;
    int lag = 0;
    for (uint k = 0; k < c; k++) {
        double s = 0;
        for (uint i = 0; i < chunks; i++) s += part[(row * cap + k) * chunks + i];
        int l = cands[row * cap + k];
        double a = abs(s);
        if (a > best || (a == best && l < lag)) {
            best = a;
            lag = l;
        }
    }
    lags[first + row] = lag;
    status[first + row] = 0;
}
