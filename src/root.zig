// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Zig implementation of Google's ViSQOL.
pub const visqol = @import("visqol.zig");
pub const audio = @import("audio.zig");
pub const svr = @import("svr.zig");
pub const lattice = @import("lattice.zig");
pub const tflite = @import("tflite.zig");

test {
    _ = @import("audio.zig");
    _ = @import("dp.zig");
    _ = @import("envelope.zig");
    _ = @import("gammatone.zig");
    _ = @import("lattice.zig");
    _ = @import("nsim.zig");
    _ = @import("realign.zig");
    _ = @import("spectrogram.zig");
    _ = @import("svr.zig");
    _ = @import("tflite.zig");
    _ = @import("visqol.zig");
    _ = @import("vad.zig");
    _ = @import("xcorr.zig");
    _ = @import("dsp/fft.zig");
    _ = @import("dsp/erb.zig");
    _ = @import("conformance_test.zig");
}
