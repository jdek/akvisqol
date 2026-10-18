// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0


module zimt;

// Rows of a folded 1-D dispatch: Vulkan only guarantees 65535 groups per
// dimension, and Slang has no portable group count.
// Must match `zimt.row_groups`.
public static const uint ZIMT_ROW_GROUPS = 32768;

// Threads past the requested count exist; bounds-check the result.
public uint zimt_index(uint3 tid)
{
    return tid.x + tid.y * (ZIMT_ROW_GROUPS * WorkgroupSize().x);
}
