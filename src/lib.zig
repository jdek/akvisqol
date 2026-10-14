// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Root of `libvisqol`: the Zig API plus the C ABI from `capi.zig`.
pub const visqol = @import("root.zig");
pub const backend = @import("backend.zig");

comptime {
    _ = @import("capi.zig");
}

test {
    _ = @import("root.zig");
    _ = @import("capi.zig");
    _ = @import("backend.zig");
}
