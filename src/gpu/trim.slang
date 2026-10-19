// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// `realign.trimGeometry` of a realignment row at `lag`.
module trim;

import tables;
import zimt;

public struct Trim
{
    // Applied (0 past half the reference); the trimmed ref starts at
    // `head`, the deg at `head - lag`, both `len` long.
    public int lag;
    public int head;
    public int len;

    public uint frames(uint window_size, uint hop_size)
    {
        return len < int(window_size) ? 0 : 1 + (uint(len) - window_size) / hop_size;
    }
}

// back: bit k set where lag k > 0 comes back from seconds as k - 1.
public Trim trim(LagRow row, int lag, RO<uint> back)
{
    int r = int(row.a.total());
    int d = int(row.b.total());
    if (lag == 0 || abs(lag) > r / 2) lag = 0;
    int dl = lag < 0 ? d - min(-lag, d) : d + lag;
    Trim t = { lag, 0, r };
    if (r > dl) {
        t.len = dl;
    } else if (r < dl && lag > 0) {
        t.head = lag - int((back[lag / 32] >> (lag % 32)) & 1);
        if (t.head > 0) t.len = r - t.head; else t.head = 0;
    }
    return t;
}
