//! The stream session: the frames of a video come one time, in order, and the pages
//! of the document come out while the video runs.
//!
//! This is the flow for a phone. A camera gives each frame one time. A decoder on a
//! phone is fast only when it runs one time through the file. So the session cannot
//! go back to a frame: it keeps a copy of the few full-size frames that a spread
//! can need, and drops each other frame.
//!
//! The steps for each frame:
//!
//! 1. The analysis: a small copy of the frame, and the observation of that copy.
//! 2. The timeline: `timeline.Tracker` says when a spread starts, ends, and is final.
//!    Before it joins two runs of stable frames to one spread, the session compares
//!    the small pictures of the two runs (decision 0032).
//! 3. The frames of a spread: while a spread is in view, the session makes the choice
//!    of `timeline.chooseReference` and `timeline.selectDonors` again and again,
//!    among the frames that it still holds, and drops the frames that the choice
//!    does not take.
//! 4. A spread that is final gets a small picture for the duplicate search. A spread
//!    that stays becomes a `Job` with its frames.
//!
//! The caller runs each job on a thread of its own choice and gives it back. The
//! pages of the job then have their place in the document.
//!
//! Threads: one thread at a time calls the functions of a `Stream`. `Job.run` works
//! on the job only, so it can run on another thread at the same time. See
//! `docs/decisions/0019-stream-session-for-a-phone.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const image = @import("image.zig");
const intake = @import("intake.zig");
const detect = @import("detect.zig");
const observe = @import("observe.zig");
const timeline = @import("timeline.zig");
const document = @import("document.zig");
const dedup = @import("dedup.zig");
const render = @import("render.zig");
const jpeg = @import("jpeg.zig");
const pdf = @import("pdf.zig");
const fuse = @import("fuse.zig");

const FrameObservation = observe.FrameObservation;
const Quad = geometry.Quad;

// region: options and results

pub const Options = struct {
    /// The size of the frames that the source gives, before the rotation.
    source_size: image.Size,
    /// The turn that brings a frame of the source to the upright view.
    rotation: intake.Rotation = .none,
    colorimetry: image.Colorimetry = .{},
    /// The frame rate of the source. Zero: the session measures it from the times
    /// of the frames.
    frames_per_second: f32 = 0,
    /// The short side of the small frame for the analysis, in pixels. The small
    /// frame has this size or a little more: the factor is a whole number.
    analysis_short_side: u32 = 540,
    timeline: timeline.Options = .{},
    reference: timeline.ReferenceOptions = .{},
    /// The donor frames of a spread. `count` and `cut_count` are for one spread:
    /// two pages with different reference frames share them. A full-size frame of
    /// 3840 x 2160 pixels is 12 MB, so a phone takes fewer donors than the
    /// command-line program.
    donor: timeline.DonorOptions = .{ .count = 4, .cut_count = 2 },
    geometry: document.GeometryOptions = .{},
    dedup: dedup.Options = .{},
    render: render.Options = .{},
    /// The page size of the document is final when this many spreads are known, or
    /// at the end of the video. All pages of a document have one size, and the
    /// first spreads wait for it.
    geometry_spreads: u8 = 2,
    /// The session makes its choice of frames again after this many new frames of
    /// a spread. A smaller value holds fewer frames for a short time and uses more
    /// CPU time.
    batch_frames: u8 = 8,
    /// Donor frames can also come from this much time after the stable time of a
    /// spread. In that time the hand is at another place and the glare too.
    donor_margin_seconds: f32 = 1.2,
    /// The limit for the number of full-size frames in the session and its jobs.
    /// At the limit, the session makes its choice of frames after each two new
    /// frames, and a spread gets fewer donor frames, down to none. The frames that
    /// each spread needs with no donor frames stay: the first choice of the
    /// timeline, the reference frames, and the last frames. So the number can be a
    /// little above the limit for a short time. Zero: no limit.
    max_held_frames: u32 = 0,
};

/// How much the part of a page outside the frame, and each page side that the frame
/// cuts, lower the quality of a spread in the duplicate search.
const outside_quality_weight = 2.0;
const clipped_quality_weight = 0.5;
/// A spread has at most this many views: runs of stable frames that joined.
const max_views = 8;
/// The frame rate before the session has measured one.
const default_frames_per_second = timeline.Options.reference_frame_rate;
/// The session measures the frame rate when it has this many frames.
const min_rate_frames = 8;
/// The limits of the frame rate, from the options or from the times of the frames.
/// A frame time in a wrong unit must not give a frame count that fits no integer.
const min_frames_per_second = 1.0;
const max_frames_per_second = 1000.0;
/// The observations of old frames go when this many can go.
const trim_step_frames = 256;
/// The session keeps at most this many frame buffers for the next frames.
const max_spare_buffers = 4;
/// At the limit of the frames in memory, a choice of frames comes after this many
/// new frames of a spread. Each choice takes some milliseconds.
const min_batch_frames = 2;

pub const Error = Allocator.Error || jpeg.Error || error{
    /// A frame has another size than `Options.source_size`, or its planes are too short.
    InvalidFrame,
    /// A frame came after `finish`.
    StreamEnded,
};

/// What the session knows after a frame. A camera app draws the page corners on
/// the preview and tells the user when to turn the page.
pub const Status = struct {
    /// True when the frame shows a page.
    detected: bool = false,
    page_count: u8 = 0,
    /// The corners of each page, in luma pixels of the upright full-size frame.
    quads: [detect.max_pages]Quad = @splat(Quad.rect(0, 0)),
    /// True when the pages stay at one place: a spread is in view.
    steady: bool = false,
    /// True when the view is long enough for a spread and this frame shows the page
    /// well: the user can turn the page.
    captured: bool = false,
    /// The spreads of the document so far. The last one can still change: the next
    /// view can show it again.
    spreads: u32 = 0,
    /// The pages that are complete.
    pages: u32 = 0,
    /// The jobs that wait for `takeJob`.
    jobs_ready: u32 = 0,
    /// The full-size frames in the session and its jobs.
    held_frames: u32 = 0,
};

pub const Stats = struct {
    frames: u64 = 0,
    /// Frames that show a page.
    detected_frames: u64 = 0,
    /// The largest number of full-size frames in memory at one time.
    peak_held_frames: u32 = 0,
    /// The number of times the session made its choice of frames.
    selections: u64 = 0,
    /// Spreads that the timeline found.
    segments: u32 = 0,
    /// Spreads that left the document as copies of another spread.
    duplicate_spreads: u32 = 0,
    /// Spreads with no usable picture of each page for the duplicate search.
    unusable_spreads: u32 = 0,
    /// Donor frames that a job did not get because of `max_held_frames`.
    donors_dropped: u32 = 0,
    /// The number of times a choice of frames had fewer places for donor frames
    /// than the options give, because of `max_held_frames`.
    donor_limits: u32 = 0,
    /// Runs of stable frames with the thumbnails of the spread before them that
    /// stayed a spread of their own: their small pictures show different pages.
    runs_kept_apart: u32 = 0,
};

/// What the render did on one page.
pub const PageReport = struct {
    /// The frame that gives the picture of the page.
    reference: u32 = 0,
    donor_frames: u8 = 0,
    donors_used: u8 = 0,
    fusion: fuse.Stats = .{},
    outside_fraction: f32 = 0,
};

/// One page of the document.
pub const Page = struct {
    /// The spread of the page: its place in the list of all spreads of the timeline.
    spread: u32,
    /// 0 for a single page or the left page, 1 for the right page.
    index: u8,
    encoded: render.EncodedPage,
    report: PageReport,
};

// endregion: options and results

// region: frames in hand

/// A full-size frame that the session keeps, as the source gave it.
const HeldFrame = struct {
    index: u32,
    /// A packed frame of `Options.source_size`, before the rotation.
    data: []u8,
    /// The page corners of the analysis, in luma pixels of the upright full-size frame.
    quads: [detect.max_pages]Quad,
    clipped_edges: [detect.max_pages]detect.ClippedEdges,
    /// For each page, true when the page is not white paper.
    colored: [detect.max_pages]bool,
};

const max_pass_donors = 24;

/// One call of the render: a reference frame, its donor frames, and the pages to make.
const Pass = struct {
    reference: timeline.Reference,
    /// The one page to render, or null for all pages of the spread.
    only_page: ?u8,
    donors: [max_pass_donors]u32 = undefined,
    donor_count: u8 = 0,

    fn donorSlice(self: *const Pass) []const u32 {
        return self.donors[0..self.donor_count];
    }
};

const Choice = struct {
    passes: [detect.max_pages]Pass = undefined,
    pass_count: u8 = 0,
    /// The first choice of the timeline. The duplicate search takes its picture.
    fallback: u32 = 0,

    fn uses(self: *const Choice, frame: u32) bool {
        if (frame == self.fallback) return true;
        for (self.passes[0..self.pass_count]) |*pass| {
            if (pass.reference.frame == frame) return true;
            for (pass.donorSlice()) |donor| {
                if (donor == frame) return true;
            }
        }
        return false;
    }
};

/// The frames in hand for one spread that can still change.
const Gather = struct {
    kind: detect.LayoutKind,
    /// The stable time of each view of the spread.
    views: [max_views]timeline.FrameSpan = undefined,
    view_count: u8 = 0,
    /// In the order of the video.
    frames: std.ArrayList(HeldFrame) = .empty,
    /// The frames that came after the last choice.
    fresh: u32 = 0,
    choice: ?Choice = null,

    fn find(self: *const Gather, index: u32) ?*HeldFrame {
        for (self.frames.items) |*frame| {
            if (frame.index == index) return frame;
        }
        return null;
    }

    /// The frame `reference` when the gather holds it, or else the first choice of
    /// the last choice of frames.
    fn picture(self: *const Gather, reference: u32) ?*HeldFrame {
        if (self.find(reference)) |frame| return frame;
        const choice = self.choice orelse return null;
        return self.find(choice.fallback);
    }

    fn take(self: *Gather, index: u32) ?HeldFrame {
        for (self.frames.items, 0..) |frame, position| {
            if (frame.index == index) return self.frames.orderedRemove(position);
        }
        return null;
    }
};

// endregion: frames in hand

// region: spreads and jobs

const SpreadState = enum {
    /// The spread is final. It waits for the page size and the duplicate search.
    waiting,
    /// A copy of another spread, or a spread with no usable picture.
    dropped,
    /// The spread has a job.
    queued,
    /// The pages of the spread are in the document.
    done,
};

const Spread = struct {
    segment: timeline.Segment,
    state: SpreadState = .waiting,
    /// True when a better copy took the place of this spread.
    replaced: bool = false,
    gather: ?Gather = null,
    /// The observation of the reference frame, while the page size is not final.
    reference_observation: ?*FrameObservation = null,
    signature: ?render.SpreadSignature = null,
    job: ?*Job = null,
    pages: [detect.max_pages]?render.EncodedPage = @splat(null),
    reports: [detect.max_pages]PageReport = @splat(.{}),
};

const JobFrame = struct {
    held: HeldFrame,
    /// The frame in the upright view, while the job runs. Null when the source
    /// needs no rotation.
    upright: ?[]u8 = null,
};

const JobPass = struct {
    /// Positions in `Job.frames`.
    reference: u8,
    donors: [max_pass_donors]u8 = undefined,
    donor_count: u8 = 0,
    only_page: ?u8,
    reference_score: timeline.Reference,
};

/// The render of the pages of one spread. The job owns its frames, so it needs
/// nothing of the session while it runs.
pub const Job = struct {
    gpa: Allocator,
    /// The spread of the job: its place in the list of all spreads of the timeline.
    spread: u32,
    kind: detect.LayoutKind,
    page_size: image.Size,
    source_size: image.Size,
    rotation: intake.Rotation,
    colorimetry: image.Colorimetry,
    options: render.Options,
    frames: []JobFrame,
    passes: [detect.max_pages]JobPass = undefined,
    pass_count: u8 = 0,
    pages: [detect.max_pages]?render.EncodedPage = @splat(null),
    reports: [detect.max_pages]PageReport = @splat(.{}),

    /// Render and encode the pages. `scratch` gives the working memory: all of it
    /// is free again at the return. A thread that runs many jobs gives a
    /// `memory.BlockCache`. The encoded pages come from the allocator of the session.
    pub fn run(self: *Job, scratch: Allocator) Error!void {
        defer for (self.frames) |*frame| {
            if (frame.upright) |buffer| scratch.free(buffer);
            frame.upright = null;
        };
        const donor_sources = try scratch.alloc(render.SourceFrame, max_pass_donors);
        defer scratch.free(donor_sources);

        for (self.passes[0..self.pass_count]) |*pass| {
            const reference = try self.source(scratch, pass.reference);
            for (pass.donors[0..pass.donor_count], 0..) |position, donor_index| {
                donor_sources[donor_index] = try self.source(scratch, position);
            }
            const only_page: ?usize = if (pass.only_page) |page| page else null;
            const spread = try render.renderSpread(
                scratch,
                scratch,
                reference,
                donor_sources[0..pass.donor_count],
                self.kind,
                only_page,
                self.page_size,
                self.options,
            );
            defer spread.deinit(scratch);
            for (spread.pageSlice()) |*page| {
                // A page that an earlier pass made stays.
                if (self.pages[page.index] != null) continue;
                self.pages[page.index] = try render.encodePage(self.gpa, scratch, page.rgb, self.options.jpeg);
                self.reports[page.index] = .{
                    .reference = pass.reference_score.frame,
                    .donor_frames = pass.donor_count,
                    .donors_used = page.donors_used,
                    .fusion = page.fusion,
                    .outside_fraction = page.outside_fraction,
                };
            }
        }
    }

    /// The number of full-size frames of the job.
    pub fn frameCount(self: *const Job) usize {
        return self.frames.len;
    }

    /// One frame of the job as the render takes it: in the upright view.
    fn source(self: *Job, scratch: Allocator, position: u8) Allocator.Error!render.SourceFrame {
        const frame = &self.frames[position];
        const upright_size = self.rotation.apply(self.source_size);
        var data: []const u8 = frame.held.data;
        if (self.rotation != .none) {
            if (frame.upright == null) {
                const buffer = try scratch.alloc(u8, image.packedFrameSize(upright_size.width, upright_size.height));
                const as_given = image.FrameView.fromPacked(frame.held.data, self.source_size.width, self.source_size.height, self.colorimetry);
                intake.rotate(buffer, as_given, self.rotation);
                frame.upright = buffer;
            }
            data = frame.upright.?;
        }
        return .{
            .frame = image.FrameView.fromPacked(data, upright_size.width, upright_size.height, self.colorimetry),
            .quads = frame.held.quads,
            .clipped_edges = frame.held.clipped_edges,
            .colored = frame.held.colored,
        };
    }
};

/// A spread for the duplicate search. The candidate reads the pictures of
/// `signature`, which must have a picture of each page of the spread.
fn candidateOf(segment: timeline.Segment, signature: *const render.SpreadSignature) dedup.Candidate {
    var candidate: dedup.Candidate = .{
        .kind = segment.kind,
        .signatures = undefined,
        .quality = segment.score -
            outside_quality_weight * signature.outside_fraction -
            clipped_quality_weight * @as(f32, @floatFromInt(signature.clipped_edge_count)),
        .weak = segment.weak,
    };
    for (&candidate.signatures, &candidate.hidden, 0..) |*plane, *hidden, page_index| {
        const source = if (page_index < signature.page_count) page_index else 0;
        plane.* = signature.pages[source].view();
        hidden.* = signature.hidden[source].view();
    }
    return candidate;
}

// endregion: spreads and jobs

// region: stream

pub const Stream = struct {
    gpa: Allocator,
    options: Options,
    /// The size of a frame in the upright view.
    upright_size: image.Size,
    /// The factor from the full-size frame to the small frame of the analysis.
    factor: u32,
    /// The size of the small frame in the upright view.
    analysis_size: image.Size,

    /// The observations of the frames from `base` on.
    observations: std.ArrayList(FrameObservation) = .empty,
    base: usize = 0,
    frame_count: usize = 0,
    first_seconds: f64 = 0,
    last_seconds: f64 = 0,
    ended: bool = false,

    tracker: timeline.Tracker,
    /// The last frame that shows a page, when no spread took it. A run of stable
    /// frames starts one frame before the frame that shows it.
    latest: ?HeldFrame = null,
    /// The frames of the run of stable frames in view.
    current: ?Gather = null,
    /// The frames of the last spread, which can still change.
    pending: ?Gather = null,

    spreads: std.ArrayList(Spread) = .empty,
    /// The first spread that waits for the page size and the duplicate search.
    next_waiting: usize = 0,
    page_geometry: ?document.PageGeometry = null,
    resolver: dedup.Resolver,
    /// The jobs that wait for `takeJob`, the oldest first.
    ready: std.ArrayList(*Job) = .empty,
    /// The jobs that the caller has.
    jobs_out: u32 = 0,

    /// Frame buffers for the next frames.
    spare: std.ArrayList([]u8) = .empty,
    held_frames: u32 = 0,
    stats: Stats = .{},

    pub fn init(gpa: Allocator, options: Options) Stream {
        const upright_size = options.rotation.apply(options.source_size);
        const factor = intake.shrinkFactor(options.source_size, options.analysis_short_side);
        var tracker_options = options.timeline;
        tracker_options.frames_per_second = if (options.frames_per_second > 0)
            std.math.clamp(options.frames_per_second, min_frames_per_second, max_frames_per_second)
        else
            default_frames_per_second;
        return .{
            .gpa = gpa,
            .options = options,
            .upright_size = upright_size,
            .factor = factor,
            .analysis_size = options.rotation.apply(intake.shrunkSize(options.source_size, factor)),
            .tracker = .init(tracker_options),
            .resolver = .init(options.dedup),
        };
    }

    /// Free the session. The caller gives each job back with `complete` first.
    pub fn deinit(self: *Stream) void {
        std.debug.assert(self.jobs_out == 0);
        const gpa = self.gpa;
        if (self.latest) |frame| gpa.free(frame.data);
        if (self.current) |*gather| self.freeGather(gather);
        if (self.pending) |*gather| self.freeGather(gather);
        for (self.ready.items) |job| self.destroyJob(job);
        self.ready.deinit(gpa);
        for (self.spreads.items) |*spread| {
            if (spread.gather) |*gather| self.freeGather(gather);
            if (spread.reference_observation) |observation| gpa.destroy(observation);
            if (spread.signature) |signature| signature.deinit(gpa);
            for (spread.pages) |maybe_page| if (maybe_page) |page| page.deinit(gpa);
        }
        self.spreads.deinit(gpa);
        self.resolver.deinit(gpa);
        for (self.spare.items) |buffer| gpa.free(buffer);
        self.spare.deinit(gpa);
        self.observations.deinit(gpa);
        self.* = undefined;
    }

    // region: frames in

    /// Take the next frame of the video. `seconds` is its time. `scratch` gives the
    /// working memory, as in `Job.run`.
    pub fn push(self: *Stream, scratch: Allocator, frame: intake.Source, seconds: f64) Error!Status {
        if (self.ended) return error.StreamEnded;
        if (!frame.isValid() or !std.meta.eql(frame.size(), self.options.source_size)) return error.InvalidFrame;
        const observation = try self.analyze(scratch, frame);
        return self.pushObserved(scratch, &observation, frame, seconds);
    }

    /// The observation of a frame. The function does not change the session, so
    /// several threads can analyse frames at the same time, each with its own
    /// `scratch`. The observations then go to `pushObserved` in the order of the video.
    pub fn analyze(self: *const Stream, scratch: Allocator, frame: intake.Source) Allocator.Error!FrameObservation {
        const shrunk = intake.shrunkSize(self.options.source_size, self.factor);
        const small = try scratch.alloc(u8, image.packedFrameSize(shrunk.width, shrunk.height));
        defer scratch.free(small);
        intake.shrink(small, frame, self.factor);
        const as_given = image.FrameView.fromPacked(small, shrunk.width, shrunk.height, self.options.colorimetry);
        if (self.options.rotation == .none) return observe.observeFrame(scratch, as_given, self.options.render.detect);

        const upright = try scratch.alloc(u8, image.packedFrameSize(self.analysis_size.width, self.analysis_size.height));
        defer scratch.free(upright);
        intake.rotate(upright, as_given, self.options.rotation);
        const view = image.FrameView.fromPacked(upright, self.analysis_size.width, self.analysis_size.height, self.options.colorimetry);
        return observe.observeFrame(scratch, view, self.options.render.detect);
    }

    /// Take the next frame of the video with its observation from `analyze`.
    pub fn pushObserved(
        self: *Stream,
        scratch: Allocator,
        observation: *const FrameObservation,
        frame: intake.Source,
        seconds: f64,
    ) Error!Status {
        if (self.ended) return error.StreamEnded;
        if (!frame.isValid() or !std.meta.eql(frame.size(), self.options.source_size)) return error.InvalidFrame;
        const gpa = self.gpa;
        const index: u32 = @intCast(self.frame_count);

        // The copy comes first: when the memory is full, the session has no change.
        var held: ?HeldFrame = if (observation.detected) try self.hold(index, observation, frame) else null;
        errdefer if (held) |copy| self.release(copy);
        try self.observations.append(gpa, observation.*);
        self.frame_count += 1;
        self.stats.frames += 1;
        if (observation.detected) self.stats.detected_frames += 1;
        self.noteTime(seconds);

        const step = try self.tracker.push(self.window(), index, JoinJudge{ .stream = self, .scratch = scratch });
        if (step.closed) |closed| try self.runClosed(scratch, closed, step.final, self.tracker.pending);
        if (step.opened) try self.openRun(index);

        // The frame goes to the spread in view, or to the spread before it.
        if (held) |copy| {
            const target = self.gatherFor(index, observation);
            if (target) |gather| {
                try gather.frames.append(gpa, copy);
                held = null;
                gather.fresh += 1;
                if (self.latest) |old| self.release(old);
                self.latest = null;
                const at_limit = self.options.max_held_frames > 0 and self.held_frames >= self.options.max_held_frames;
                const batch = if (at_limit) min_batch_frames else self.options.batch_frames;
                if (gather.fresh >= batch) try self.select(scratch, gather, self.fallbackOf(gather));
            } else {
                if (self.latest) |old| self.release(old);
                self.latest = copy;
                held = null;
            }
        }

        try self.advance(scratch);
        self.trimObservations();
        return self.status(observation);
    }

    /// The video has no more frames. The spreads that were open become final. The
    /// caller then runs the jobs that are left.
    pub fn finish(self: *Stream, scratch: Allocator) Error!void {
        if (self.ended) return;
        self.ended = true;
        const end = try self.tracker.finish(self.window(), JoinJudge{ .stream = self, .scratch = scratch });
        if (end.closed) |closed| try self.runClosed(scratch, closed, end.final[0], end.final[1]);
        // A run that the tracker did not close has no stable frames to give.
        if (self.current) |*gather| self.freeGather(gather);
        self.current = null;
        if (self.pending) |*gather| {
            if (end.final[1]) |segment| {
                try self.finalize(scratch, gather, segment);
            } else {
                self.freeGather(gather);
            }
            self.pending = null;
        }
        if (self.latest) |frame| self.release(frame);
        self.latest = null;
        if (self.page_geometry == null) try self.lockGeometry(scratch, null);
        try self.advance(scratch);
    }

    // endregion: frames in

    // region: jobs and pages out

    /// The next job, or null when no job is ready. The caller runs it and gives it
    /// back with `complete`.
    pub fn takeJob(self: *Stream) ?*Job {
        if (self.ready.items.len == 0) return null;
        self.jobs_out += 1;
        return self.ready.orderedRemove(0);
    }

    /// Take a job back. `done` is false when `Job.run` did not run or failed: the
    /// spread then has no pages. The session frees the job.
    pub fn complete(self: *Stream, job: *Job, done: bool) void {
        self.jobs_out -= 1;
        const spread = &self.spreads.items[job.spread];
        spread.job = null;
        if (done and !spread.replaced) {
            spread.pages = job.pages;
            spread.reports = job.reports;
            job.pages = @splat(null);
            spread.state = .done;
        } else {
            spread.state = .dropped;
        }
        self.destroyJob(job);
    }

    /// True when the session has work for the caller, or will have: a job, or a
    /// spread that waits.
    pub fn busy(self: *const Stream) bool {
        return self.ready.items.len > 0 or self.jobs_out > 0;
    }

    /// The number of pages that are complete, in the order of the document.
    pub fn pageCount(self: *const Stream) usize {
        var count: usize = 0;
        var pages = self.pageIterator();
        while (pages.next()) |_| count += 1;
        return count;
    }

    /// The pages that are complete, in the order of the document. The list can
    /// change after each call of `pushObserved`, `finish`, and `complete`: a new
    /// page comes, and a better copy of a spread takes the place of an old one.
    pub fn pageIterator(self: *const Stream) PageIterator {
        return .{ .stream = self };
    }

    pub const PageIterator = struct {
        stream: *const Stream,
        kept_position: usize = 0,
        page_index: u8 = 0,

        pub fn next(self: *PageIterator) ?Page {
            const kept = self.stream.resolver.kept.items;
            while (self.kept_position < kept.len) {
                const id = kept[self.kept_position].id;
                const spread = &self.stream.spreads.items[id];
                while (self.page_index < detect.max_pages) {
                    const index = self.page_index;
                    self.page_index += 1;
                    if (spread.state != .done) break;
                    const encoded = spread.pages[index] orelse continue;
                    return .{ .spread = id, .index = index, .encoded = encoded, .report = spread.reports[index] };
                }
                self.kept_position += 1;
                self.page_index = 0;
            }
            return null;
        }
    };

    /// The size of each page image, when it is known.
    pub fn pageSize(self: *const Stream) ?image.Size {
        return if (self.page_geometry) |found| found.size else null;
    }

    /// The number of spreads that the document has so far: the spreads that stay
    /// after the duplicate search, the spreads that wait for it, and the last
    /// spread of the timeline.
    pub fn spreadCount(self: *const Stream) usize {
        return self.resolver.kept.items.len + (self.spreads.items.len - self.next_waiting) +
            @intFromBool(self.tracker.pending != null);
    }

    /// Write the pages that are complete as a PDF.
    pub fn writePdf(self: *const Stream, output: pdf.Output, metadata: pdf.Metadata) pdf.Error!void {
        var writer = try pdf.Writer.init(self.gpa, output, metadata);
        defer writer.deinit();
        var pages = self.pageIterator();
        while (pages.next()) |page| {
            try writer.addPage(.{
                .jpeg = page.encoded.jpeg,
                .width_px = page.encoded.width,
                .height_px = page.encoded.height,
                .color_space = if (page.encoded.gray) .gray else .rgb,
                .dpi = @floatFromInt(self.options.render.jpeg.dpi),
            });
        }
        try writer.finish();
    }

    // endregion: jobs and pages out

    // region: time and observations

    fn window(self: *const Stream) timeline.Window {
        return .{ .items = self.observations.items, .base = self.base };
    }

    fn noteTime(self: *Stream, seconds: f64) void {
        if (self.frame_count == 1) self.first_seconds = seconds;
        self.last_seconds = seconds;
        if (self.options.frames_per_second > 0) return;
        const elapsed = self.last_seconds - self.first_seconds;
        if (self.frame_count < min_rate_frames or !(elapsed > 0)) return;
        const rate = @as(f64, @floatFromInt(self.frame_count - 1)) / elapsed;
        self.tracker.options.frames_per_second = @floatCast(std.math.clamp(rate, min_frames_per_second, max_frames_per_second));
    }

    fn framesPerSecond(self: *const Stream) f32 {
        return self.tracker.options.frames_per_second;
    }

    /// Drop the observations of the frames that no open spread can use.
    fn trimObservations(self: *Stream) void {
        var needed: usize = self.frame_count - 1;
        if (self.tracker.current) |run| needed = @min(needed, run.first);
        if (self.tracker.pending) |segment| needed = @min(needed, segment.first_frame);
        // One frame more: the motion measure of a frame needs the frame before it.
        needed -|= 1;
        if (needed < self.base + trim_step_frames) return;
        const drop = needed - self.base;
        const items = self.observations.items;
        @memmove(items[0 .. items.len - drop], items[drop..]);
        self.observations.shrinkRetainingCapacity(items.len - drop);
        self.base = needed;
    }

    // endregion: time and observations

    // region: frame buffers

    /// A copy of a frame of the source, with what the analysis knows about it.
    fn hold(self: *Stream, index: u32, observation: *const FrameObservation, frame: intake.Source) Allocator.Error!HeldFrame {
        const bytes = image.packedFrameSize(self.options.source_size.width, self.options.source_size.height);
        const data = self.spare.pop() orelse try self.gpa.alloc(u8, bytes);
        intake.copy(data, frame);
        var held: HeldFrame = .{ .index = index, .data = data, .quads = undefined, .clipped_edges = undefined, .colored = undefined };
        const scale: f32 = @floatFromInt(self.factor);
        for (&held.quads, &held.clipped_edges, &held.colored, &observation.pages) |*quad, *edges, *colored, *page| {
            quad.* = scaleQuad(page.quad, scale);
            edges.* = page.clipped_edges;
            colored.* = page.colored;
        }
        self.held_frames += 1;
        self.stats.peak_held_frames = @max(self.stats.peak_held_frames, self.held_frames);
        return held;
    }

    /// Give the buffer of a frame back.
    fn release(self: *Stream, frame: HeldFrame) void {
        self.held_frames -= 1;
        if (self.spare.items.len < max_spare_buffers) {
            if (self.spare.append(self.gpa, frame.data)) |_| return else |_| {}
        }
        self.gpa.free(frame.data);
    }

    fn freeGather(self: *Stream, gather: *Gather) void {
        for (gather.frames.items) |frame| self.release(frame);
        gather.frames.deinit(self.gpa);
        gather.* = undefined;
    }

    fn destroyJob(self: *Stream, job: *Job) void {
        for (job.frames) |frame| self.release(frame.held);
        self.gpa.free(job.frames);
        for (job.pages) |maybe_page| if (maybe_page) |page| page.deinit(self.gpa);
        self.gpa.destroy(job);
    }

    // endregion: frame buffers

    // region: the frames of a spread

    /// The spread that takes the frame `index`, if one does.
    fn gatherFor(self: *Stream, index: u32, observation: *const FrameObservation) ?*Gather {
        if (self.current) |*gather| {
            // All the frames of a run can be its best frame, also a frame of a short break.
            if (observation.kind == gather.kind) return gather;
            return null;
        }
        if (self.pending) |*gather| {
            const segment = self.tracker.pending orelse return null;
            if (observation.kind != gather.kind) return null;
            if (index > segment.last_frame + self.marginFrames()) return null;
            return gather;
        }
        return null;
    }

    fn marginFrames(self: *const Stream) u32 {
        return @intFromFloat(@round(self.options.donor_margin_seconds * self.framesPerSecond()));
    }

    /// The first choice of the timeline for a spread, when the timeline has one.
    fn fallbackOf(self: *const Stream, gather: *const Gather) ?u32 {
        if (self.pending) |*pending| {
            if (pending == gather) return if (self.tracker.pending) |segment| segment.reference else null;
        }
        return null;
    }

    /// A run of stable frames started at the frame before `index`.
    fn openRun(self: *Stream, index: u32) Allocator.Error!void {
        const run = self.tracker.current.?;
        var gather: Gather = .{ .kind = run.kind };
        errdefer self.freeGather(&gather);
        // The first frame of the run came before the run was known.
        const first = index - 1;
        var found: ?HeldFrame = null;
        if (self.latest) |frame| {
            if (frame.index == first) {
                found = frame;
                self.latest = null;
            }
        }
        if (found == null) {
            if (self.pending) |*pending| found = pending.take(first);
        }
        if (found) |frame| {
            errdefer self.release(frame);
            try gather.frames.append(self.gpa, frame);
            gather.fresh += 1;
        }
        self.current = gather;
    }

    /// The judge of the timeline for the join of two runs of stable frames.
    const JoinJudge = struct {
        stream: *Stream,
        scratch: Allocator,

        pub fn sameSpread(self: JoinJudge, previous: timeline.Segment, run: timeline.Segment) Allocator.Error!bool {
            return self.stream.runsShowOneSpread(self.scratch, previous, run);
        }
    };

    /// True when the run that ended shows the spread of `pending` again. The
    /// thumbnails of the two runs are similar; the duplicate search on the small
    /// pictures of the pages decides. With no small picture of each run, the
    /// thumbnails decide.
    fn runsShowOneSpread(self: *Stream, scratch: Allocator, previous: timeline.Segment, run: timeline.Segment) Allocator.Error!bool {
        const earlier = if (self.pending) |*gather| gather.picture(previous.reference) else null;
        const later = if (self.current) |*gather| gather.picture(run.reference) else null;
        if (earlier == null or later == null) return true;
        const page_size = if (self.page_geometry) |found| found.size else size: {
            // The page size is not final yet: the size from the two runs.
            const observations = [2]FrameObservation{
                self.observations.items[previous.reference - self.base],
                self.observations.items[run.reference - self.base],
            };
            var segments = [2]timeline.Segment{ previous, run };
            segments[0].reference = 0;
            segments[1].reference = 1;
            const scale: f32 = @floatFromInt(self.factor);
            const found = try document.pageGeometry(scratch, &observations, &segments, self.analysis_size, scale, self.options.geometry);
            break :size (found orelse return true).size;
        };
        const kind = previous.kind;
        const first = try self.signatureOf(scratch, scratch, earlier.?, kind, page_size);
        defer first.deinit(scratch);
        const second = try self.signatureOf(scratch, scratch, later.?, kind, page_size);
        defer second.deinit(scratch);
        if (first.page_count != kind.pageCount() or second.page_count != kind.pageCount()) return true;
        const comparison = try dedup.compare(scratch, &candidateOf(previous, &first), &candidateOf(run, &second), self.options.dedup);
        if (!comparison.same) self.stats.runs_kept_apart += 1;
        return comparison.same;
    }

    /// A run of stable frames ended. `final` is the spread that can change no more,
    /// and `pending_after` is the last spread after this run.
    fn runClosed(
        self: *Stream,
        scratch: Allocator,
        closed: timeline.Tracker.Closed,
        final: ?timeline.Segment,
        pending_after: ?timeline.Segment,
    ) Error!void {
        var gather = self.current orelse return;
        self.current = null;
        // True while the frames of the run belong to `gather`.
        var owned = true;
        errdefer if (owned) self.freeGather(&gather);
        switch (closed.fate) {
            .rejected => {},
            .merged => if (self.pending) |*pending| {
                if (pending.view_count < max_views) {
                    try pending.frames.appendSlice(self.gpa, gather.frames.items);
                    pending.fresh += @intCast(gather.frames.items.len);
                    gather.frames.deinit(self.gpa);
                    owned = false;
                    pending.views[pending.view_count] = closed.frames;
                    pending.view_count += 1;
                }
                try self.select(scratch, pending, pending_after.?.reference);
            },
            .accepted => {
                if (self.pending) |*old| {
                    if (final) |segment| {
                        try self.finalize(scratch, old, segment);
                    } else {
                        self.freeGather(old);
                    }
                    self.pending = null;
                }
                gather.views[0] = closed.frames;
                gather.view_count = 1;
                self.pending = gather;
                owned = false;
                try self.select(scratch, &self.pending.?, pending_after.?.reference);
            },
        }
        if (owned) self.freeGather(&gather);
        owned = false;
    }

    /// Make the choice of `timeline.chooseReference` and `timeline.selectDonors`
    /// among the frames in hand, and drop the frames that the choice does not take.
    /// `first_choice` is the reference frame of the timeline; null while the spread
    /// is in view, when it is the best frame so far.
    fn select(self: *Stream, scratch: Allocator, gather: *Gather, first_choice: ?u32) Allocator.Error!void {
        gather.fresh = 0;
        self.stats.selections += 1;
        const observations = self.observations.items;
        const base: u32 = @intCast(self.base);
        const newest: u32 = @intCast(self.frame_count - 1);

        // The stable time of the spread, in positions of the window.
        var views: [max_views]timeline.FrameSpan = undefined;
        var view_count: usize = gather.view_count;
        if (view_count == 0) {
            // The run in view.
            const run = self.tracker.current orelse return;
            views[0] = .{ .first = @intCast(run.first), .last = @intCast(run.last) };
            view_count = 1;
        } else {
            @memcpy(views[0..view_count], gather.views[0..view_count]);
        }
        var spans: [max_views]timeline.FrameSpan = undefined;
        const margin = self.marginFrames();
        for (views[0..view_count], spans[0..view_count]) |*view, *span| {
            // A frame before the window has no observation. The first frame of the
            // window has no frame before it for the motion measure.
            view.first = @max(view.first, base + 1) - base;
            view.last = view.last - base;
            span.* = .{ .first = view.first, .last = @min(view.last + margin, newest - base) };
        }

        // The frames with a known frame after them: their motion is known.
        const allowed = try scratch.alloc(u32, gather.frames.items.len);
        defer scratch.free(allowed);
        var allowed_count: usize = 0;
        for (gather.frames.items) |frame| {
            if (frame.index <= base) continue;
            if (frame.index == newest and !self.ended) continue;
            allowed[allowed_count] = frame.index - base;
            allowed_count += 1;
        }
        const in_hand = allowed[0..allowed_count];

        // The first choice: the frame of the stable time with the best score.
        var fallback: ?u32 = null;
        if (first_choice) |frame| {
            if (gather.find(frame) != null and frame > base) fallback = frame - base;
        }
        if (fallback == null) {
            var best_score = -std.math.inf(f32);
            for (in_hand) |position| {
                const frame = &observations[position];
                if (!frame.detected or frame.kind != gather.kind) continue;
                if (!inSpans(views[0..view_count], position)) continue;
                const score = timeline.referenceScore(observations, position);
                if (score > best_score) {
                    best_score = score;
                    fallback = position;
                }
            }
        }
        const fallback_position = fallback orelse {
            gather.choice = null;
            return;
        };

        const page_aspect: ?f32 = if (self.page_geometry) |found| found.aspect else null;
        var reference_options = self.options.reference;
        reference_options.page_aspect = page_aspect;
        reference_options.allowed = in_hand;

        var choice: Choice = .{ .fallback = fallback_position + base };
        const page_count = gather.kind.pageCount();
        var references: [detect.max_pages]timeline.Reference = undefined;
        for (0..page_count) |page_index| {
            references[page_index] = try timeline.chooseReference(
                scratch,
                observations,
                views[0..view_count],
                fallback_position,
                page_index,
                reference_options,
            );
        }
        const shared = page_count == 1 or references[0].frame == references[1].frame;
        var donor_options = self.options.donor;
        donor_options.page_aspect = page_aspect;
        donor_options.allowed = in_hand;
        if (self.options.max_held_frames > 0) {
            // The limit of the memory: the donor frames take the place that the
            // other spreads, the jobs, and the next frames of this spread leave.
            const others = self.held_frames - @as(u32, @intCast(gather.frames.items.len));
            const needed = 1 + @as(u32, page_count) + min_batch_frames + 1;
            const room = (self.options.max_held_frames -| others) -| needed;
            if (room < @as(u32, donor_options.count) + donor_options.cut_count) self.stats.donor_limits += 1;
            donor_options.count = @intCast(@min(donor_options.count, room));
            donor_options.cut_count = @intCast(@min(donor_options.cut_count, room - donor_options.count));
        }
        if (!shared) {
            // The two pages share the donor frames of the spread.
            donor_options.count = (donor_options.count + 1) / 2;
            donor_options.cut_count = (donor_options.cut_count + 1) / 2;
        }
        choice.pass_count = if (shared) 1 else page_count;
        for (choice.passes[0..choice.pass_count], 0..) |*pass, pass_index| {
            const reference = references[pass_index];
            pass.* = .{
                .reference = .{ .frame = reference.frame + base, .ink = reference.ink, .score = reference.score },
                .only_page = if (shared) null else @as(u8, @intCast(pass_index)),
            };
            const donors = try timeline.selectDonors(
                scratch,
                observations,
                spans[0..view_count],
                reference.frame,
                if (shared) null else pass_index,
                donor_options,
            );
            defer scratch.free(donors);
            pass.donor_count = @intCast(@min(donors.len, max_pass_donors));
            for (pass.donors[0..pass.donor_count], donors[0..pass.donor_count]) |*target, donor| target.* = donor + base;
        }
        gather.choice = choice;

        // Drop the frames that the choice does not take. A frame with no known
        // frame after it stays for the next choice.
        var kept: usize = 0;
        for (gather.frames.items) |frame| {
            const unknown = frame.index == newest and !self.ended;
            if (unknown or choice.uses(frame.index)) {
                gather.frames.items[kept] = frame;
                kept += 1;
            } else {
                self.release(frame);
            }
        }
        gather.frames.shrinkRetainingCapacity(kept);
    }

    // endregion: the frames of a spread

    // region: spreads that are final

    /// The spread of `gather` can change no more: it goes to the list of spreads.
    fn finalize(self: *Stream, scratch: Allocator, gather: *Gather, segment: timeline.Segment) Error!void {
        {
            var owned = gather.*;
            gather.* = .{ .kind = owned.kind };
            errdefer self.freeGather(&owned);
            try self.select(scratch, &owned, segment.reference);

            var spread: Spread = .{ .segment = segment };
            if (self.page_geometry == null) {
                const observation = try self.gpa.create(FrameObservation);
                observation.* = self.observations.items[segment.reference - self.base];
                spread.reference_observation = observation;
            }
            errdefer if (spread.reference_observation) |observation| self.gpa.destroy(observation);
            spread.gather = owned;
            try self.spreads.append(self.gpa, spread);
        }
        self.stats.segments += 1;

        if (self.page_geometry == null and self.spreads.items.len + 1 >= self.options.geometry_spreads) {
            try self.lockGeometry(scratch, self.tracker.pending);
        }
    }

    /// Choose the page size of the document from the spreads so far. `open` is the
    /// last spread of the timeline, which is not in the list yet.
    fn lockGeometry(self: *Stream, scratch: Allocator, open: ?timeline.Segment) Allocator.Error!void {
        const count = self.spreads.items.len + @intFromBool(open != null);
        if (count == 0) return;
        const observations = try scratch.alloc(FrameObservation, count);
        defer scratch.free(observations);
        const segments = try scratch.alloc(timeline.Segment, count);
        defer scratch.free(segments);
        var used: usize = 0;
        for (self.spreads.items) |*spread| {
            const observation = spread.reference_observation orelse continue;
            observations[used] = observation.*;
            segments[used] = spread.segment;
            segments[used].reference = @intCast(used);
            used += 1;
        }
        if (open) |segment| {
            observations[used] = self.observations.items[segment.reference - self.base];
            segments[used] = segment;
            segments[used].reference = @intCast(used);
            used += 1;
        }
        const scale: f32 = @floatFromInt(self.factor);
        self.page_geometry = try document.pageGeometry(
            scratch,
            observations[0..used],
            segments[0..used],
            self.analysis_size,
            scale,
            self.options.geometry,
        );
        if (self.page_geometry == null) return;
        for (self.spreads.items) |*spread| {
            if (spread.reference_observation) |observation| self.gpa.destroy(observation);
            spread.reference_observation = null;
        }
    }

    /// Give each spread that waits its place: a copy of another spread goes, and a
    /// spread that stays gets a job.
    fn advance(self: *Stream, scratch: Allocator) Error!void {
        const found = self.page_geometry orelse return;
        while (self.next_waiting < self.spreads.items.len) {
            const id: u32 = @intCast(self.next_waiting);
            try self.resolve(scratch, id, found.size);
            self.next_waiting += 1;
        }
    }

    fn resolve(self: *Stream, scratch: Allocator, id: u32, page_size: image.Size) Error!void {
        const gpa = self.gpa;
        const spread = &self.spreads.items[id];
        var gather = spread.gather.?;
        spread.gather = null;
        errdefer self.freeGather(&gather);
        spread.state = .dropped;

        const choice = gather.choice orelse {
            self.stats.unusable_spreads += 1;
            self.freeGather(&gather);
            return;
        };
        const first_choice = gather.find(choice.fallback) orelse {
            self.stats.unusable_spreads += 1;
            self.freeGather(&gather);
            return;
        };

        // A small picture of each page, from the first choice of the timeline.
        const signature = try self.signatureOf(gpa, scratch, first_choice, spread.segment.kind, page_size);
        if (signature.page_count != spread.segment.kind.pageCount()) {
            signature.deinit(gpa);
            self.stats.unusable_spreads += 1;
            self.freeGather(&gather);
            return;
        }
        spread.signature = signature;

        const decision = try self.resolver.add(gpa, id, candidateOf(spread.segment, &spread.signature.?), null);
        switch (decision) {
            .kept => {},
            .duplicate => {
                self.stats.duplicate_spreads += 1;
                self.freeGather(&gather);
                self.freeOldSignatures();
                return;
            },
            .replaces => |earlier| {
                self.stats.duplicate_spreads += 1;
                self.dropSpread(earlier);
            },
        }
        self.freeOldSignatures();

        const job = try self.makeJob(id, &gather, choice, page_size);
        errdefer self.destroyJob(job);
        try self.ready.append(gpa, job);
        const stored = &self.spreads.items[id];
        stored.job = job;
        stored.state = .queued;
    }

    /// The small picture of each page of a frame in hand, for the duplicate search.
    fn signatureOf(
        self: *const Stream,
        allocator: Allocator,
        scratch: Allocator,
        frame: *const HeldFrame,
        kind: detect.LayoutKind,
        page_size: image.Size,
    ) Allocator.Error!render.SpreadSignature {
        var upright: ?[]u8 = null;
        defer if (upright) |buffer| scratch.free(buffer);
        var data: []const u8 = frame.data;
        const source_size = self.options.source_size;
        if (self.options.rotation != .none) {
            const buffer = try scratch.alloc(u8, image.packedFrameSize(self.upright_size.width, self.upright_size.height));
            upright = buffer;
            const as_given = image.FrameView.fromPacked(frame.data, source_size.width, source_size.height, self.options.colorimetry);
            intake.rotate(buffer, as_given, self.options.rotation);
            data = buffer;
        }
        return render.renderSignature(
            allocator,
            scratch,
            .{
                .frame = image.FrameView.fromPacked(data, self.upright_size.width, self.upright_size.height, self.options.colorimetry),
                .quads = frame.quads,
                .clipped_edges = frame.clipped_edges,
                .colored = frame.colored,
            },
            kind,
            page_size,
            self.options.render,
        );
    }

    /// A better copy took the place of a spread: its pages leave the document.
    fn dropSpread(self: *Stream, id: u32) void {
        const spread = &self.spreads.items[id];
        spread.replaced = true;
        for (&spread.pages) |*maybe_page| {
            if (maybe_page.*) |page| page.deinit(self.gpa);
            maybe_page.* = null;
        }
        if (spread.state == .done) spread.state = .dropped;
        // A job that the caller did not take yet has no use.
        const job = spread.job orelse return;
        for (self.ready.items, 0..) |waiting, position| {
            if (waiting != job) continue;
            _ = self.ready.orderedRemove(position);
            self.destroyJob(job);
            spread.job = null;
            spread.state = .dropped;
            return;
        }
    }

    /// Free the small pictures that the duplicate search reads no more.
    fn freeOldSignatures(self: *Stream) void {
        for (self.spreads.items[0..@min(self.next_waiting + 1, self.spreads.items.len)], 0..) |*spread, id| {
            const signature = spread.signature orelse continue;
            if (self.resolver.compares(@intCast(id))) continue;
            signature.deinit(self.gpa);
            spread.signature = null;
        }
    }

    /// The job of a spread. The frames of the choice go from `gather` to the job,
    /// and the other frames of `gather` go back.
    fn makeJob(self: *Stream, id: u32, gather: *Gather, choice: Choice, page_size: image.Size) Allocator.Error!*Job {
        const gpa = self.gpa;
        var passes = choice.passes;
        const pass_count = choice.pass_count;
        // The limit of the memory: the frames of this job take the place that is left.
        if (self.options.max_held_frames > 0) {
            const others = self.held_frames - @as(u32, @intCast(gather.frames.items.len));
            while (others + jobFrameCount(passes[0..pass_count]) > self.options.max_held_frames) {
                // The pass with the most donor frames gives one.
                var largest: ?*Pass = null;
                for (passes[0..pass_count]) |*pass| {
                    if (pass.donor_count == 0) continue;
                    if (largest == null or pass.donor_count > largest.?.donor_count) largest = pass;
                }
                const pass = largest orelse break;
                pass.donor_count -= 1;
                self.stats.donors_dropped += 1;
            }
        }

        // Each frame of the passes one time. A frame that the session holds no more
        // is not in the job.
        var wanted: [detect.max_pages * (max_pass_donors + 1)]u32 = undefined;
        var wanted_count: usize = 0;
        for (passes[0..pass_count]) |*pass| {
            var frames_of_pass: [max_pass_donors + 1]u32 = undefined;
            frames_of_pass[0] = pass.reference.frame;
            @memcpy(frames_of_pass[1..][0..pass.donor_count], pass.donorSlice());
            for (frames_of_pass[0 .. pass.donor_count + 1]) |index| {
                if (std.mem.findScalar(u32, wanted[0..wanted_count], index) != null) continue;
                if (gather.find(index) == null) continue;
                wanted[wanted_count] = index;
                wanted_count += 1;
            }
        }

        const frames = try gpa.alloc(JobFrame, wanted_count);
        errdefer gpa.free(frames);
        const job = try gpa.create(Job);
        job.* = .{
            .gpa = gpa,
            .spread = id,
            .kind = gather.kind,
            .page_size = page_size,
            .source_size = self.options.source_size,
            .rotation = self.options.rotation,
            .colorimetry = self.options.colorimetry,
            .options = self.options.render,
            .frames = frames,
        };
        // No step after this one can fail.
        for (frames, wanted[0..wanted_count]) |*frame, index| frame.* = .{ .held = gather.take(index).? };
        for (passes[0..pass_count]) |*pass| {
            const reference = jobFramePosition(frames, pass.reference.frame) orelse continue;
            var job_pass: JobPass = .{ .reference = reference, .only_page = pass.only_page, .reference_score = pass.reference };
            for (pass.donorSlice()) |index| {
                const position = jobFramePosition(frames, index) orelse continue;
                job_pass.donors[job_pass.donor_count] = position;
                job_pass.donor_count += 1;
            }
            job.passes[job.pass_count] = job_pass;
            job.pass_count += 1;
        }
        self.freeGather(gather);
        gather.* = .{ .kind = job.kind };
        return job;
    }

    // endregion: spreads that are final

    fn status(self: *const Stream, observation: *const FrameObservation) Status {
        var result: Status = .{
            .detected = observation.detected,
            .page_count = observation.pageCount(),
            .spreads = @intCast(self.spreadCount()),
            .pages = @intCast(self.pageCount()),
            .jobs_ready = @intCast(self.ready.items.len),
            .held_frames = self.held_frames,
        };
        if (observation.detected) {
            const scale: f32 = @floatFromInt(self.factor);
            for (&result.quads, &observation.pages) |*quad, *page| quad.* = scaleQuad(page.quad, scale);
        }
        if (self.tracker.current) |run| {
            result.steady = self.tracker.gap == 0;
            // The timeline takes a view only when its best frame shows the page
            // with clear edges and with little of it covered. This frame is a
            // sign for that: the best frame is known only at the end of the view.
            const limits = self.tracker.options;
            const clear = observation.detected and
                observation.coveredFraction() <= limits.max_reference_cover and
                observation.edge_support >= limits.min_reference_support;
            result.captured = clear and run.stable >= self.tracker.minRunFrames();
        }
        return result;
    }
};

fn jobFramePosition(frames: []const JobFrame, index: u32) ?u8 {
    for (frames, 0..) |frame, position| {
        if (frame.held.index == index) return @intCast(position);
    }
    return null;
}

/// The number of different frames of some passes.
fn jobFrameCount(passes: []const Pass) usize {
    var seen: [detect.max_pages * (max_pass_donors + 1)]u32 = undefined;
    var count: usize = 0;
    for (passes) |*pass| {
        var wanted: [max_pass_donors + 1]u32 = undefined;
        wanted[0] = pass.reference.frame;
        @memcpy(wanted[1..][0..pass.donor_count], pass.donorSlice());
        for (wanted[0 .. pass.donor_count + 1]) |index| {
            if (std.mem.findScalar(u32, seen[0..count], index) != null) continue;
            seen[count] = index;
            count += 1;
        }
    }
    return count;
}

fn inSpans(spans: []const timeline.FrameSpan, frame: u32) bool {
    for (spans) |span| {
        if (frame >= span.first and frame <= span.last) return true;
    }
    return false;
}

/// A quad of the small frame in pixels of the full-size frame. Pixel centers are
/// at integer coordinates in the two frames.
fn scaleQuad(quad: Quad, scale: f32) Quad {
    const Convert = struct {
        fn point(p: geometry.Point, factor: f32) geometry.Point {
            return .{ .x = (p.x + 0.5) * factor - 0.5, .y = (p.y + 0.5) * factor - 0.5 };
        }
    };
    return .{
        .tl = Convert.point(quad.tl, scale),
        .tr = Convert.point(quad.tr, scale),
        .br = Convert.point(quad.br, scale),
        .bl = Convert.point(quad.bl, scale),
    };
}

// endregion: stream

// region: tests

const testing = std.testing;

const test_width = 320;
const test_height = 240;
const test_frame_bytes = image.packedFrameSize(test_width, test_height);

const test_page: Quad = .{
    .tl = geometry.Point.init(80, 30),
    .tr = geometry.Point.init(230, 30),
    .br = geometry.Point.init(230, 210),
    .bl = geometry.Point.init(80, 210),
};

fn shifted(quad: Quad, dx: f32, dy: f32) Quad {
    const shift = geometry.Point.init(dx, dy);
    return .{ .tl = quad.tl.add(shift), .tr = quad.tr.add(shift), .br = quad.br.add(shift), .bl = quad.bl.add(shift) };
}

/// A frame of `width` x `height` pixels with a dark desk and, when `page` is given,
/// a bright page with a pattern of dots and a dark bar. `seed` selects the pattern:
/// two seeds are two different pages.
fn fillTestFrame(buffer: []u8, width: usize, height: usize, page: ?Quad, seed: u32) void {
    const desk = 70;
    const luma_size = width * height;
    const chroma_width = width / 2;
    const chroma_size = chroma_width * (height / 2);
    @memset(buffer[0..luma_size], desk);
    @memset(buffer[luma_size..][0..chroma_size], 128);
    @memset(buffer[luma_size + chroma_size ..][0..chroma_size], 150);
    const quad = page orelse return;
    const to_page = geometry.Homography.fromQuads(quad, Quad.rect(1, 1)).?;
    const bar_top = 0.25 + 0.1 * @as(f32, @floatFromInt(seed % 5));
    for (0..height) |y| {
        for (0..width) |x| {
            const p = geometry.Point.init(@floatFromInt(x), @floatFromInt(y));
            if (!quad.contains(p)) continue;
            const uv = to_page.apply(p);
            const on_bar = uv.x > 0.2 and uv.x < 0.8 and uv.y > bar_top and uv.y < bar_top + 0.12;
            const column: u32 = @intFromFloat(@max(uv.x, 0) * 40);
            const row: u32 = @intFromFloat(@max(uv.y, 0) * 50);
            const dot = (column * (7 + seed) + row * (13 + 2 * seed)) % 11 == 0;
            buffer[y * width + x] = if (on_bar) 40 else if (dot) 120 else 200;
        }
    }
    for (0..height / 2) |y| {
        for (0..chroma_width) |x| {
            const p = geometry.Point.init(@floatFromInt(2 * x), @floatFromInt(2 * y));
            if (quad.contains(p)) buffer[luma_size + chroma_size + y * chroma_width + x] = 128;
        }
    }
}

fn testSource(buffer: []const u8, width: u32, height: u32) intake.Source {
    return intake.Source.fromFrame(image.FrameView.fromPacked(buffer, width, height, .{}));
}

const test_options: Options = .{
    .source_size = .{ .width = test_width, .height = test_height },
    .frames_per_second = 30,
    // Small pages need small tiles.
    .render = .{ .register = .{ .tile = 16, .max_levels = 2 }, .fuse = .{ .cell = 4 } },
    .geometry = .{ .min_height_px = 100 },
    .batch_frames = 4,
};

const TestVideo = struct {
    stream: Stream,
    buffer: []u8,
    frame: u32 = 0,

    fn init(options: Options) !TestVideo {
        return .{
            .stream = .init(testing.allocator, options),
            .buffer = try testing.allocator.alloc(u8, test_frame_bytes),
        };
    }

    fn deinit(self: *TestVideo) void {
        self.stream.deinit();
        testing.allocator.free(self.buffer);
    }

    /// Show a page for some frames. The camera drifts by `drift` pixels per frame.
    fn show(self: *TestVideo, seed: u32, frames: usize, drift: f32) !void {
        for (0..frames) |step| {
            fillTestFrame(self.buffer, test_width, test_height, shifted(test_page, drift * @as(f32, @floatFromInt(step)), 0), seed);
            try self.pushBuffer();
        }
    }

    /// Show a page for some frames, `offset` pixels to the right of its usual place.
    fn showAt(self: *TestVideo, seed: u32, frames: usize, offset: f32) !void {
        for (0..frames) |_| {
            fillTestFrame(self.buffer, test_width, test_height, shifted(test_page, offset, 0), seed);
            try self.pushBuffer();
        }
    }

    /// Show the desk with no page: the time of a page turn.
    fn turn(self: *TestVideo, frames: usize) !void {
        for (0..frames) |_| {
            fillTestFrame(self.buffer, test_width, test_height, null, 0);
            try self.pushBuffer();
        }
    }

    fn pushBuffer(self: *TestVideo) !void {
        const seconds = @as(f64, @floatFromInt(self.frame)) / 30.0;
        _ = try self.stream.push(testing.allocator, testSource(self.buffer, test_width, test_height), seconds);
        self.frame += 1;
    }

    /// Run all the jobs that are ready. Returns the number of jobs.
    fn runJobs(self: *TestVideo) !usize {
        var count: usize = 0;
        while (self.stream.takeJob()) |job| {
            job.run(testing.allocator) catch |err| {
                self.stream.complete(job, false);
                return err;
            };
            self.stream.complete(job, true);
            count += 1;
        }
        return count;
    }
};

test "a video of two pages gives two pages, each one after the next page is known" {
    var video = try TestVideo.init(test_options);
    defer video.deinit();

    try video.show(1, 12, 0);
    try video.turn(8);
    try testing.expectEqual(@as(usize, 0), try video.runJobs());
    try video.show(2, 12, 0);
    // The second page is in view, and no frame says yet that it is a new page.
    try testing.expectEqual(@as(usize, 0), try video.runJobs());
    try video.turn(8);
    // The first page is final now, and the page size is known.
    try testing.expectEqual(@as(usize, 1), try video.runJobs());
    try testing.expectEqual(@as(usize, 1), video.stream.pageCount());
    try video.stream.finish(testing.allocator);
    try testing.expectEqual(@as(usize, 1), try video.runJobs());

    try testing.expectEqual(@as(usize, 2), video.stream.pageCount());
    try testing.expectEqual(@as(u32, 2), video.stream.stats.segments);
    const size = video.stream.pageSize().?;
    try testing.expect(size.height > size.width);
    var pages = video.stream.pageIterator();
    var spread: u32 = 0;
    while (pages.next()) |page| : (spread += 1) {
        try testing.expectEqual(spread, page.spread);
        try testing.expectEqual(size.width, page.encoded.width);
        try testing.expect(page.encoded.jpeg.len > 100);
    }

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    const Sink = struct {
        fn write(context: ?*anyopaque, data: []const u8) pdf.WriteError!void {
            const list: *std.ArrayList(u8) = @ptrCast(@alignCast(context.?));
            list.appendSlice(testing.allocator, data) catch return error.WriteFailed;
        }
    };
    try video.stream.writePdf(.{ .context = &bytes, .writeFn = Sink.write }, .{});
    try testing.expect(std.mem.startsWith(u8, bytes.items, "%PDF-"));
    try testing.expect(std.mem.find(u8, bytes.items, "/Count 2") != null);
    try testing.expectError(error.StreamEnded, video.pushBuffer());
}

test "a view after a short break joins the spread before it" {
    var video = try TestVideo.init(test_options);
    defer video.deinit();
    try video.show(1, 12, 0);
    try video.turn(8);
    try video.show(1, 12, 0);
    try video.stream.finish(testing.allocator);
    _ = try video.runJobs();
    try testing.expectEqual(@as(u32, 0), video.stream.stats.runs_kept_apart);
    try testing.expectEqual(@as(u32, 1), video.stream.stats.segments);
    try testing.expectEqual(@as(usize, 1), video.stream.pageCount());
}

test "a page with the thumbnail of the page before it stays a page of its own" {
    var video = try TestVideo.init(test_options);
    defer video.deinit();
    // The seeds 1 and 6 give the bar at the same place and other dots.
    try video.show(1, 12, 0);
    try video.turn(8);
    try video.show(6, 12, 0);
    try video.stream.finish(testing.allocator);
    _ = try video.runJobs();
    try testing.expectEqual(@as(u32, 1), video.stream.stats.runs_kept_apart);
    try testing.expectEqual(@as(u32, 2), video.stream.stats.segments);
    try testing.expectEqual(@as(usize, 2), video.stream.pageCount());
}

test "a page that comes again later stays one time" {
    var video = try TestVideo.init(test_options);
    defer video.deinit();
    try video.show(1, 12, 0);
    try video.turn(8);
    try video.show(2, 12, 0);
    try video.turn(8);
    try video.show(1, 12, 0);
    try video.stream.finish(testing.allocator);
    _ = try video.runJobs();
    try testing.expectEqual(@as(u32, 3), video.stream.stats.segments);
    try testing.expectEqual(@as(u32, 1), video.stream.stats.duplicate_spreads);
    try testing.expectEqual(@as(usize, 2), video.stream.pageCount());
}

test "a better view of a page takes the place of the first view" {
    var video = try TestVideo.init(test_options);
    defer video.deinit();
    // The first view cuts the right side of the page.
    try video.showAt(1, 12, 96);
    try video.turn(8);
    try video.show(2, 12, 0);
    try video.turn(8);
    _ = try video.runJobs();
    try testing.expectEqual(@as(usize, 1), video.stream.pageCount());
    // The page of the first view again, with all of its sides in view.
    try video.show(1, 12, 0);
    try video.stream.finish(testing.allocator);
    _ = try video.runJobs();

    try testing.expectEqual(@as(u32, 3), video.stream.stats.segments);
    try testing.expectEqual(@as(u32, 1), video.stream.stats.duplicate_spreads);
    try testing.expectEqual(@as(usize, 2), video.stream.pageCount());
    // The better view has its own place in the order: after the second page.
    var pages = video.stream.pageIterator();
    try testing.expectEqual(@as(u32, 1), pages.next().?.spread);
    try testing.expectEqual(@as(u32, 2), pages.next().?.spread);
    try testing.expect(pages.next() == null);
}

test "a long view holds only a few full-size frames" {
    var options = test_options;
    options.donor = .{ .count = 2, .cut_count = 0 };
    var video = try TestVideo.init(options);
    defer video.deinit();
    // Four seconds of one page, with a camera that drifts.
    try video.show(1, 120, 0.1);
    // The first choice, the reference, two donors, the frames of one batch, and
    // the last frame.
    const limit = 1 + 1 + options.donor.count + options.batch_frames + 1;
    try testing.expect(video.stream.stats.peak_held_frames <= limit);
    try testing.expect(video.stream.stats.selections >= 120 / options.batch_frames - 1);
    try video.stream.finish(testing.allocator);
    try testing.expectEqual(@as(usize, 1), try video.runJobs());
    try testing.expectEqual(@as(usize, 1), video.stream.pageCount());
    try testing.expectEqual(@as(u32, 0), video.stream.held_frames);
}

test "near the limit of the frames in memory a spread gets fewer donor frames" {
    var options = test_options;
    options.donor = .{ .count = 4, .cut_count = 0 };
    // What a spread of one page needs with no donor frame: the first choice, the
    // reference, two new frames, and the last frame.
    const needed: u32 = 1 + 1 + min_batch_frames + 1;
    var frame_counts: [2]usize = undefined;
    // A limit with a place for one donor frame, then no limit.
    for ([_]u32{ needed + 1, 0 }, &frame_counts) |limit, *frame_count| {
        options.max_held_frames = limit;
        var video = try TestVideo.init(options);
        defer video.deinit();
        try video.show(1, 60, 0.2);
        if (limit > 0) {
            try testing.expect(video.stream.stats.peak_held_frames <= limit);
            try testing.expect(video.stream.stats.donor_limits > 0);
        }
        try video.stream.finish(testing.allocator);
        const job = video.stream.takeJob().?;
        frame_count.* = job.frameCount();
        try job.run(testing.allocator);
        video.stream.complete(job, true);
        try testing.expectEqual(@as(usize, 1), video.stream.pageCount());
    }
    // With the limit: the reference and one donor frame at most.
    try testing.expect(frame_counts[0] <= 2);
    try testing.expect(frame_counts[1] > frame_counts[0]);
}

test "a source on its side gives the pages of the upright source" {
    // The upright video: a page for 12 frames, 240 pixels wide and 320 pixels high.
    const upright_width = test_height;
    const upright_height = test_width;
    const page: Quad = .{
        .tl = geometry.Point.init(40, 60),
        .tr = geometry.Point.init(200, 60),
        .br = geometry.Point.init(200, 270),
        .bl = geometry.Point.init(40, 270),
    };
    const upright = try testing.allocator.alloc(u8, test_frame_bytes);
    defer testing.allocator.free(upright);
    fillTestFrame(upright, upright_width, upright_height, page, 3);
    // The sensor gives the same picture on its side: a quarter turn makes it upright.
    const sideways = try testing.allocator.alloc(u8, test_frame_bytes);
    defer testing.allocator.free(sideways);
    intake.rotate(sideways, image.FrameView.fromPacked(upright, upright_width, upright_height, .{}), .three_quarters);

    var results: [2][]u8 = undefined;
    var result_count: usize = 0;
    defer for (results[0..result_count]) |bytes| testing.allocator.free(bytes);
    for ([_]bool{ false, true }) |turned| {
        var options = test_options;
        if (turned) {
            options.rotation = .quarter;
        } else {
            options.source_size = .{ .width = upright_width, .height = upright_height };
        }
        var stream: Stream = .init(testing.allocator, options);
        defer stream.deinit();
        const source = if (turned) testSource(sideways, test_width, test_height) else testSource(upright, upright_width, upright_height);
        for (0..12) |index| {
            const status = try stream.push(testing.allocator, source, @as(f64, @floatFromInt(index)) / 30.0);
            try testing.expect(status.detected);
            // The corners are in pixels of the upright frame for the two sources.
            try testing.expectApproxEqAbs(page.tl.x, status.quads[0].tl.x, 3);
            try testing.expectApproxEqAbs(page.br.y, status.quads[0].br.y, 3);
        }
        try stream.finish(testing.allocator);
        const job = stream.takeJob().?;
        try job.run(testing.allocator);
        stream.complete(job, true);
        var pages = stream.pageIterator();
        const first = pages.next().?;
        results[result_count] = try testing.allocator.dupe(u8, first.encoded.jpeg);
        result_count += 1;
    }
    try testing.expectEqualSlices(u8, results[0], results[1]);
}

test "the session measures the frame rate from the times of the frames" {
    var options = test_options;
    options.frames_per_second = 0;
    var video = try TestVideo.init(options);
    defer video.deinit();
    try testing.expectEqual(default_frames_per_second, video.stream.framesPerSecond());
    // The test video has 30 frames in each second.
    try video.show(1, 12, 0);
    try testing.expectApproxEqAbs(@as(f32, 30), video.stream.framesPerSecond(), 0.01);

    // Frame times that go back, or that are no numbers, change nothing and break nothing.
    fillTestFrame(video.buffer, test_width, test_height, test_page, 1);
    const frame = testSource(video.buffer, test_width, test_height);
    _ = try video.stream.push(testing.allocator, frame, -5);
    _ = try video.stream.push(testing.allocator, frame, std.math.nan(f64));
    try testing.expectApproxEqAbs(@as(f32, 30), video.stream.framesPerSecond(), 0.01);
    // A time in a wrong unit gives a rate at the limit, and no frame count that fits no integer.
    _ = try video.stream.push(testing.allocator, frame, 1e-12);
    _ = try video.stream.push(testing.allocator, frame, 0.3999999 + 1e-9);
    try testing.expect(video.stream.framesPerSecond() <= max_frames_per_second);
    try video.stream.finish(testing.allocator);
    _ = try video.runJobs();
}

test "a frame of another size is an error" {
    var video = try TestVideo.init(test_options);
    defer video.deinit();
    const small: [image.packedFrameSize(4, 4)]u8 = @splat(0);
    const frame = testSource(&small, 4, 4);
    try testing.expectError(error.InvalidFrame, video.stream.push(testing.allocator, frame, 0));
}

// endregion: tests
