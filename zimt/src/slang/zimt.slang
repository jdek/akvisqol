// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0


module zimt;

// Kernel buffer parameters: device addresses, read-only or read-write
// (bindgen records which, for Vulkan barriers and Metal resource usage). Atomics take `.p[i]`.
public struct RO<T>
{
    public T* p;
    public __subscript(uint i) -> T { get { return p[i]; } }
}

public struct RW<T>
{
    public T* p;
    public __subscript(uint i) -> T
    {
        get { return p[i]; }
        set { p[i] = newValue; }
    }
}

// Rows of a folded 1-D dispatch: Vulkan only guarantees 65535 groups per
// dimension, and Slang has no portable group count.
// Must match `zimt.row_groups`.
public static const uint ZIMT_ROW_GROUPS = 32768;

// Threads past the requested count exist; bounds-check the result.
public uint zimt_index(uint3 tid)
{
    return tid.x + tid.y * (ZIMT_ROW_GROUPS * WorkgroupSize().x);
}

// Groups covering n threads of `threads_x` each, folded as `dispatch1d`
// folds them: what a kernel writes for `dispatchIndirect1d`.
public uint3 zimt_groups(uint n, uint threads_x)
{
    uint g = (n + threads_x - 1) / threads_x;
    if (g <= ZIMT_ROW_GROUPS) return uint3(g, 1, 1);
    return uint3(ZIMT_ROW_GROUPS, (g + ZIMT_ROW_GROUPS - 1) / ZIMT_ROW_GROUPS, 1);
}
