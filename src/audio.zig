// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

//! WAV loader to mono f64, matching upstream `MiscAudio::LoadAsMono` for 16-bit
//! PCM (/32768, channel mean). Upstream reads every format as raw i16; other
//! PCM and float formats are decoded properly to the same full scale here.
const std = @import("std");

pub const Error = error{
    EmptyAudio,
    ChannelCountZero,
    NotRiffWave,
    MissingFmtChunk,
    MissingDataChunk,
    UnsupportedFormat,
    TruncatedFile,
};

/// Mono f64 audio + sample rate. Caller owns `samples`.
pub const Audio = struct {
    samples: []f64,
    sample_rate: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Audio) void {
        self.allocator.free(self.samples);
    }

    pub fn duration(self: Audio) f64 {
        return @as(f64, @floatFromInt(self.samples.len)) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// SPL reference pressure (Pa).
pub const SPL_REFERENCE_POINT: f64 = 0.00002;

const FORMAT_PCM: u16 = 1;
const FORMAT_FLOAT: u16 = 3;
const FORMAT_EXTENSIBLE: u16 = 0xFFFE;

pub fn loadAsMono(allocator: std.mem.Allocator, path: []const u8) !Audio {
    const io = std.Options.debug_io;
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 32));
    defer allocator.free(data);
    return decodeWavAsMono(allocator, data);
}

pub fn decodeWavAsMono(allocator: std.mem.Allocator, data: []const u8) !Audio {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE"))
        return Error.NotRiffWave;

    var format_tag: u16 = 0;
    var num_channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits: u16 = 0;
    var have_fmt = false;
    var pcm: ?[]const u8 = null;

    var off: usize = 12;
    while (off + 8 <= data.len) {
        const id = data[off .. off + 4];
        const size: usize = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
        const body_start = off + 8;
        // Clamp oversized chunks (streamed WAVs write 0xFFFFFFFF), as upstream does.
        const body_end = @min(data.len, body_start + size);
        const body = data[body_start..body_end];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return Error.UnsupportedFormat;
            format_tag = std.mem.readInt(u16, body[0..2], .little);
            num_channels = std.mem.readInt(u16, body[2..4], .little);
            sample_rate = std.mem.readInt(u32, body[4..8], .little);
            bits = std.mem.readInt(u16, body[14..16], .little);
            if (format_tag == FORMAT_EXTENSIBLE and body.len >= 26) {
                // SubFormat GUID's first two bytes carry the real tag.
                format_tag = std.mem.readInt(u16, body[24..26], .little);
            }
            have_fmt = true;
        } else if (std.mem.eql(u8, id, "data")) {
            pcm = body;
            break;
        }
        off = body_start + size + (size & 1);
    }
    if (!have_fmt) return Error.MissingFmtChunk;
    const raw = pcm orelse return Error.MissingDataChunk;
    if (num_channels == 0) return Error.ChannelCountZero;

    const bytes_per_sample: usize = bits / 8;
    const valid = switch (format_tag) {
        FORMAT_PCM => bits == 8 or bits == 16 or bits == 24 or bits == 32,
        FORMAT_FLOAT => bits == 32 or bits == 64,
        else => false,
    };
    if (!valid) return Error.UnsupportedFormat;

    const nch: usize = num_channels;
    const frames = raw.len / (bytes_per_sample * nch);
    if (frames == 0) return Error.EmptyAudio;

    const out = try allocator.alloc(f64, frames);
    errdefer allocator.free(out);

    for (out, 0..) |*o, f| {
        var sum: f64 = 0.0;
        for (0..nch) |c| {
            const p = raw[(f * nch + c) * bytes_per_sample ..];
            sum += decodeSample(format_tag, bits, p);
        }
        // sum/n to match upstream AMatrix::Mean.
        o.* = if (nch == 1) sum else sum / @as(f64, @floatFromInt(nch));
    }
    return .{ .samples = out, .sample_rate = sample_rate, .allocator = allocator };
}

inline fn decodeSample(format_tag: u16, bits: u16, p: []const u8) f64 {
    if (format_tag == FORMAT_FLOAT) {
        return if (bits == 32)
            @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, p[0..4], .little))))
        else
            @bitCast(std.mem.readInt(u64, p[0..8], .little));
    }
    return switch (bits) {
        8 => (@as(f64, @floatFromInt(p[0])) - 128.0) / 128.0,
        16 => @as(f64, @floatFromInt(std.mem.readInt(i16, p[0..2], .little))) / 32768.0,
        24 => @as(f64, @floatFromInt(std.mem.readInt(i24, p[0..3], .little))) / 8388608.0,
        32 => @as(f64, @floatFromInt(std.mem.readInt(i32, p[0..4], .little))) / 2147483648.0,
        else => unreachable,
    };
}

/// SPL in dB: 20 * log10(rms / SPL_REFERENCE_POINT).
pub fn soundPressureLevel(samples: []const f64) f64 {
    var energy: f64 = 0.0;
    for (samples) |x| energy += x * x;
    return splOfEnergy(energy, samples.len);
}

/// `soundPressureLevel` of `len` samples whose squares sum to `energy`.
pub fn splOfEnergy(energy: f64, len: usize) f64 {
    if (len == 0) return -std.math.inf(f64);
    const rms = @sqrt(energy / @as(f64, @floatFromInt(len)));
    return 20.0 * std.math.log10(rms / SPL_REFERENCE_POINT);
}

/// `scaleToMatchSpl`'s factor (1: left as is).
pub fn splFactor(ref_spl: f64, deg_spl: f64) f64 {
    if (!std.math.isFinite(ref_spl) or !std.math.isFinite(deg_spl)) return 1.0;
    return std.math.pow(f64, 10.0, (ref_spl - deg_spl) / 20.0);
}

/// Scale `degraded` in place so its SPL matches `reference`.
pub fn scaleToMatchSpl(reference: []const f64, degraded: []f64) void {
    const ref_spl = soundPressureLevel(reference);
    const deg_spl = soundPressureLevel(degraded);
    if (!std.math.isFinite(ref_spl) or !std.math.isFinite(deg_spl)) return;
    const factor = std.math.pow(f64, 10.0, (ref_spl - deg_spl) / 20.0);
    for (degraded) |*x| x.* *= factor;
}

fn testWav(buf: []u8, fmt: u16, bits: u16, nch: u16, payload: []const u8) []u8 {
    const out = buf[0 .. 44 + payload.len];
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], @intCast(36 + payload.len), .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], fmt, .little);
    std.mem.writeInt(u16, out[22..24], nch, .little);
    std.mem.writeInt(u32, out[24..28], 48000, .little);
    std.mem.writeInt(u32, out[28..32], 48000 * @as(u32, nch) * bits / 8, .little);
    std.mem.writeInt(u16, out[32..34], nch * bits / 8, .little);
    std.mem.writeInt(u16, out[34..36], bits, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], @intCast(payload.len), .little);
    @memcpy(out[44..], payload);
    return out;
}

test "decodeWavAsMono: 16-bit stereo averages channels, /32768" {
    const payload = [_]u8{ 0x00, 0x40, 0x00, 0xC0, 0xFF, 0x7F, 0xFF, 0x7F };
    var buf: [64]u8 = undefined;
    const wav = testWav(&buf, FORMAT_PCM, 16, 2, &payload);
    var a = try decodeWavAsMono(std.testing.allocator, wav);
    defer a.deinit();
    try std.testing.expectEqual(@as(usize, 2), a.samples.len);
    try std.testing.expectEqual(@as(f64, 0.0), a.samples[0]);
    try std.testing.expectEqual(@as(f64, 32767.0 / 32768.0), a.samples[1]);
    try std.testing.expectEqual(@as(u32, 48000), a.sample_rate);
}

test "decodeWavAsMono: float32 mono" {
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], @bitCast(@as(f32, 0.5)), .little);
    std.mem.writeInt(u32, payload[4..8], @bitCast(@as(f32, -0.25)), .little);
    var buf: [64]u8 = undefined;
    const wav = testWav(&buf, FORMAT_FLOAT, 32, 1, &payload);
    var a = try decodeWavAsMono(std.testing.allocator, wav);
    defer a.deinit();
    try std.testing.expectEqualSlices(f64, &.{ 0.5, -0.25 }, a.samples);
}

test "soundPressureLevel: unit dc has known SPL" {
    const ones: [16]f64 = @splat(1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 93.9794), soundPressureLevel(&ones), 1e-3);
}

test "scaleToMatchSpl: half-amplitude degraded scales up to match" {
    var ref = [_]f64{ 0.5, -0.5, 0.5, -0.5, 0.5, -0.5, 0.5, -0.5 };
    var deg = [_]f64{ 0.25, -0.25, 0.25, -0.25, 0.25, -0.25, 0.25, -0.25 };
    scaleToMatchSpl(&ref, &deg);
    try std.testing.expectApproxEqAbs(soundPressureLevel(&ref), soundPressureLevel(&deg), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), deg[0], 1e-9);
}
