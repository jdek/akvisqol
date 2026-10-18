// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// NSIM of ref patch `row` vs the degraded patch at frame `lo + k`, one thread
// per (row, k). Mirrors `Comparator.measureSimilarityScalar`; degraded frames
// past nf_deg read as zero.
//
// rows: (num_rows, 8) u32 — task_base, count, lo, ref_base, nf_ref, ref_col,
//       deg_base, nf_deg.
import nsim_common;
import zimt;

float degAt(StructuredBuffer<float> deg, uint base, uint nf, int band, int col)
{
    return uint(col) < nf ? deg[base + uint(band) * nf + uint(col)] : 0.0;
}

[shader("compute")]
[numthreads(64, 1, 1)]
void patch_sims(
    uint3 tid: SV_DispatchThreadID,
    uniform StructuredBuffer<float> ref_spec,
    uniform StructuredBuffer<float> deg_spec,
    uniform StructuredBuffer<uint> rows,
    uniform StructuredBuffer<uint> out_base,
    uniform StructuredBuffer<float> mu_ref,
    uniform StructuredBuffer<float> srs_ref,
    uniform RWStructuredBuffer<float> out,
    uniform uint num_rows,
    uniform uint num_tasks,
    uniform uint num_bands,
    uniform uint patch_size)
{
    uint t = zimt_index(tid);
    if (t >= num_tasks) return;

    uint lo_r = 0, hi_r = num_rows - 1;
    while (lo_r < hi_r) {
        uint mid = (lo_r + hi_r + 1) / 2;
        if (rows[mid * 8 + 0] <= t) lo_r = mid; else hi_r = mid - 1;
    }
    uint row = lo_r;
    uint k = t - rows[row * 8 + 0];
    uint off = rows[row * 8 + 2] + k;
    uint ref_base = rows[row * 8 + 3];
    uint nf_ref = rows[row * 8 + 4];
    uint ref_col = rows[row * 8 + 5];
    uint deg_base = rows[row * 8 + 6];
    uint nf_deg = rows[row * 8 + 7];

    int nb = int(num_bands);
    int ps = int(patch_size);
    uint cells = num_bands * patch_size;
    float total = 0;
    for (int r = 0; r < nb; r++) {
        float band_sum = 0;
        for (int c = 0; c < ps; c++) {
            float md = 0, dsq = 0, rd = 0;
            for (int dr = -1; dr <= 1; dr++) {
                int rr = clamp(r + dr, 0, nb - 1);
                for (int dc = -1; dc <= 1; dc++) {
                    int cc = clamp(c + dc, 0, ps - 1);
                    float w = wgt(dr, dc);
                    float d = degAt(deg_spec, deg_base, nf_deg, rr, int(off) + cc);
                    float rv = ref_spec[ref_base + uint(rr) * nf_ref + ref_col + uint(cc)];
                    md += w * d;
                    dsq += w * (d * d);
                    rd += w * (rv * d);
                }
            }
            uint ci = row * cells + uint(r) * patch_size + uint(c);
            float mr = mu_ref[ci];
            float srs = srs_ref[ci];
            float dms = md * md;
            float mrd = mr * md;
            float rms = mr * mr;
            float sds = dsq - dms;
            float srd = rd - mrd;
            float intensity = (2.0 * mrd + C1) / (rms + dms + C1);
            float prod = srs * sds;
            float denom = prod < 0.0 ? C3 : sqrt(prod) + C3;
            band_sum += intensity * ((srd + C3) / denom);
        }
        total += band_sum;
    }
    out[out_base[row] + off] = total / float(cells);
}
