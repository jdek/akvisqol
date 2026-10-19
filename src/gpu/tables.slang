// SPDX-FileCopyrightText: 2026 J. Dekker <jdek@itanimul.li>
// SPDX-License-Identifier: Apache-2.0

// Index tables the host fills; zimt-bindgen generates their Zig structs.
module tables;

// A signal view: sample i is 0 below `pad`, else signals[start + i - pad],
// for i < pad + len (`realign.SliceLayout` without the copy).
public struct Side
{
    public uint start;
    public uint pad;
    public uint len;

    public uint total() { return pad + len; }
}

// One lag search between the envelopes of `a` and `b`, and for a realigned
// patch where its spectrograms go: frame slots `first_slot ..+ slots`, ref
// then deg, each (bands, frames) at first_slot · 2 · bands. Per side, the
// slice's start in its full signal, the frames of that signal's spectrogram
// (0: none) and the spectrogram's offset in `raw`: frames on that grid are
// copied (`realign.RawSpectrograms.reuse`).
public struct LagRow
{
    public Side a;
    public Side b;
    public uint first_slot;
    public uint slots;
    public uint a_base;
    public uint b_base;
    public uint a_grid;
    public uint b_grid;
    public uint a_raw;
    public uint b_raw;
}

// The lag search's largest lag and its f32 error bound (`xcorr.refineSlack`).
public struct LagParams
{
    public uint max_lag;
    public float slack;
}

// A spectrogram frame: its first sample, and where band 0 of it goes with
// bands `stride` apart.
public struct Frame
{
    public uint start;
    public uint out;
    public uint stride;
}

// A ref and a deg spectrogram, each (bands, frames) at its offset.
public struct SpecPair
{
    public uint ref_off;
    public uint ref_frames;
    public uint deg_off;
    public uint deg_frames;
}

// Ref frames `ref_frame ..+ patch` against deg frames `deg_frame ..+ cols`,
// deg frames past `deg_frames` reading zero.
public struct PatchPair
{
    public uint ref_off;
    public uint ref_frames;
    public uint ref_frame;
    public uint deg_off;
    public uint deg_frames;
    public uint deg_frame;
    public uint cols;
}

// A DP row: the ref patch at `ref_frame` against deg offsets [lo, hi],
// similarities at sims[row + offset]; its pair's `DegPlane` at `plane`,
// `width` frames.
public struct PatchSearch
{
    public uint ref_off;
    public uint ref_frames;
    public uint ref_frame;
    public uint deg_off;
    public uint deg_frames;
    public uint lo;
    public uint hi;
    public uint row;
    public uint plane;
    public uint width;
}

// A deg spectrogram's NSIM terms per cell (`nsim.DegPlane`), `width`
// frames (zero past `deg_frames`) at `plane`.
public struct DegPlane
{
    public uint deg_off;
    public uint deg_frames;
    public uint plane;
    public uint width;
}

// Offsets `first ..+ TILE_THREADS` of patch search `patch`.
public struct SimTask
{
    public uint patch;
    public uint first;
}

// The hybrid path's NSIM tasks: ref patch at `ref_frame` of a spectrogram
// at `ref_off` with `ref_frames` frames.
public struct RefPatch
{
    public uint ref_off;
    public uint ref_frames;
    public uint ref_frame;
}

// `count` offsets from `lo` of a ref patch against a deg spectrogram, their
// results from `task`.
public struct SimRow
{
    public uint task;
    public uint count;
    public uint lo;
    public RefPatch ref;
    public uint deg_off;
    public uint deg_frames;
}

// The DP of one pair: `patches` searches from `first`, deg spectrogram of
// `deg_frames`, DP and backtrace rows `deg_frames` wide from `table`.
public struct DpPair
{
    public uint first;
    public uint patches;
    public uint deg_frames;
    public uint table;
}

// Where the DP backtrack matched a ref patch: `visited` unless it stopped
// before (the CPU's defaults then stand), `valid` unless it pointed at itself.
public struct Match
{
    public uint deg_frame;
    public uint visited;
    public uint valid;
}

// A pair's ref and deg signals.
public struct PairSignals
{
    public uint ref_off;
    public uint ref_len;
    public uint deg_off;
    public uint deg_len;
}

// `realign.applyLag` of a deg signal: `zeros` zeros, then deg from `skip`,
// `len` samples in all at `out_off`.
public struct Alignment
{
    public uint deg_off;
    public uint skip;
    public uint zeros;
    public uint out_off;
    public uint len;
}

// A realignment row's patch, the aligned deg signal its slice is cut from
// (at `deg_off`), and that signal's `realign.sliceLayout` per DP offset
// (`Side`s, `start` relative to `deg_off`) from `slices`.
public struct RealignPatch
{
    public uint patch;
    public uint deg_off;
    public uint slices;
}

// A realigned patch: its lag, the length of its deg slice, and whether its
// rescore replaced the match.
public struct Realigned
{
    public int lag;
    public uint deg_total;
    public uint accepted;
}

// A degraded frame in the gammatone backward: its first sample in the
// signals (outside [lo, hi) read zero), its cells' gradients (band 0 at
// `grad`, bands `stride` apart), and where its window of sample gradients
// goes.
public struct FrameGrad
{
    public int start;
    public uint lo;
    public uint hi;
    public uint grad;
    public uint stride;
    public uint out;
}

// Frames `count` long, hop apart from `start`, their sample gradients a
// window apart from `out`.
public struct FrameRun
{
    public int start;
    public uint count;
    public uint out;
}

// A pair's aligned deg, signals [start, start + len): its gradient at
// `out`, gathered from runs `first_run ..+ runs`.
public struct SignalGrad
{
    public uint start;
    public uint len;
    public uint first_run;
    public uint runs;
    public uint out;
}

// A prepared spectrogram (bands, frames at `off`) gathering the patch
// gradients of rows `first ..+ count` on `side` (0: ref, 1: deg).
public struct SpecGather
{
    public uint off;
    public uint frames;
    public uint side;
    public uint first;
    public uint count;
}
