//! Straight lines in the steps of a picture.
//!
//! Each pixel with a step votes for the lines through it that go across the
//! direction of its step. This is the Hough transform of R. O. Duda and P. E. Hart,
//! "Use of the Hough transformation to detect lines and curves in pictures",
//! Communications of the ACM 15, 1972, with the use of the direction of the
//! gradient of F. O'Gorman and M. B. Clowes, "Finding picture edges through
//! collinearity of feature points", IEEE Transactions on Computers C-25, 1976. The
//! lines with the most votes are the result. Each line is then fitted to the
//! steps near it, because the table of the votes has whole degrees and whole
//! pixels. Each line knows where along its length the picture has a step that
//! fits it: a gap in an edge does not hide the edge, but the gap can be measured.
//!
//! A coordinate is in pixels of the picture of the steps.

const std = @import("std");
const geometry = @import("geometry.zig");

const Allocator = std.mem.Allocator;
const Point = geometry.Point;

/// The number of directions of a step or of the normal of a line: one for each
/// whole degree of a half turn.
pub const angle_count = 180;

/// The steps of a picture: at each pixel, how strong the change is and which way
/// it goes.
pub const Steps = struct {
    width: u32,
    height: u32,
    /// The strength of the step, in codes for one pixel.
    strength: []const f32,
    /// The direction of the step in whole degrees, 0 to 179. 0 is a change from
    /// the left to the right, as on an edge that goes from the top to the bottom.
    /// 90 is a change from the top to the bottom.
    angle: []const u8,
};

pub const Options = struct {
    /// The largest number of lines in the result.
    max_lines: u32 = 24,
    /// A line needs this many votes. One pixel gives the strength of its step as
    /// votes, so this is a length in pixels times a strength.
    min_votes: f32,
    /// A pixel votes for the lines within this many degrees of the direction of
    /// its step. The direction of the step has the full vote, and the vote goes
    /// down to zero one degree past this limit.
    vote_spread_degrees: u8 = 2,
    /// A step below this strength has no vote.
    min_vote_strength: f32 = 3.0,
    /// A step has at most this many votes: one strong edge must not hide the
    /// weak ones.
    max_vote_strength: f32 = 20.0,
    /// Two lines nearer than this, in degrees and in pixels, are one line.
    merge_degrees: u8 = 5,
    merge_distance: u8 = 6,
    /// A line has support at a place where a step of this strength lies within
    /// `support_distance` pixels of the line, with a direction within
    /// `support_degrees` of the normal of the line.
    support_strength: f32 = 6.0,
    support_distance: u8 = 2,
    support_degrees: u8 = 20,
    /// The line with the most votes is near an edge, but not on it. With this on,
    /// each line of the result is the edge that it came from: see `refined`.
    refine: bool = true,
    /// The candidates for that edge are the lines within this many degrees and
    /// pixels of the line with the most votes. 0 degrees leaves only the fit.
    near_degrees: u8 = 4,
    near_distance: u8 = 6,
    /// An edge ends at this many places in a row with no step.
    run_gap: u8 = 12,
    /// The edge is fitted to the steps within `support_distance` pixels of it,
    /// this many times.
    fit_rounds: u8 = 2,
    /// An edge has this many steps or more.
    min_fit_steps: u32 = 12,
};

/// A line: the points `p` with `p · normal = distance`.
pub const Line = struct {
    /// The direction of the normal in whole degrees, 0 to 179: `radians` as the
    /// nearest whole degree. For a comparison of two directions.
    degrees: u8,
    /// The direction of the normal, from 0 to pi.
    radians: f32,
    /// The distance of the line from the origin along the normal. It is negative
    /// for a line on the other side of the origin.
    distance: f32,
    votes: f32,

    /// A line with a normal at a whole degree.
    pub fn init(degrees: u8, distance: f32, votes: f32) Line {
        return .{
            .degrees = degrees,
            .radians = std.math.degreesToRadians(@as(f32, @floatFromInt(degrees))),
            .distance = distance,
            .votes = votes,
        };
    }

    pub fn normal(self: Line) Point {
        return .{ .x = @cos(self.radians), .y = @sin(self.radians) };
    }

    /// The direction along the line.
    pub fn along(self: Line) Point {
        return self.normal().perpendicular();
    }

    pub fn asGeometry(self: Line) geometry.Line {
        const n = self.normal();
        return .{ .a = n.x, .b = n.y, .c = -self.distance };
    }
};

/// The smallest angle between two directions of a half turn, in degrees.
pub fn angleBetween(a: u8, b: u8) u8 {
    const difference = if (a > b) a - b else b - a;
    return @min(difference, angle_count - difference);
}

pub const Lines = struct {
    /// The lines, the one with the most votes first.
    items: []Line,
    /// The number of lines that the memory of `items` has room for.
    capacity: usize,
    /// One row for each line. The entry `k + 1` of a row is the number of places
    /// with support among the first `k + 1` places of the line. A place is one
    /// pixel along the line, and the place `reach` is the point of the line that
    /// is nearest to the origin.
    sums: []u32,
    /// The largest distance of a pixel from the origin, in whole pixels.
    reach: u32,

    pub fn deinit(self: Lines, allocator: Allocator) void {
        allocator.free(self.items.ptr[0..self.capacity]);
        allocator.free(self.sums);
    }

    fn rowLength(self: Lines) usize {
        return 2 * @as(usize, self.reach) + 2;
    }

    /// The part of the segment between two points of the line `index` that has
    /// support, from 0 to 1.
    pub fn support(self: Lines, index: usize, a: Point, b: Point) f32 {
        const direction = self.items[index].along();
        const first = a.dot(direction);
        const second = b.dot(direction);
        const reach: f32 = @floatFromInt(self.reach);
        const last: f32 = @floatFromInt(self.rowLength() - 1);
        const low: usize = @intFromFloat(std.math.clamp(@round(@min(first, second)) + reach, 0, last));
        const high: usize = @intFromFloat(std.math.clamp(@round(@max(first, second)) + reach + 1, 0, last));
        if (high <= low) return 0;
        const row = self.sums[index * self.rowLength() ..][0..self.rowLength()];
        return @as(f32, @floatFromInt(row[high] - row[low])) / @as(f32, @floatFromInt(high - low));
    }
};

/// The votes of all lines. A row is one direction of the normal, and a column is
/// one distance from the middle of the picture, in whole pixels, plus `offset`.
///
/// The distance is from the middle and not from the origin: a small change of the
/// direction then moves a line of the picture by a small distance only, and the
/// votes of one edge stay in some cells that lie side by side.
const Votes = struct {
    data: []f32,
    columns: usize,
    offset: i32,

    /// The votes of a line, also for a direction past the two ends of the table:
    /// the direction `d + 180` with the distance `r` is the line of the direction
    /// `d` with the distance `-r`.
    fn at(self: Votes, direction: i32, column: i32) f32 {
        const index = self.cell(direction, column) orelse return 0;
        return self.data[index];
    }

    /// The index of a line in `data`, or null for a distance outside the table.
    fn cell(self: Votes, direction: i32, column: i32) ?usize {
        var row = direction;
        var mirrored = column;
        if (row < 0 or row >= angle_count) {
            row = @mod(row, angle_count);
            mirrored = 2 * self.offset - column;
        }
        if (mirrored < 0 or mirrored >= @as(i32, @intCast(self.columns))) return null;
        return @as(usize, @intCast(row)) * self.columns + @as(usize, @intCast(mirrored));
    }
};

/// The sides of the square of cells that the smoothed votes of one cell come from.
const smooth_half_width = 1;
const smooth_cells = (2 * smooth_half_width + 1) * (2 * smooth_half_width + 1);

/// Find the straight lines of a picture from its steps. The caller frees the
/// result with `deinit`.
pub fn find(allocator: Allocator, steps: Steps, options: Options) Allocator.Error!Lines {
    const width: usize = steps.width;
    const height: usize = steps.height;
    const diagonal = @sqrt(@as(f32, @floatFromInt(width * width + height * height)));
    const reach: u32 = @intFromFloat(@ceil(diagonal));
    const middle_x = 0.5 * @as(f32, @floatFromInt(width -| 1));
    const middle_y = 0.5 * @as(f32, @floatFromInt(height -| 1));
    // No pixel is farther from the middle than half the diagonal.
    const offset: i32 = @as(i32, @intFromFloat(@ceil(0.5 * diagonal))) + 1;
    const columns: usize = 2 * @as(usize, @intCast(offset)) + 1;

    var cosines: [angle_count]f32 = undefined;
    var sines: [angle_count]f32 = undefined;
    for (&cosines, &sines, 0..) |*cosine, *sine, degrees| {
        const radians = std.math.degreesToRadians(@as(f32, @floatFromInt(degrees)));
        cosine.* = @cos(radians);
        sine.* = @sin(radians);
    }

    const raw: Votes = .{ .data = try allocator.alloc(f32, angle_count * columns), .columns = columns, .offset = offset };
    defer allocator.free(raw.data);
    @memset(raw.data, 0);
    const spread: i32 = options.vote_spread_degrees;
    for (0..height) |y| {
        const strengths = steps.strength[y * width ..][0..width];
        const angles = steps.angle[y * width ..][0..width];
        const fy = @as(f32, @floatFromInt(y)) - middle_y;
        for (strengths, angles, 0..) |strength, angle, x| {
            if (!(strength > options.min_vote_strength)) continue;
            const weight = @min(strength, options.max_vote_strength);
            const fx = @as(f32, @floatFromInt(x)) - middle_x;
            var shift: i32 = -spread;
            while (shift <= spread) : (shift += 1) {
                const direction: usize = @intCast(@mod(@as(i32, angle) + shift, angle_count));
                const distance = fx * cosines[direction] + fy * sines[direction];
                const column: usize = @intCast(@as(i32, @intFromFloat(@round(distance))) + offset);
                // The direction of the step has the full vote, and the directions
                // next to it have less: the line with the most votes then has
                // the direction of its steps.
                const nearness = @as(f32, @floatFromInt(spread + 1 - @as(i32, @intCast(@abs(shift))))) / @as(f32, @floatFromInt(spread + 1));
                raw.data[direction * columns + column] += weight * nearness;
            }
        }
    }

    // A line of the picture is never exact: its votes go to some cells that lie
    // side by side. The sum of a small square of cells is the measure of a line.
    const votes: Votes = .{ .data = try allocator.alloc(f32, angle_count * columns), .columns = columns, .offset = offset };
    defer allocator.free(votes.data);
    for (0..angle_count) |direction| {
        for (0..columns) |column| {
            var sum: f32 = 0;
            var d: i32 = -smooth_half_width;
            while (d <= smooth_half_width) : (d += 1) {
                var c: i32 = -smooth_half_width;
                while (c <= smooth_half_width) : (c += 1) {
                    sum += raw.at(@as(i32, @intCast(direction)) + d, @as(i32, @intCast(column)) + c);
                }
            }
            votes.data[direction * columns + column] = sum / smooth_cells;
        }
    }

    std.debug.assert(options.max_lines > 0);
    const items = try allocator.alloc(Line, options.max_lines);
    errdefer allocator.free(items);
    var count: usize = 0;
    for (0..angle_count) |direction| {
        for (0..columns) |column| {
            const own = direction * columns + column;
            const value = votes.data[own];
            if (!(value >= options.min_votes)) continue;
            if (!isPeak(votes, @intCast(direction), @intCast(column), options)) continue;
            // Keep the lines in the order of their votes.
            if (count == items.len and value <= items[count - 1].votes) continue;
            var place = @min(count, items.len - 1);
            while (place > 0 and items[place - 1].votes < value) : (place -= 1) items[place] = items[place - 1];
            const from_middle: f32 = @floatFromInt(@as(i32, @intCast(column)) - offset);
            items[place] = .init(
                @intCast(direction),
                from_middle + middle_x * cosines[direction] + middle_y * sines[direction],
                value,
            );
            count = @min(count + 1, items.len);
        }
    }
    if (options.refine and count > 0) {
        const workspace = try Workspace.init(allocator, reach, options);
        defer workspace.deinit(allocator);
        for (items[0..count]) |*line| line.* = refined(line.*, steps, reach, workspace, options);
    }

    var result: Lines = .{ .items = items[0..count], .capacity = items.len, .sums = &.{}, .reach = reach };
    const row_length = result.rowLength();
    const sums = try allocator.alloc(u32, count * row_length);
    for (result.items, 0..) |line, index| {
        fillSupport(sums[index * row_length ..][0..row_length], line, steps, reach, options);
    }
    result.sums = sums;
    return result;
}

/// True when no line near this one has more votes. Of two lines with the same
/// votes, the first one in the table is the peak.
fn isPeak(votes: Votes, direction: i32, column: i32, options: Options) bool {
    const own = votes.cell(direction, column).?;
    const value = votes.data[own];
    var d: i32 = -@as(i32, options.merge_degrees);
    while (d <= options.merge_degrees) : (d += 1) {
        var c: i32 = -@as(i32, options.merge_distance);
        while (c <= options.merge_distance) : (c += 1) {
            const other = votes.cell(direction + d, column + c) orelse continue;
            if (other == own) continue;
            const neighbour = votes.data[other];
            if (neighbour > value or (neighbour == value and other < own)) return false;
        }
    }
    return true;
}

/// The working memory of `refined`, for one picture.
const Workspace = struct {
    /// One step near a line.
    const Step = struct {
        /// The index of the pixel in the picture.
        pixel: u32,
        /// The place of the step along the line, from 0 for the place `-reach`.
        place: u32,
    };

    steps: []Step,
    /// One bit for each place along a line, for each candidate line.
    places: []u64,
    /// The number of steps at each place along a line.
    occupied: []u16,

    /// The candidates have a direction each this many degrees.
    const near_step_degrees = 0.5;
    const word_bits = 64;

    fn init(allocator: Allocator, reach: u32, options: Options) Allocator.Error!Workspace {
        const place_count = 2 * @as(usize, reach) + 1;
        const steps = try allocator.alloc(Step, place_count * distanceCount(options));
        errdefer allocator.free(steps);
        const places = try allocator.alloc(u64, directionCount(options) * distanceCount(options) * rowWords(reach));
        errdefer allocator.free(places);
        const occupied = try allocator.alloc(u16, place_count);
        return .{ .steps = steps, .places = places, .occupied = occupied };
    }

    fn deinit(self: Workspace, allocator: Allocator) void {
        allocator.free(self.steps);
        allocator.free(self.places);
        allocator.free(self.occupied);
    }

    fn directionCount(options: Options) usize {
        return 2 * @as(usize, @intFromFloat(@as(f32, @floatFromInt(options.near_degrees)) / near_step_degrees)) + 1;
    }

    fn distanceCount(options: Options) usize {
        return 2 * @as(usize, options.near_distance) + 1;
    }

    /// The words of one candidate: one bit for each place.
    fn rowWords(reach: u32) usize {
        return (2 * @as(usize, reach) + 1 + word_bits - 1) / word_bits;
    }
};

/// The edge that `line` came from, as a line. `line` is the top of a hill of
/// votes, and it is near an edge but not on it:
///
/// - The table has whole degrees and whole pixels, and the votes of a short edge
///   make a flat hill. The top moves by some degrees from one frame to the next.
/// - The votes say how strong the steps of an edge are, not how long the edge is.
///   Two edges that meet at a small angle make one hill, with its top between
///   the two or on the edge with more contrast. The side of a page is the long
///   edge.
///
/// The function takes the steps near `line` that give it support (see
/// `Options.support_strength`), and of those only the longest run along the
/// line: a second thing in line with the edge, farther away, is not a part of
/// it. Of the candidate lines near `line`, it takes the one with steps along the
/// most places. Then it fits that line to the steps on it, with the least
/// squares of the distances across the line.
fn refined(line: Line, steps: Steps, reach: u32, workspace: Workspace, options: Options) Line {
    const band: i32 = options.near_distance;
    const width: f32 = @floatFromInt(steps.width);
    const height: f32 = @floatFromInt(steps.height);
    const normal = line.normal();
    const along = line.along();
    const place_count = 2 * @as(usize, reach) + 1;

    // The steps near the line, and how many of them each place has.
    var step_count: usize = 0;
    @memset(workspace.occupied, 0);
    for (0..place_count) |place| {
        const position = @as(f32, @floatFromInt(place)) - @as(f32, @floatFromInt(reach));
        var shift: i32 = -band;
        while (shift <= band) : (shift += 1) {
            const across = line.distance + @as(f32, @floatFromInt(shift));
            const x = @round(across * normal.x + position * along.x);
            const y = @round(across * normal.y + position * along.y);
            if (x < 0 or y < 0 or x >= width or y >= height) continue;
            const pixel = @as(usize, @intFromFloat(y)) * steps.width + @as(usize, @intFromFloat(x));
            if (!(steps.strength[pixel] > options.support_strength)) continue;
            if (angleBetween(steps.angle[pixel], line.degrees) >= options.support_degrees) continue;
            workspace.steps[step_count] = .{ .pixel = @intCast(pixel), .place = @intCast(place) };
            step_count += 1;
            workspace.occupied[place] += 1;
        }
    }

    // The run of places with the most steps. A run ends at `run_gap` places with
    // no step.
    var best_first: usize = 0;
    var best_last: usize = 0;
    var best_steps: u32 = 0;
    var run_first: usize = 0;
    var run_steps: u32 = 0;
    var empty: u32 = options.run_gap;
    for (workspace.occupied, 0..) |count, place| {
        if (count == 0) {
            empty += 1;
            continue;
        }
        if (empty >= options.run_gap) {
            run_first = place;
            run_steps = 0;
        }
        empty = 0;
        run_steps += count;
        if (run_steps > best_steps) {
            best_steps = run_steps;
            best_first = run_first;
            best_last = place;
        }
    }
    if (best_steps < options.min_fit_steps) return line;

    // Only the steps of that run stay. Their middle is where the candidates turn.
    var kept: usize = 0;
    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    for (workspace.steps[0..step_count]) |step| {
        if (step.place < best_first or step.place > best_last) continue;
        workspace.steps[kept] = step;
        kept += 1;
        sum_x += @floatFromInt(step.pixel % steps.width);
        sum_y += @floatFromInt(step.pixel / steps.width);
    }
    const run = workspace.steps[0..kept];
    const middle = Point.init(@floatCast(sum_x / @as(f64, @floatFromInt(kept))), @floatCast(sum_y / @as(f64, @floatFromInt(kept))));

    var best = line;
    if (options.near_degrees > 0) best = longestCandidate(line, steps, reach, workspace, run, middle, options);
    for (0..options.fit_rounds) |_| best = fittedToSteps(best, steps, run, options) orelse break;
    return best;
}

/// Of the lines near `line` that turn around `middle`, the one with steps of
/// `run` along the most places. A place counts when a step lies on the candidate
/// or one pixel to a side of it.
fn longestCandidate(
    line: Line,
    steps: Steps,
    reach: u32,
    workspace: Workspace,
    run: []const Workspace.Step,
    middle: Point,
    options: Options,
) Line {
    const directions = Workspace.directionCount(options);
    const distances = Workspace.distanceCount(options);
    const row_words = Workspace.rowWords(reach);
    const band: i32 = options.near_distance;
    const half_directions: i32 = @intCast(directions / 2);
    const last_bit: i32 = 2 * @as(i32, @intCast(reach));

    @memset(workspace.places, 0);
    for (0..directions) |direction| {
        const turn = std.math.degreesToRadians(@as(f32, @floatFromInt(@as(i32, @intCast(direction)) - half_directions)) * Workspace.near_step_degrees);
        const candidate_normal = Point.init(@cos(line.radians + turn), @sin(line.radians + turn));
        const candidate_along = candidate_normal.perpendicular();
        for (run) |step| {
            const from_middle = Point.init(@floatFromInt(step.pixel % steps.width), @floatFromInt(step.pixel / steps.width)).sub(middle);
            const across: i32 = @intFromFloat(@round(from_middle.dot(candidate_normal)));
            if (across < -band or across > band) continue;
            const position: i32 = @intFromFloat(@round(from_middle.dot(candidate_along)));
            const bit: usize = @intCast(std.math.clamp(position + @as(i32, @intCast(reach)), 0, last_bit));
            const row = (direction * distances + @as(usize, @intCast(across + band))) * row_words;
            workspace.places[row + bit / Workspace.word_bits] |= @as(u64, 1) << @intCast(bit % Workspace.word_bits);
        }
    }

    var best_count: u32 = 0;
    var best_direction: usize = directions / 2;
    var best_distance: usize = distances / 2;
    var best_offset: u64 = std.math.maxInt(u64);
    for (0..directions) |direction| {
        for (0..distances) |distance| {
            var place_count: u32 = 0;
            const row = (direction * distances + distance) * row_words;
            for (0..row_words) |word| {
                var bits = workspace.places[row + word];
                if (distance > 0) bits |= workspace.places[row - row_words + word];
                if (distance + 1 < distances) bits |= workspace.places[row + row_words + word];
                place_count += @popCount(bits);
            }
            // Of two candidates with the same count, the one nearer to `line` wins.
            const offset = @abs(@as(i64, @intCast(direction)) - half_directions) + @abs(@as(i64, @intCast(distance)) - band);
            if (place_count > best_count or (place_count == best_count and offset < best_offset)) {
                best_count = place_count;
                best_direction = direction;
                best_distance = distance;
                best_offset = offset;
            }
        }
    }
    const turn = std.math.degreesToRadians(@as(f32, @floatFromInt(@as(i32, @intCast(best_direction)) - half_directions)) * Workspace.near_step_degrees);
    return lineAt(line.radians + turn, middle, @floatFromInt(@as(i32, @intCast(best_distance)) - band), line.votes);
}

/// The line with the normal direction `radians` (any angle) at the distance
/// `across` from the point `through`, along that normal.
fn lineAt(radians: f32, through: Point, across: f32, votes: f32) Line {
    // The normal of a line has a direction from 0 to pi.
    const turned = @mod(radians, 2 * std.math.pi);
    const flipped = turned >= std.math.pi;
    const direction = if (flipped) turned - std.math.pi else turned;
    const normal = Point.init(@cos(direction), @sin(direction));
    const degrees: u32 = @intFromFloat(@round(std.math.radiansToDegrees(direction)));
    return .{
        .degrees = @intCast(degrees % angle_count),
        .radians = direction,
        .distance = through.dot(normal) + (if (flipped) -across else across),
        .votes = votes,
    };
}

/// The line through the steps of `run` within `support_distance` pixels of
/// `line`: a least-squares fit, with the distance across the line as the error
/// and the strength of a step as its weight. Null with too few steps.
fn fittedToSteps(line: Line, steps: Steps, run: []const Workspace.Step, options: Options) ?Line {
    const normal = line.normal();
    const limit: f32 = @floatFromInt(options.support_distance);
    var count: u32 = 0;
    var weight_sum: f64 = 0;
    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    var sum_xx: f64 = 0;
    var sum_xy: f64 = 0;
    var sum_yy: f64 = 0;
    for (run) |step| {
        const x: f32 = @floatFromInt(step.pixel % steps.width);
        const y: f32 = @floatFromInt(step.pixel / steps.width);
        if (@abs(x * normal.x + y * normal.y - line.distance) > limit) continue;
        const weight: f64 = @min(steps.strength[step.pixel], options.max_vote_strength);
        count += 1;
        weight_sum += weight;
        sum_x += weight * x;
        sum_y += weight * y;
        sum_xx += weight * x * x;
        sum_xy += weight * x * y;
        sum_yy += weight * y * y;
    }
    if (count < options.min_fit_steps) return null;
    const mean_x = sum_x / weight_sum;
    const mean_y = sum_y / weight_sum;
    const spread_xx = sum_xx / weight_sum - mean_x * mean_x;
    const spread_xy = sum_xy / weight_sum - mean_x * mean_y;
    const spread_yy = sum_yy / weight_sum - mean_y * mean_y;
    // The direction in which the steps spread most is the direction of the line.
    const along_radians = 0.5 * std.math.atan2(2 * spread_xy, spread_xx - spread_yy);
    return lineAt(@floatCast(along_radians + 0.5 * std.math.pi), Point.init(@floatCast(mean_x), @floatCast(mean_y)), 0, line.votes);
}

/// Write the running count of the places with support of one line into `row`.
fn fillSupport(row: []u32, line: Line, steps: Steps, reach: u32, options: Options) void {
    const normal = line.normal();
    const direction = line.along();
    const width: f32 = @floatFromInt(steps.width);
    const height: f32 = @floatFromInt(steps.height);
    row[0] = 0;
    for (0..row.len - 1) |place| {
        const position = @as(f32, @floatFromInt(place)) - @as(f32, @floatFromInt(reach));
        var supported = false;
        var shift: i32 = -@as(i32, options.support_distance);
        while (shift <= options.support_distance and !supported) : (shift += 1) {
            const across = line.distance + @as(f32, @floatFromInt(shift));
            const x = @round(across * normal.x + position * direction.x);
            const y = @round(across * normal.y + position * direction.y);
            if (x < 0 or y < 0 or x >= width or y >= height) continue;
            const index = @as(usize, @intFromFloat(y)) * steps.width + @as(usize, @intFromFloat(x));
            supported = steps.strength[index] > options.support_strength and
                angleBetween(steps.angle[index], line.degrees) < options.support_degrees;
        }
        row[place + 1] = row[place] + @intFromBool(supported);
    }
}

// region: tests

const testing = std.testing;
const alloc_check = @import("alloc_check.zig");

/// The steps of a picture of 160 x 120 pixels with the outline of a rectangle:
/// the left side has a gap.
const TestSteps = struct {
    strength: []f32,
    angle: []u8,
    steps: Steps,

    const width = 160;
    const height = 120;
    const left = 40;
    const right = 110;
    const top = 30;
    const bottom = 90;
    const gap_first = 50;
    const gap_last = 64;
    const edge_strength = 12.0;

    fn init(allocator: Allocator) !TestSteps {
        const strength = try allocator.alloc(f32, width * height);
        errdefer allocator.free(strength);
        const angle = try allocator.alloc(u8, width * height);
        @memset(strength, 0);
        @memset(angle, 0);
        for (top..bottom + 1) |y| {
            for ([_]usize{ left, right }) |x| {
                if (x == left and y >= gap_first and y <= gap_last) continue;
                strength[y * width + x] = edge_strength;
                angle[y * width + x] = 0;
            }
        }
        for (left..right + 1) |x| {
            for ([_]usize{ top, bottom }) |y| {
                strength[y * width + x] = edge_strength;
                angle[y * width + x] = 90;
            }
        }
        return .{
            .strength = strength,
            .angle = angle,
            .steps = .{ .width = width, .height = height, .strength = strength, .angle = angle },
        };
    }

    fn deinit(self: TestSteps, allocator: Allocator) void {
        allocator.free(self.strength);
        allocator.free(self.angle);
    }

    /// The index of the line with about a direction and a distance, or null.
    fn lineAt(found: Lines, degrees: u8, distance: f32) ?usize {
        for (found.items, 0..) |line, index| {
            if (angleBetween(line.degrees, degrees) <= 1 and @abs(line.distance - distance) <= 2) return index;
        }
        return null;
    }
};

const test_options: Options = .{ .min_votes = 100 };

test "the four sides of a rectangle are the four lines" {
    const picture = try TestSteps.init(testing.allocator);
    defer picture.deinit(testing.allocator);
    const found = try find(testing.allocator, picture.steps, test_options);
    defer found.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), found.items.len);
    try testing.expect(TestSteps.lineAt(found, 0, TestSteps.left) != null);
    try testing.expect(TestSteps.lineAt(found, 0, TestSteps.right) != null);
    try testing.expect(TestSteps.lineAt(found, 90, TestSteps.top) != null);
    try testing.expect(TestSteps.lineAt(found, 90, TestSteps.bottom) != null);
    // The lines come in the order of their votes: a long side first.
    try testing.expect(angleBetween(found.items[0].degrees, 90) <= 1);
    try testing.expect(found.items[0].votes >= found.items[3].votes);
}

test "the support of a line is the part of a segment with steps" {
    const picture = try TestSteps.init(testing.allocator);
    defer picture.deinit(testing.allocator);
    const found = try find(testing.allocator, picture.steps, test_options);
    defer found.deinit(testing.allocator);

    const right = TestSteps.lineAt(found, 0, TestSteps.right).?;
    // The two pixels at the corners have the direction of the other side.
    const whole = found.support(right, Point.init(TestSteps.right, TestSteps.top), Point.init(TestSteps.right, TestSteps.bottom));
    try testing.expect(whole > 0.95);
    // The order of the two points does not change the result.
    try testing.expectEqual(whole, found.support(right, Point.init(TestSteps.right, TestSteps.bottom), Point.init(TestSteps.right, TestSteps.top)));
    // Past the corner, the line has no steps.
    const past = found.support(right, Point.init(TestSteps.right, TestSteps.bottom + 5), Point.init(TestSteps.right, TestSteps.bottom + 25));
    try testing.expectEqual(@as(f32, 0), past);

    // The left side has a gap of 15 of its 61 pixels.
    const left = TestSteps.lineAt(found, 0, TestSteps.left).?;
    const with_gap = found.support(left, Point.init(TestSteps.left, TestSteps.top), Point.init(TestSteps.left, TestSteps.bottom));
    try testing.expectApproxEqAbs(@as(f32, 46.0 / 61.0), with_gap, 0.04);
}

test "a line with a normal near the end of the table is one line" {
    // An edge with the direction 179: one degree from an edge that goes from the
    // top to the bottom. Its votes go to the directions 177 to 179, 0, and 1.
    const width = 120;
    const height = 120;
    const strength = try testing.allocator.alloc(f32, width * height);
    defer testing.allocator.free(strength);
    const angle = try testing.allocator.alloc(u8, width * height);
    defer testing.allocator.free(angle);
    @memset(strength, 0);
    @memset(angle, 0);
    const normal = Line.init(179, 0, 0).normal();
    for (10..110) |y| {
        // The points with `p · normal = -60`.
        const x = (-60.0 - @as(f32, @floatFromInt(y)) * normal.y) / normal.x;
        const index = y * width + @as(usize, @intFromFloat(@round(x)));
        strength[index] = 12;
        angle[index] = 179;
    }
    const found = try find(testing.allocator, .{ .width = width, .height = height, .strength = strength, .angle = angle }, test_options);
    defer found.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expect(angleBetween(found.items[0].degrees, 179) <= 1);
    try testing.expectApproxEqAbs(@as(f32, 60), @abs(found.items[0].distance), 2);
}

test "a line is fitted to its steps: a direction between two whole degrees" {
    // An edge with a slope of 0.21: its normal has 101.86 degrees.
    const width = 200;
    const height = 150;
    const slope = 0.21;
    const strength = try testing.allocator.alloc(f32, width * height);
    defer testing.allocator.free(strength);
    const angle = try testing.allocator.alloc(u8, width * height);
    defer testing.allocator.free(angle);
    @memset(strength, 0);
    @memset(angle, 0);
    const first = Point.init(30, 40);
    const last = Point.init(170, 40 + slope * 140);
    for (30..171) |x| {
        const y: usize = @intFromFloat(@round(first.y + slope * (@as(f32, @floatFromInt(x)) - first.x)));
        strength[y * width + x] = 12;
        angle[y * width + x] = 102;
    }
    const steps: Steps = .{ .width = width, .height = height, .strength = strength, .angle = angle };
    const true_degrees = 90.0 + std.math.radiansToDegrees(std.math.atan(@as(f32, slope)));

    const found = try find(testing.allocator, steps, test_options);
    defer found.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), found.items.len);
    try testing.expectApproxEqAbs(true_degrees, std.math.radiansToDegrees(found.items[0].radians), 0.2);
    try testing.expectEqual(@as(u8, 102), found.items[0].degrees);
    // The two ends of the edge lie on the line.
    const line = found.items[0].asGeometry();
    try testing.expect(@abs(line.signedDistance(first)) < 0.6);
    try testing.expect(@abs(line.signedDistance(last)) < 0.6);
    try testing.expect(found.support(0, first, last) > 0.95);

    // With no fit, the line has the direction of a cell of the table.
    var no_fit = test_options;
    no_fit.refine = false;
    const coarse = try find(testing.allocator, steps, no_fit);
    defer coarse.deinit(testing.allocator);
    const coarse_degrees = std.math.radiansToDegrees(coarse.items[0].radians);
    try testing.expectEqual(@round(coarse_degrees), coarse_degrees);
}

/// A picture of steps for a test of the edge of a line: the caller draws edges.
const EdgePicture = struct {
    strength: []f32,
    angle: []u8,

    const width = 240;
    const height = 180;

    fn init() !EdgePicture {
        const strength = try testing.allocator.alloc(f32, width * height);
        errdefer testing.allocator.free(strength);
        const angle = try testing.allocator.alloc(u8, width * height);
        @memset(strength, 0);
        @memset(angle, 0);
        return .{ .strength = strength, .angle = angle };
    }

    fn deinit(self: EdgePicture) void {
        testing.allocator.free(self.strength);
        testing.allocator.free(self.angle);
    }

    fn steps(self: EdgePicture) Steps {
        return .{ .width = width, .height = height, .strength = self.strength, .angle = self.angle };
    }

    /// An edge from `from` to `to`, one pixel for each column, with the direction
    /// of its normal in whole degrees.
    fn draw(self: EdgePicture, from: Point, to: Point, strength: f32) void {
        const slope = (to.y - from.y) / (to.x - from.x);
        const degrees: u8 = @intFromFloat(@round(90.0 + std.math.radiansToDegrees(std.math.atan(slope))));
        var x = from.x;
        while (x <= to.x) : (x += 1) {
            const y = @round(from.y + slope * (x - from.x));
            const index = @as(usize, @intFromFloat(y)) * width + @as(usize, @intFromFloat(x));
            self.strength[index] = strength;
            self.angle[index] = degrees;
        }
    }
};

test "of two edges that meet at a small angle, the line is the long edge" {
    const picture = try EdgePicture.init();
    defer picture.deinit();
    // A long edge with little contrast, and a short edge with much contrast that
    // leaves it at 3 degrees: the two make one hill of votes.
    const start = Point.init(40, 60);
    const long_end = Point.init(200, 60 + 160 * @tan(std.math.degreesToRadians(10.0)));
    const short_end = Point.init(120, 60 + 80 * @tan(std.math.degreesToRadians(13.0)));
    picture.draw(start, long_end, 7);
    picture.draw(start, short_end, 20);

    const found = try find(testing.allocator, picture.steps(), test_options);
    defer found.deinit(testing.allocator);
    try testing.expect(found.items.len >= 1);
    try testing.expectApproxEqAbs(@as(f32, 100.0), std.math.radiansToDegrees(found.items[0].radians), 0.5);
    try testing.expect(found.support(0, start, long_end) > 0.95);

    // The top of the hill of votes alone is not on the long edge.
    var coarse_options = test_options;
    coarse_options.refine = false;
    const coarse = try find(testing.allocator, picture.steps(), coarse_options);
    defer coarse.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 103), coarse.items[0].degrees);
    try testing.expect(coarse.support(0, start, long_end) < 0.7);
}

test "a thing in line with an edge, after a gap, does not turn the line" {
    const picture = try EdgePicture.init();
    defer picture.deinit();
    // An edge, then 40 pixels with no step, then a second edge 4 pixels lower.
    const start = Point.init(30, 80);
    const end = Point.init(130, 80 + 100 * @tan(std.math.degreesToRadians(5.0)));
    picture.draw(start, end, 12);
    picture.draw(Point.init(170, end.y + 7.5), Point.init(220, end.y + 7.5 + 50 * @tan(std.math.degreesToRadians(5.0))), 12);

    const found = try find(testing.allocator, picture.steps(), test_options);
    defer found.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, 95.0), std.math.radiansToDegrees(found.items[0].radians), 0.5);
    const line = found.items[0].asGeometry();
    try testing.expect(@abs(line.signedDistance(start)) < 1);
    try testing.expect(@abs(line.signedDistance(end)) < 1);
}

test "the angle between two directions is at most a quarter turn" {
    try testing.expectEqual(@as(u8, 0), angleBetween(10, 10));
    try testing.expectEqual(@as(u8, 20), angleBetween(10, 30));
    try testing.expectEqual(@as(u8, 2), angleBetween(179, 1));
    try testing.expectEqual(@as(u8, 90), angleBetween(0, 90));
}

test "a picture with no steps has no lines" {
    const strength: [40 * 30]f32 = @splat(0);
    const angle: [40 * 30]u8 = @splat(0);
    const found = try find(testing.allocator, .{ .width = 40, .height = 30, .strength = &strength, .angle = &angle }, test_options);
    defer found.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), found.items.len);
}

test "the line search frees its memory when an allocation fails" {
    const picture = try TestSteps.init(testing.allocator);
    defer picture.deinit(testing.allocator);
    const Check = struct {
        fn run(allocator: Allocator, steps: Steps) !void {
            const found = try find(allocator, steps, test_options);
            defer found.deinit(allocator);
            try testing.expectEqual(@as(usize, 4), found.items.len);
        }
    };
    try alloc_check.eachFailure(testing.allocator, Check.run, .{picture.steps});
}

// endregion: tests
