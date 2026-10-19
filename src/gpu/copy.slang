// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// dst[dst_off ..+ n] = src[src_off ..+ n], between buffers on one device.
import zimt;

typealias real = REAL;

[shader("compute")]
[numthreads(256, 1, 1)]
void copy(
    uint3 tid: SV_DispatchThreadID,
    uniform RO<real> src,
    uniform RW<real> dst,
    uniform uint src_off,
    uniform uint dst_off,
    uniform uint n)
{
    uint i = zimt_index(tid);
    if (i < n) dst[dst_off + i] = src[src_off + i];
}
