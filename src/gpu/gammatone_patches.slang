// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Spectrograms of realigned patches, trimmed on the device from each row's
// lag as `realign.trimGeometry` does: one thread per (frame slot, side, band),
// for slots `first_slot ..`.
//
// rows: as envelope.slang, with where each row's spectrograms go (`LagRow`).
// slots: the row of each frame slot.
// back: bit k set where lag k > 0 comes back from seconds as k - 1.
// Rows with a nonzero status are the host's.
import df;
import gammatone_common;
import tables;
import trim;
import zimt;

// `signals`, with the lo parts in BALANCED.
struct Signals
{
    RO<real> hi;
#if BALANCED
    RO<real> lo;
#endif

    Sample at(uint i)
    {
#if BALANCED
        return DF(hi[i], lo[i]);
#else
        return hi[i];
#endif
    }
}

Sample at(Side s, Signals signals, int i)
{
    if (i < int(s.pad) || i >= int(s.total())) return Sample(real(0));
    return signals.at(s.start + uint(i) - s.pad);
}

// A frame entirely inside the slice's samples.
struct Inside : IFrame
{
    Signals signals;
    uint start;

    Sample at(uint i) { return signals.at(start + i); }
}

struct Windowed : IFrame
{
    Signals signals;
    Side side;
    int start;

    Sample at(uint i) { return ::at(side, signals, start + int(i)); }
}

[shader("compute")]
[numthreads(64, 1, 1)]
void gammatone_patches(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> signals,
#if BALANCED
    uniform RO<real> signals_lo,
#endif
    uniform RO<LagRow> rows,
    uniform RO<uint> slots,
    uniform RO<int> lags,
    uniform RO<uint> status,
    uniform RO<uint> back,
    uniform RO<real> coeffs,
    uniform RO<real> hann,
    uniform RO<real> raw,
    uniform RW<real> out,
    uniform uint copy_raw,
    uniform uint first_slot,
    uniform uint total,
    uniform uint num_bands,
    uniform uint window_size,
    uniform uint hop_size)
{
    uint gid = zimt_index(tid);
    if (gid >= total) return;
    uint band = gid % num_bands;
    bool ref = (gid / num_bands) % 2 == 0;
    uint slot = first_slot + gid / num_bands / 2;
    uint row = slots[slot];
    if (status[row] != 0) return;
    LagRow r = rows[row];
    Side a = r.a;
    Side b = r.b;

    Trim t = trim(r, lags[row], back);
    uint frames = t.frames(window_size, hop_size);
    if (frames == 0) return;
    int head = t.head;
    int lag = t.lag;
    uint f = slot - r.first_slot;
    if (f >= frames) return;

    // RawSpectrograms.reuse
    int off = ref ? head : head - lag;
    Side s = ref ? a : b;
    uint base = r.first_slot * 2 * num_bands + (ref ? 0 : num_bands * r.slots);
    uint grid = ref ? r.a_grid : r.b_grid;
    if (grid > 0 && off >= int(s.pad)) {
        uint start = (ref ? r.a_base : r.b_base) + uint(off) - s.pad;
        if (start % hop_size == 0 && start / hop_size + frames <= grid) {
            if (copy_raw != 0) out[base + band * frames + f] = raw[(ref ? r.a_raw : r.b_raw) + band * grid + start / hop_size + f];
            return;
        }
    }

    int first = off + int(f * hop_size);
#if BALANCED
    Signals sig = { signals, signals_lo };
#else
    Signals sig = { signals };
#endif
    real rms;
    if (first >= int(s.pad) && first + int(window_size) <= int(s.total())) {
        Inside fr = { sig, s.start + uint(first) - s.pad };
        rms = gammatone_rms(fr, band, coeffs, hann, window_size);
    } else {
        Windowed fr = { sig, s, first };
        rms = gammatone_rms(fr, band, coeffs, hann, window_size);
    }
    out[base + band * frames + f] = rms;
}
