// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// `realign.planRealign` and `finishRealign` on the device: each matched
// patch's degraded slice from its DP match, then after the lag search and
// `gammatone_patches` the trimmed spectrograms' rows, and finally the
// rescore kept unless worse. Rows are the lag search's (by FFT size);
// `RealignPatch.patch` is the match. Status 2: no realignment.
import tables;
import trim;
import zimt;

typealias real = REAL;

// Each row's deg side: the host's `sliceLayout` for its match's offset
// (the CPU's f64 times), into the aligned deg signal.
[shader("compute")]
[numthreads(64, 1, 1)]
void realign_rows(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<RealignPatch> patches,
    uniform RO<Match> matches,
    uniform RO<Side> slices,
    uniform RW<LagRow> rows,
    uniform RW<LagParams> params,
    uniform uint num_rows)
{
    uint row = zimt_index(tid);
    if (row >= num_rows) return;
    RealignPatch rp = patches[row];
    Match m = matches[rp.patch];
    Side s = { rp.deg_off, 0, 0 };
    uint base = 0;
    if (m.visited != 0 && m.valid != 0) {
        Side l = slices[rp.slices + m.deg_frame];
        base = l.start;
        s.start = rp.deg_off + l.start;
        s.pad = l.pad;
        s.len = l.len;
    }
    rows.p[row].b = s;
    rows.p[row].b_base = base;
    LagParams lp = { max(max(rows[row].a.total(), s.total()), 1u) - 1, 0 };
    params[row] = lp;
}

// After the lag search: each row's trim, its spectrogram rows for
// `spec_prep` and `nsim_bands`, and status 2 where the CPU skips it (no
// valid match, a slice under a window, nothing left after trimming).
[shader("compute")]
[numthreads(64, 1, 1)]
void realign_frames(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<RealignPatch> patches,
    uniform RO<Match> matches,
    uniform RO<LagRow> rows,
    uniform RO<int> lags,
    uniform RW<uint> status,
    uniform RO<uint> back,
    uniform RW<SpecPair> specs,
    uniform RW<PatchPair> pairs,
    uniform RW<uint> active,
    uniform RW<Realigned> realigned,
    uniform uint num_rows,
    uniform uint num_bands,
    uniform uint window_size,
    uniform uint hop_size)
{
    uint row = zimt_index(tid);
    if (row >= num_rows) return;
    LagRow r = rows[row];
    Match m = matches[patches[row].patch];
    Trim t = trim(r, lags[row], back);
    uint frames = t.frames(window_size, hop_size);
    bool live = m.visited != 0 && m.valid != 0 && r.a.total() >= window_size && r.b.total() >= window_size;
    if (!live) status[row] = 2;
    bool on = live && status[row] == 0 && frames > 0;
    uint base = r.first_slot * 2 * num_bands;
    SpecPair sp = { base, on ? frames : 0, base + num_bands * r.slots, on ? frames : 0 };
    specs[row] = sp;
    PatchPair pp = { base, frames, 0, base + num_bands * r.slots, frames, 0, frames };
    pairs[row] = pp;
    active[row] = on ? 1 : 0;
    Realigned ra = { lags[row], r.b.total(), 0 };
    realigned[patches[row].patch] = ra;
}

// `finishRealign`: the rescore replaces the match unless strictly worse.
// stats: the matches' (patch, band, 3); rstats: the rows'.
[shader("compute")]
[numthreads(64, 1, 1)]
void realign_accept(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<RealignPatch> patches,
    uniform RO<uint> active,
    uniform RO<real> rstats,
    uniform RW<real> stats,
    uniform RW<real> similarity,
    uniform RW<Realigned> realigned,
    uniform uint num_rows,
    uniform uint num_bands)
{
    uint row = zimt_index(tid);
    if (row >= num_rows || active[row] == 0) return;
    uint m = patches[row].patch;
    real sum = 0;
    for (uint b = 0; b < num_bands; b++) sum += rstats[(row * num_bands + b) * 3];
    real mean = sum / real(num_bands);
    if (mean < similarity[m]) return;
    for (uint i = 0; i < num_bands * 3; i++) stats[m * num_bands * 3 + i] = rstats[row * num_bands * 3 + i];
    similarity[m] = mean;
    realigned.p[m].accepted = 1;
}
