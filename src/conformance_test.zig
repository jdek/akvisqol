// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! Upstream `src/conformance_test.cc` (conformance number 333). Needs
//! `tests/fetch_data.sh`; cases with missing audio are skipped.
const std = @import("std");
const visqol = @import("visqol.zig");
const svr = @import("svr.zig");
const lattice = @import("lattice.zig");

/// Upstream `kTolerance`.
const TOLERANCE = 0.0001;

const Case = struct {
    name: []const u8,
    ref: []const u8,
    deg: []const u8,
    speech: bool = false,
    unscaled: bool = false,
    lattice: bool = false,
    expected: f64,
};

const cs = "tests/data/clean_speech/";
const sub = "tests/data/conformance_testdata_subset/";

pub const cases = [_]Case{
    .{ .name = "SpeechCA01TranscodedLattice", .ref = cs ++ "CA01_01.wav", .deg = cs ++ "transcoded_CA01_01.wav", .speech = true, .lattice = true, .expected = 3.3129234313964844 },
    .{ .name = "CA01PerfectScoreLattice", .ref = cs ++ "CA01_01.wav", .deg = cs ++ "CA01_01.wav", .speech = true, .lattice = true, .expected = 4.505550384521484 },
    .{ .name = "DifferentAudiosLattice", .ref = sub ++ "guitar48_stereo.wav", .deg = cs ++ "CA01_01.wav", .speech = true, .lattice = true, .expected = 1.4982070922851562 },
    .{ .name = "BadDegradedLattice", .ref = "tests/data/alignment/reference.wav", .deg = "tests/data/alignment/degraded.wav", .speech = true, .lattice = true, .expected = 1.19293212890625 },
    .{ .name = "SpeechCA01TranscodedExponential", .ref = cs ++ "CA01_01.wav", .deg = cs ++ "transcoded_CA01_01.wav", .speech = true, .expected = 3.374505555111911 },
    .{ .name = "UnscaledPerfectScoreExponential", .ref = cs ++ "CA01_01.wav", .deg = cs ++ "CA01_01.wav", .speech = true, .unscaled = true, .expected = 4.015861169223797 },
    .{ .name = "StraussLp35", .ref = sub ++ "strauss48_stereo.wav", .deg = sub ++ "strauss48_stereo_lp35.wav", .expected = 1.3888791489130758 },
    .{ .name = "SteelyLp7", .ref = sub ++ "steely48_stereo.wav", .deg = sub ++ "steely48_stereo_lp7.wav", .expected = 2.2501683734385183 },
    .{ .name = "Sopr256aac", .ref = sub ++ "sopr48_stereo.wav", .deg = sub ++ "sopr48_stereo_256kbps_aac.wav", .expected = 4.68228969737946 },
    .{ .name = "Ravel128opus", .ref = sub ++ "ravel48_stereo.wav", .deg = sub ++ "ravel48_stereo_128kbps_opus.wav", .expected = 4.465141897255348 },
    .{ .name = "Moonlight128aac", .ref = sub ++ "moonlight48_stereo.wav", .deg = sub ++ "moonlight48_stereo_128kbps_aac.wav", .expected = 4.684292801646114 },
    .{ .name = "Harpsichord96mp3", .ref = sub ++ "harpsichord48_stereo.wav", .deg = sub ++ "harpsichord48_stereo_96kbps_mp3.wav", .expected = 4.22374532766003 },
    .{ .name = "Guitar64aac", .ref = sub ++ "guitar48_stereo.wav", .deg = sub ++ "guitar48_stereo_64kbps_aac.wav", .expected = 4.349722308064298 },
    .{ .name = "Glock48aac", .ref = sub ++ "glock48_stereo.wav", .deg = sub ++ "glock48_stereo_48kbps_aac.wav", .expected = 4.332452943882108 },
    .{ .name = "Contrabassoon24aac", .ref = sub ++ "contrabassoon48_stereo.wav", .deg = sub ++ "contrabassoon48_stereo_24kbps_aac.wav", .expected = 2.346868205375293 },
    .{ .name = "CastanetsIdentity", .ref = sub ++ "castanets48_stereo.wav", .deg = sub ++ "castanets48_stereo.wav", .expected = 4.732101253042348 },
    .{ .name = "GuitarShortDegradedPatch", .ref = sub ++ "guitar48_stereo.wav", .deg = "tests/data/short_duration/5_second/guitar48_stereo_5_sec.wav", .expected = 4.314508583690198 },
    .{ .name = "GuitarShortReferencePatch", .ref = "tests/data/short_duration/5_second/guitar48_stereo_5_sec.wav", .deg = sub ++ "guitar48_stereo.wav", .expected = 4.550791119387646 },
    .{ .name = "DifferentAudiosExponential", .ref = sub ++ "guitar48_stereo.wav", .deg = cs ++ "CA01_01.wav", .speech = true, .expected = 1.269675546824064 },
    .{ .name = "BadDegradedExponential", .ref = "tests/data/alignment/reference.wav", .deg = "tests/data/alignment/degraded.wav", .speech = true, .expected = 1.357521678867611 },
};

fn exists(path: []const u8) bool {
    const io = std.Options.debug_io;
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

test "conformance (google/visqol v333)" {
    const allocator = std.testing.allocator;
    var ran: usize = 0;
    var failed: usize = 0;
    for (cases) |c| {
        if (!exists(c.ref) or !exists(c.deg)) continue;
        const models = @import("default_model");
        const mapper: ?visqol.QualityMapper = if (!c.speech)
            .{ .svr = try svr.parseModel(allocator, models.svr) }
        else if (c.lattice)
            .{ .lattice = try lattice.Mapper.init(allocator, models.lattice, visqol.constants.NUM_BANDS_SPEECH) }
        else
            null;
        var v = try visqol.Visqol.init(allocator, .{
            .mode = if (c.speech) .speech else .audio,
            .use_unscaled_speech_mos_mapping = c.unscaled,
            .use_lattice_model = c.lattice,
        }, mapper);
        defer v.deinit();
        var r = try v.measureFiles(c.ref, c.deg);
        defer r.deinit();
        ran += 1;
        const err = @abs(r.moslqo - c.expected);
        if (err > TOLERANCE) {
            failed += 1;
            std.debug.print("FAIL {s}: got {d:.12} expected {d:.12} (|Δ|={e})\n", .{ c.name, r.moslqo, c.expected, err });
        }
    }
    if (ran == 0) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 0), failed);
}
