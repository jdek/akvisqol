// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// NSIM in REAL, following nsim.zig's operation order (3x3 replicate-
// clamped Gaussian convolution per cell, taps in `Taps.at` order, sums
// serial and row-major), so f64 without contraction matches the CPU.
//
// window: (9,) taps, row-major from the top-left neighbour.
import df;
import tables;
import zimt;

typealias real = REAL;

#if BALANCED
// df's add, which Cell.add hides.
DF plus(DF a, DF b) { return add(a, b); }
#endif

// One cell's 3x3 window sums. EXACT: conv(r), conv(d), conv(r²), conv(d²),
// conv(r·d), then simCell. Otherwise about the centre values (cr, cd), so
// f32 keeps the variances that cancellation against the means² would lose.
struct Cell
{
#if EXACT
    real mr, md, crsq, cdsq, crd;

    __init(real cr, real cd)
    {
        mr = 0; md = 0; crsq = 0; cdsq = 0; crd = 0;
    }

    [mutating]
    void add(real w, real rv, real dv)
    {
        mr += w * rv;
        md += w * dv;
        crsq += w * (rv * rv);
        cdsq += w * (dv * dv);
        crd += w * (rv * dv);
    }

    // simCell
    real sim(real c1, real c3)
    {
        real rms = mr * mr;
        real srs = crsq - rms;
        real dms = md * md;
        real sds = cdsq - dms;
        real mrd = mr * md;
        real srd = crd - mrd;
        real intensity = (real(2) * mrd + c1) / (rms + dms + c1);
        real prod = srs * sds;
        real denom = prod < real(0) ? c3 : sqrt(prod) + c3;
        return intensity * ((srd + c3) / denom);
    }
#elif BALANCED
    // The centred form in two-float, the similarity's divisions and root
    // too: Vulkan's f32 ones need not be correctly rounded.
    real cr, cd;
    DF sr, sd, qr, qd, qrd;

    __init(real r0, real d0)
    {
        cr = r0; cd = d0; sr = DF(0); sd = DF(0); qr = DF(0); qd = DF(0); qrd = DF(0);
    }

    [mutating]
    void add(real w, real rv, real dv)
    {
        DF er = sub(DF(rv), DF(cr));
        DF ed = sub(DF(dv), DF(cd));
        DF ww = DF(w);
        sr = plus(sr, mul(ww, er));
        sd = plus(sd, mul(ww, ed));
        qr = plus(qr, mul(ww, mul(er, er)));
        qd = plus(qd, mul(ww, mul(ed, ed)));
        qrd = plus(qrd, mul(ww, mul(er, ed)));
    }

    real sim(real c1, real c3)
    {
        DF mr = plus(DF(cr), sr);
        DF md = plus(DF(cd), sd);
        DF srs = sub(qr, mul(sr, sr));
        DF sds = sub(qd, mul(sd, sd));
        DF srd = sub(qrd, mul(sr, sd));
        DF mrd = mul(mr, md);
        DF k1 = DF(c1), k3 = DF(c3);
        DF intensity = div(plus(mul(DF(2), mrd), k1), plus(plus(mul(mr, mr), mul(md, md)), k1));
        DF prod = mul(srs, sds);
        DF denom = prod.hi < 0 ? k3 : plus(sqrt(prod), k3);
        DF s = mul(intensity, div(plus(srd, k3), denom));
        return s.hi + s.lo;
    }
#else
    real cr, cd, sr, sd, qr, qd, qrd;

    __init(real r0, real d0)
    {
        cr = r0; cd = d0; sr = 0; sd = 0; qr = 0; qd = 0; qrd = 0;
    }

    [mutating]
    void add(real w, real rv, real dv)
    {
        real er = rv - cr;
        real ed = dv - cd;
        sr += w * er;
        sd += w * ed;
        qr += w * (er * er);
        qd += w * (ed * ed);
        qrd += w * (er * ed);
    }

    real sim(real c1, real c3)
    {
        real mr = cr + sr;
        real md = cd + sd;
        real srs = qr - sr * sr;
        real sds = qd - sd * sd;
        real srd = qrd - sr * sd;
        real mrd = mr * md;
        real intensity = (real(2) * mrd + c1) / (mr * mr + md * md + c1);
        real prod = srs * sds;
        real denom = prod < real(0) ? c3 : sqrt(prod) + c3;
        return intensity * ((srd + c3) / denom);
    }
#endif
}

// One side's window terms (`windowTerms`), c the centre value.
struct Terms
{
    real c, m, v;
}

// EXACT: conv(x) and conv(x²) - conv(x)², `Taps.at`'s order. Otherwise
// Σw(x - c) and Σw(x - c)² - (Σw(x - c))², c the centre.
Terms windowTerms(real x[9], real centre, RO<real> window)
{
    real m = 0, q = 0;
    for (uint k = 0; k < 9; k++) {
#if EXACT
        m += window[k] * x[k];
        q += window[k] * (x[k] * x[k]);
#else
        real e = x[k] - centre;
        m += window[k] * e;
        q += window[k] * (e * e);
#endif
    }
    Terms s = { centre, m, q - m * m };
    return s;
}

// simCell from both sides' terms and the cross term (EXACT: conv(r·d);
// otherwise Σw(r - cr)(d - cd)).
real cellSim(Terms r, Terms d, real cross, real c1, real c3)
{
#if EXACT
    real mr = r.m, md = d.m;
    real srd = cross - mr * md;
#else
    real mr = r.c + r.m, md = d.c + d.m;
    real srd = cross - r.m * d.m;
#endif
    real mrd = mr * md;
    real intensity = (real(2) * mrd + c1) / (mr * mr + md * md + c1);
    real prod = r.v * d.v;
    real denom = prod < real(0) ? c3 : sqrt(prod) + c3;
    return intensity * ((srd + c3) / denom);
}

// deg_terms[plane + (band · width + frame) · 2 + {0, 1}]: the window terms
// over the zero-padded plane, clamped at its edges; one thread per cell.
[shader("compute")]
[numthreads(64, 1, 1)]
void deg_plane(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> deg_spec,
    uniform RO<real> window,
    uniform RO<DegPlane> planes,
    uniform RW<real> deg_terms,
    uniform uint num_planes,
    uniform uint max_cells,
    uniform uint num_bands)
{
    uint id = zimt_index(tid);
    uint p = id / max_cells;
    uint cell = id % max_cells;
    if (p >= num_planes) return;
    DegPlane pl = planes[p];
    if (cell >= num_bands * pl.width) return;
    int b = int(cell / pl.width);
    int f = int(cell % pl.width);
    real x[9];
    for (int dr = -1; dr <= 1; dr++) for (int dc = -1; dc <= 1; dc++) {
        uint rr = uint(clamp(b + dr, 0, int(num_bands) - 1));
        uint cc = uint(clamp(f + dc, 0, int(pl.width) - 1));
        x[(dr + 1) * 3 + dc + 1] = cc < pl.deg_frames ? deg_spec[pl.deg_off + rr * pl.deg_frames + cc] : real(0);
    }
    Terms s = windowTerms(x, x[4], window);
    deg_terms[pl.plane + cell * 2] = s.m;
    deg_terms[pl.plane + cell * 2 + 1] = s.v;
}

// ref_terms[((patch · bands + band) · patch_size + col) · 2 + {0, 1}]: the
// window terms of each ref patch cell, clamped at the patch.
[shader("compute")]
[numthreads(64, 1, 1)]
void ref_terms(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> ref_spec,
    uniform RO<real> window,
    uniform RO<PatchSearch> patches,
    uniform RW<real> ref_terms,
    uniform uint num_patches,
    uniform uint num_bands,
    uniform uint patch_size)
{
    uint id = zimt_index(tid);
    uint cells = num_bands * patch_size;
    uint p = id / cells;
    if (p >= num_patches) return;
    int b = int((id % cells) / patch_size);
    int c = int(id % patch_size);
    PatchSearch ps = patches[p];
    real x[9];
    for (int dr = -1; dr <= 1; dr++) for (int dc = -1; dc <= 1; dc++) {
        uint rr = uint(clamp(b + dr, 0, int(num_bands) - 1));
        uint cc = uint(clamp(c + dc, 0, int(patch_size) - 1));
        x[(dr + 1) * 3 + dc + 1] = ref_spec[ps.ref_off + rr * ps.ref_frames + ps.ref_frame + cc];
    }
    Terms s = windowTerms(x, x[4], window);
    ref_terms[id * 2] = s.m;
    ref_terms[id * 2 + 1] = s.v;
}

static const uint TILE_THREADS = 64;
static const uint MAX_BANDS = 32;
static const uint MAX_PATCH = 32;
static const uint DEG_TILE = TILE_THREADS + MAX_PATCH - 1;

groupshared real ref_tile[MAX_BANDS * MAX_PATCH];
groupshared real deg_tile[MAX_BANDS * DEG_TILE];

// `measureSimilarityAt` of each patch against its degraded offsets
// [lo, hi], `TILE_THREADS` consecutive offsets per thread group, both
// patches tiled in group memory. The sides' terms come from `ref_terms`
// and `deg_plane`, except at the edge columns, which the patch clamps
// differently from the plane. Degraded frames past `deg_frames` read zero.
[shader("compute")]
[numthreads(TILE_THREADS, 1, 1)]
void nsim_table(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> ref_spec,
    uniform RO<real> deg_spec,
    uniform RO<real> window,
    uniform RO<PatchSearch> patches,
    uniform RO<SimTask> tasks,
    uniform RO<real> ref_terms,
    uniform RO<real> deg_terms,
    uniform RW<real> sims,
    uniform uint num_tasks,
    uniform uint num_bands,
    uniform uint patch_size,
    uniform real c1,
    uniform real c3)
{
    uint task = zimt_index(tid) / TILE_THREADS;
    uint lane = tid.x % TILE_THREADS;
    if (task >= num_tasks) return;
    SimTask tk = tasks[task];
    PatchSearch ps_ = patches[tk.patch];
    uint first = tk.first;

    uint cols = TILE_THREADS + patch_size - 1;
    for (uint i = lane; i < num_bands * patch_size; i += TILE_THREADS) {
        uint b = i / patch_size;
        ref_tile[i] = ref_spec[ps_.ref_off + b * ps_.ref_frames + ps_.ref_frame + i % patch_size];
    }
    for (uint i = lane; i < num_bands * cols; i += TILE_THREADS) {
        uint b = i / cols;
        uint col = first + i % cols;
        deg_tile[b * DEG_TILE + i % cols] = col < ps_.deg_frames ? deg_spec[ps_.deg_off + b * ps_.deg_frames + col] : real(0);
    }
    GroupMemoryBarrierWithGroupSync();
    uint off = first + lane;
    if (off > ps_.hi) return;

    int nb = int(num_bands);
    int ps = int(patch_size);
    uint rt = tk.patch * num_bands * patch_size;
    real sum = 0;
    for (int r = 0; r < nb; r++) {
        for (int c = 0; c < ps; c++) {
            uint ri = (rt + uint(r * ps + c)) * 2;
            Terms rs = { ref_tile[uint(r * ps + c)], ref_terms[ri], ref_terms[ri + 1] };
            real dc0 = deg_tile[uint(r) * DEG_TILE + lane + uint(c)];
            real d[9];
            real cross = 0;
            for (int dr = -1; dr <= 1; dr++) {
                uint rr = uint(clamp(r + dr, 0, nb - 1));
                for (int dc = -1; dc <= 1; dc++) {
                    uint cc = uint(clamp(c + dc, 0, ps - 1));
                    uint k = uint((dr + 1) * 3 + dc + 1);
                    real rv = ref_tile[rr * patch_size + cc];
                    d[k] = deg_tile[rr * DEG_TILE + lane + cc];
#if EXACT
                    cross += window[k] * (rv * d[k]);
#else
                    cross += window[k] * ((rv - rs.c) * (d[k] - dc0));
#endif
                }
            }
            Terms ds;
            if (c == 0 || c == ps - 1) {
                ds = windowTerms(d, dc0, window);
            } else {
                uint di = ps_.plane + (uint(r) * ps_.width + off + uint(c)) * 2;
                ds.c = dc0;
                ds.m = deg_terms[di];
                ds.v = deg_terms[di + 1];
            }
            sum += cellSim(rs, ds, cross, c1, c3);
        }
    }
    sims[ps_.row + off] = sum / real(nb * ps);
}

real refAt(RO<real> spec, uint o, uint nf, uint col0, uint b, uint c) { return spec[o + b * nf + col0 + c]; }
real degAt(RO<real> spec, uint o, uint nf, uint col0, uint b, uint c) { return col0 + c < nf ? spec[o + b * nf + col0 + c] : real(0); }

real bandSim(RO<real> ref_spec, RO<real> deg_spec, RO<real> window, PatchPair pp, uint b, uint c, uint nb, real c1, real c3)
{
    uint ncols = pp.cols;
    Cell cell = Cell(refAt(ref_spec, pp.ref_off, pp.ref_frames, pp.ref_frame, b, c), degAt(deg_spec, pp.deg_off, pp.deg_frames, pp.deg_frame, b, c));
    for (int dr = -1; dr <= 1; dr++) {
        uint rr = uint(clamp(int(b) + dr, 0, int(nb) - 1));
        for (int dc = -1; dc <= 1; dc++) {
            uint cc = uint(clamp(int(c) + dc, 0, int(ncols) - 1));
            cell.add(window[(dr + 1) * 3 + dc + 1], refAt(ref_spec, pp.ref_off, pp.ref_frames, pp.ref_frame, rr, cc), degAt(deg_spec, pp.deg_off, pp.deg_frames, pp.deg_frame, rr, cc));
        }
    }
    return cell.sim(c1, c3);
}

// `measurePatchSimilarity` per (row, band) where `active[row]`.
// stats: (rows, num_bands, 3) — mean, sample stddev, degraded energy.
[shader("compute")]
[numthreads(64, 1, 1)]
void nsim_bands(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> ref_spec,
    uniform RO<real> deg_spec,
    uniform RO<real> window,
    uniform RO<PatchPair> rows,
    uniform RO<uint> active,
    uniform RW<real> stats,
    uniform uint num_rows,
    uniform uint num_bands,
    uniform real c1,
    uniform real c3)
{
    uint id = zimt_index(tid);
    uint row = id / num_bands;
    uint b = id % num_bands;
    if (row >= num_rows || active[row] == 0) return;
    PatchPair pp = rows[row];
    uint ncols = pp.cols;
#if BALANCED
    // The column sums in two-float: serial f32 ones lose ~ncols·eps.
    DF deg_sum = DF(0);
    for (uint c = 0; c < ncols; c++) deg_sum = add(deg_sum, DF(degAt(deg_spec, pp.deg_off, pp.deg_frames, pp.deg_frame, b, c)));
    DF sim_sum = DF(0);
    for (uint c = 0; c < ncols; c++) sim_sum = add(sim_sum, DF(bandSim(ref_spec, deg_spec, window, pp, b, c, num_bands, c1, c3)));
    DF n = DF(real(ncols));
    DF mean2 = div(sim_sum, n);
    real mean = mean2.hi + mean2.lo;
    real dev = 0;
    if (ncols > 1) {
        DF ss = DF(0);
        for (uint c = 0; c < ncols; c++) {
            DF d = sub(DF(bandSim(ref_spec, deg_spec, window, pp, b, c, num_bands, c1, c3)), mean2);
            ss = add(ss, mul(d, d));
        }
        DF v = div(ss, DF(real(ncols) - real(1)));
        dev = sqrt(v.hi + v.lo);
    }
    DF dm = div(deg_sum, n);
    real deg_mean = dm.hi + dm.lo;
#else
    real inv_ncols = real(1) / real(ncols);

    real deg_sum = 0;
    for (uint c = 0; c < ncols; c++) deg_sum += degAt(deg_spec, pp.deg_off, pp.deg_frames, pp.deg_frame, b, c);
    real sim_sum = 0;
    for (uint c = 0; c < ncols; c++) sim_sum += bandSim(ref_spec, deg_spec, window, pp, b, c, num_bands, c1, c3);
    real mean = sim_sum * inv_ncols;
    real dev = 0;
    if (ncols > 1) {
        real ss = 0;
        for (uint c = 0; c < ncols; c++) {
            real d = bandSim(ref_spec, deg_spec, window, pp, b, c, num_bands, c1, c3) - mean;
            ss += d * d;
        }
        dev = sqrt(ss / (real(ncols) - real(1)));
    }
    real deg_mean = deg_sum * inv_ncols;
#endif
    uint o = (row * num_bands + b) * 3;
    stats[o + 0] = mean;
    stats[o + 1] = dev;
    stats[o + 2] = deg_mean;
}

// Backward
//
// simCell about the centre values (constants: with Σw = 1 the means don't
// depend on them), and its adjoint into gr, gd. prod <= 0 takes c3, so a
// flat window's root contributes no slope. By hand: Slang's bwd_diff of
// this gets ∂/∂sds wrong where sqrt(srs·sds) is small (slangc 2026.19).
struct SimTerms
{
    real er[9], ed[9];
    real sr, sd, mr, md, srs, sds, srd, prod;

    __init(real r[9], real d[9], real w[9])
    {
        sr = 0; sd = 0;
        real qr = 0, qd = 0, qrd = 0;
        for (uint k = 0; k < 9; k++) {
            er[k] = r[k] - r[4];
            ed[k] = d[k] - d[4];
            sr += w[k] * er[k];
            sd += w[k] * ed[k];
            qr += w[k] * (er[k] * er[k]);
            qd += w[k] * (ed[k] * ed[k]);
            qrd += w[k] * (er[k] * ed[k]);
        }
        mr = r[4] + sr;
        md = d[4] + sd;
        srs = qr - sr * sr;
        sds = qd - sd * sd;
        srd = qrd - sr * sd;
        prod = srs * sds;
    }

    real denom(real c3) { return prod > real(0) ? sqrt(prod) + c3 : c3; }

    real sim(real c1, real c3)
    {
        real intensity = (real(2) * (mr * md) + c1) / (mr * mr + md * md + c1);
        return intensity * ((srd + c3) / denom(c3));
    }
}

void simBwd(real r[9], real d[9], real w[9], real c1, real c3, real g, out real gr[9], out real gd[9])
{
    SimTerms t = SimTerms(r, d, w);
    real a = real(2) * (t.mr * t.md) + c1;
    real bb = t.mr * t.mr + t.md * t.md + c1;
    real den = t.denom(c3);
    real n = t.srd + c3;
    real g_i = g * (n / den);
    real g_s = g * (a / bb);
    real g_srd = g_s / den;
    real g_den = -g_s * n / (den * den);
    real g_prod = t.prod > real(0) ? g_den / (real(2) * sqrt(t.prod)) : real(0);
    real g_srs = g_prod * t.sds;
    real g_sds = g_prod * t.srs;
    real g_a = g_i / bb;
    real g_b = -g_i * a / (bb * bb);
    real g_mr = g_a * real(2) * t.md + g_b * real(2) * t.mr;
    real g_md = g_a * real(2) * t.mr + g_b * real(2) * t.md;
    real g_sr = g_mr - real(2) * t.sr * g_srs - t.sd * g_srd;
    real g_sd = g_md - real(2) * t.sd * g_sds - t.sr * g_srd;
    for (uint k = 0; k < 9; k++) {
        gr[k] = w[k] * (g_sr + real(2) * t.er[k] * g_srs + t.ed[k] * g_srd);
        gd[k] = w[k] * (g_sd + real(2) * t.ed[k] * g_sds + t.er[k] * g_srd);
    }
}

// `nsim_bands`' backward per (row, band, col): ∂L/∂ of the cell's 3x3
// window, from ∂L/∂(mean, stddev) of its band (`g_stats`, as `stats`).
// cells: (rows, num_bands, max_cols, 18) — ref then deg, tap order.
[shader("compute")]
[numthreads(64, 1, 1)]
void nsim_bands_bwd(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> ref_spec,
    uniform RO<real> deg_spec,
    uniform RO<real> window,
    uniform RO<PatchPair> rows,
    uniform RO<uint> active,
    uniform RO<real> stats,
    uniform RO<real> g_stats,
    uniform RW<real> cells,
    uniform uint num_rows,
    uniform uint num_bands,
    uniform uint max_cols,
    uniform real c1,
    uniform real c3)
{
    uint id = zimt_index(tid);
    uint row = id / (num_bands * max_cols);
    uint b = (id / max_cols) % num_bands;
    uint c = id % max_cols;
    if (row >= num_rows || active[row] == 0) return;
    PatchPair pp = rows[row];
    uint n = pp.cols;
    if (c >= n) return;
    uint o = (row * num_bands + b) * 3;
    real g_mean = g_stats[o];
    real g_dev = g_stats[o + 1];

    real w[9], r[9], d[9];
    for (int dr = -1; dr <= 1; dr++) {
        uint rr = uint(clamp(int(b) + dr, 0, int(num_bands) - 1));
        for (int dc = -1; dc <= 1; dc++) {
            uint cc = uint(clamp(int(c) + dc, 0, int(n) - 1));
            uint k = uint((dr + 1) * 3 + dc + 1);
            w[k] = window[k];
            r[k] = refAt(ref_spec, pp.ref_off, pp.ref_frames, pp.ref_frame, rr, cc);
            d[k] = degAt(deg_spec, pp.deg_off, pp.deg_frames, pp.deg_frame, rr, cc);
        }
    }
    real g = g_mean / real(n);
    real dev = stats[o + 1];
    if (n > 1 && dev > real(0) && g_dev != real(0)) {
        real s = SimTerms(r, d, w).sim(c1, c3);
        g += g_dev * (s - stats[o]) / ((real(n) - real(1)) * dev);
    }
    real gr[9], gd[9];
    simBwd(r, d, w, c1, c3, g, gr, gd);
    uint at = ((row * num_bands + b) * max_cols + c) * 18;
    for (uint k = 0; k < 9; k++) {
        cells[at + k] = gr[k];
        cells[at + 9 + k] = gd[k];
    }
}

// ∂L/∂ each patch cell per (row, side, band, col): the windows clamped
// onto it, and on the deg side the band energy's share.
// patch_grad: (rows, 2, num_bands, max_cols).
[shader("compute")]
[numthreads(64, 1, 1)]
void nsim_cells_bwd(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<PatchPair> rows,
    uniform RO<uint> active,
    uniform RO<real> g_stats,
    uniform RO<real> cells,
    uniform RW<real> patch_grad,
    uniform uint num_rows,
    uniform uint num_bands,
    uniform uint max_cols)
{
    uint id = zimt_index(tid);
    uint row = id / (2 * num_bands * max_cols);
    uint side = (id / (num_bands * max_cols)) % 2;
    uint b = (id / max_cols) % num_bands;
    uint c = id % max_cols;
    if (row >= num_rows) return;
    PatchPair pp = rows[row];
    uint n = pp.cols;
    real sum = 0;
    if (active[row] != 0 && c < n) {
        // Sources within one cell whose clamped taps land here.
        for (int sb = int(b) - 1; sb <= int(b) + 1; sb++) {
            if (sb < 0 || sb >= int(num_bands)) continue;
            for (int sc = int(c) - 1; sc <= int(c) + 1; sc++) {
                if (sc < 0 || sc >= int(n)) continue;
                uint at = ((row * num_bands + uint(sb)) * max_cols + uint(sc)) * 18 + side * 9;
                for (int dr = -1; dr <= 1; dr++) {
                    if (clamp(sb + dr, 0, int(num_bands) - 1) != int(b)) continue;
                    for (int dc = -1; dc <= 1; dc++) {
                        if (clamp(sc + dc, 0, int(n) - 1) != int(c)) continue;
                        sum += cells[at + uint((dr + 1) * 3 + dc + 1)];
                    }
                }
            }
        }
        if (side == 1) sum += g_stats[(row * num_bands + b) * 3 + 2] / real(n);
    }
    patch_grad[((row * 2 + side) * num_bands + b) * max_cols + c] = sum;
}

// Each prepared spectrogram's gradient, per cell: its rows' patch
// gradients covering it (deg frames past `deg_frames` aren't cells).
[shader("compute")]
[numthreads(64, 1, 1)]
void spec_grad(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<SpecGather> specs,
    uniform RO<PatchPair> rows,
    uniform RO<uint> active,
    uniform RO<real> patch_grad,
    uniform RW<real> out,
    uniform uint num_specs,
    uniform uint max_cells,
    uniform uint num_bands,
    uniform uint max_cols)
{
    uint id = zimt_index(tid);
    uint s = id / max_cells;
    uint cell = id % max_cells;
    if (s >= num_specs) return;
    SpecGather sg = specs[s];
    if (cell >= num_bands * sg.frames) return;
    uint b = cell / sg.frames;
    uint f = cell % sg.frames;
    real sum = 0;
    for (uint i = 0; i < sg.count; i++) {
        uint row = sg.first + i;
        if (active[row] == 0) continue;
        PatchPair pp = rows[row];
        uint first = sg.side == 0 ? pp.ref_frame : pp.deg_frame;
        if (f < first || f - first >= pp.cols) continue;
        sum += patch_grad[((row * 2 + sg.side) * num_bands + b) * max_cols + f - first];
    }
    out[sg.off + cell] = sum;
}
