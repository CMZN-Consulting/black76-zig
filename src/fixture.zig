//! Reference reader for `vectors/black76-golden.ndjson`.
//!
//! Shipped as part of the library, not hidden in the test, because anyone
//! porting this kernel to another language has to read the file first and
//! should not have to reverse-engineer the format from a test.
//!
//! The format is deliberately boring: one JSON object per line, every f64 held
//! as its 64-bit pattern in "0x%016X" form. Parsing it needs no JSON library --
//! find the key, take the next 16 hex digits. That is the point. A fixture you
//! need a dependency to read is a fixture people stop checking.
//!
//! Memory: this module never allocates on its own. `parseInto` fills a
//! caller-owned buffer; `parseAlloc` takes an explicit allocator, reads the
//! vector count from the header, and allocates exactly that many `Vector`s,
//! once. There is no growth, no arena, and nothing to free but the slice.

const std = @import("std");
const assert = std.debug.assert;
const b76 = @import("black76");

pub const Vector = struct {
    f: f64,
    k: f64,
    s: f64,
    t: f64,
    delta: f64,
    gamma: f64,
    theta: f64,
    vega: f64,
    price: f64,
    /// Group tag. Metadata, never compared. Points into the fixture text.
    g: []const u8,
    /// 1-based line number in the source file, for legible failure messages.
    line_no: u32,
    kind: b76.Kind,

    pub fn input(v: Vector) b76.Input {
        return .{ .forward = v.f, .strike = v.k, .sigma = v.s, .ttm = v.t, .kind = v.kind };
    }

    pub fn expected(v: Vector) b76.Greeks {
        return .{ .delta = v.delta, .gamma = v.gamma, .theta = v.theta, .vega = v.vega, .price = v.price };
    }
};

/// The provenance line. Everything here is EXPECTED to differ between
/// captures except `schema` and `vector_count`; only the vector lines are the
/// contract.
pub const Header = struct {
    schema: []const u8,
    zig_version: []const u8,
    target: []const u8,
    cpu: []const u8,
    optimize: []const u8,
    vector_count: u32,
};

pub const ParseError = error{
    EmptyFixture,
    MissingHeader,
    MissingField,
    TruncatedField,
    NotABool,
    Unterminated,
    Overflow,
    InvalidCharacter,
    /// `parseInto` was given fewer slots than the file has vectors.
    BufferTooSmall,
    /// The header's `vector_count` disagrees with the lines that follow it.
    CountMismatch,
};

/// True for the provenance line. Headers are skipped by every consumer.
pub fn isHeader(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "{\"header\"");
}

pub fn hexField(line: []const u8, comptime key: []const u8) ParseError!f64 {
    const needle = "\"" ++ key ++ "\":\"0x";
    const idx = std.mem.indexOf(u8, line, needle) orelse return error.MissingField;
    const start = idx + needle.len;
    if (start + 16 > line.len) return error.TruncatedField;
    const pattern = try std.fmt.parseInt(u64, line[start..][0..16], 16);
    return @bitCast(pattern);
}

pub fn boolField(line: []const u8, comptime key: []const u8) ParseError!bool {
    const needle = "\"" ++ key ++ "\":";
    const idx = std.mem.indexOf(u8, line, needle) orelse return error.MissingField;
    const rest = line[idx + needle.len ..];
    if (std.mem.startsWith(u8, rest, "true")) return true;
    if (std.mem.startsWith(u8, rest, "false")) return false;
    return error.NotABool;
}

pub fn strField(line: []const u8, comptime key: []const u8) ParseError![]const u8 {
    const needle = "\"" ++ key ++ "\":\"";
    const idx = std.mem.indexOf(u8, line, needle) orelse return error.MissingField;
    const rest = line[idx + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.Unterminated;
    return rest[0..end];
}

pub fn intField(line: []const u8, comptime key: []const u8) ParseError!u64 {
    const needle = "\"" ++ key ++ "\":";
    const idx = std.mem.indexOf(u8, line, needle) orelse return error.MissingField;
    const rest = line[idx + needle.len ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    return std.fmt.parseInt(u64, rest[0..end], 10);
}

/// The header must be the first line of the file.
pub fn parseHeader(text: []const u8) ParseError!Header {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const first = text[0..end];
    if (first.len == 0) return error.EmptyFixture;
    if (!isHeader(first)) return error.MissingHeader;
    const count = try intField(first, "vector_count");
    if (count > std.math.maxInt(u32)) return error.Overflow;
    return .{
        .schema = try strField(first, "schema"),
        .zig_version = try strField(first, "zig_version"),
        .target = try strField(first, "target"),
        .cpu = try strField(first, "cpu"),
        .optimize = try strField(first, "optimize"),
        .vector_count = @intCast(count),
    };
}

pub fn parseLine(line: []const u8, line_no: u32) ParseError!Vector {
    return .{
        .f = try hexField(line, "f"),
        .k = try hexField(line, "k"),
        .s = try hexField(line, "s"),
        .t = try hexField(line, "t"),
        .kind = b76.Kind.fromIsCall(try boolField(line, "c")),
        .delta = try hexField(line, "delta"),
        .gamma = try hexField(line, "gamma"),
        .theta = try hexField(line, "theta"),
        .vega = try hexField(line, "vega"),
        .price = try hexField(line, "price"),
        .g = try strField(line, "g"),
        .line_no = line_no,
    };
}

/// Parse every vector line in `text` into `out`, skipping the header, and
/// return how many were written. The caller owns `out` and sizes it; the
/// header's `vector_count` is the intended size (see `parseHeader`).
///
/// Line numbers are counted with `splitScalar`, not `tokenizeScalar`: tokenize
/// silently swallows empty lines, which would make every "MISMATCH line N"
/// after a blank line point at the wrong row.
pub fn parseInto(text: []const u8, out: []Vector) ParseError!usize {
    var it = std.mem.splitScalar(u8, text, '\n');
    var line_no: u32 = 0;
    var n: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        if (line.len == 0 or isHeader(line)) continue;
        if (n == out.len) return error.BufferTooSmall;
        out[n] = try parseLine(line, line_no);
        n += 1;
    }
    assert(n <= out.len);
    return n;
}

/// Read the header, allocate exactly `vector_count` slots with `gpa`, fill
/// them, and require the count to agree with the file. The caller frees the
/// returned slice with the same allocator.
pub fn parseAlloc(gpa: std.mem.Allocator, text: []const u8) (ParseError || std.mem.Allocator.Error)![]Vector {
    const header = try parseHeader(text);
    const out = try gpa.alloc(Vector, header.vector_count);
    errdefer gpa.free(out);

    const n = try parseInto(text, out);
    if (n != out.len) return error.CountMismatch;
    return out;
}

/// Bit equality, NOT numeric equality. -0.0 is not 0.0 here, and two NaNs with
/// the same payload ARE equal. The comparison deliberately has no opinion about
/// what the numbers mean.
pub fn bitEq(a: f64, b: f64) bool {
    return bits(a) == bits(b);
}

pub fn greeksBitEq(a: b76.Greeks, b: b76.Greeks) bool {
    return bitEq(a.delta, b.delta) and bitEq(a.gamma, b.gamma) and
        bitEq(a.theta, b.theta) and bitEq(a.vega, b.vega) and bitEq(a.price, b.price);
}

pub fn bits(x: f64) u64 {
    return @bitCast(x);
}

test "hex fields round-trip the exact bit pattern, sign of zero included" {
    const line = "{\"f\":\"0x3FE0000000000000\",\"k\":\"0x3FF0000000000000\",\"s\":\"0x3FA999999999999A\",\"t\":\"0x3EE3F33830013F33\",\"c\":true,\"delta\":\"0x0000000000000000\",\"gamma\":\"0x0000000000000000\",\"theta\":\"0x8000000000000000\",\"vega\":\"0x0000000000000000\",\"price\":\"0x0000000000000000\",\"g\":\"grid\",\"_\":\"x\"}";
    const v = try parseLine(line, 2);
    try std.testing.expectEqual(@as(f64, 0.5), v.f);
    try std.testing.expectEqual(@as(f64, 1.0), v.k);
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), bits(v.theta));
    try std.testing.expectEqual(@as(u64, 0), bits(v.gamma));
    try std.testing.expectEqual(b76.Kind.call, v.kind);
    try std.testing.expectEqualStrings("grid", v.g);
    try std.testing.expectEqual(@as(u32, 2), v.line_no);
}

test "parseInto refuses a buffer that is too small, and parseAlloc sizes from the header" {
    const text =
        "{\"header\":1,\"schema\":\"black76-golden/1\",\"zig_version\":\"x\",\"target\":\"x\",\"cpu\":\"x\",\"optimize\":\"x\",\"vector_count\":2}\n" ++
        "{\"f\":\"0x3FE0000000000000\",\"k\":\"0x3FF0000000000000\",\"s\":\"0x3FA999999999999A\",\"t\":\"0x3EE3F33830013F33\",\"c\":true,\"delta\":\"0x0000000000000000\",\"gamma\":\"0x0000000000000000\",\"theta\":\"0x8000000000000000\",\"vega\":\"0x0000000000000000\",\"price\":\"0x0000000000000000\",\"g\":\"grid\",\"_\":\"x\"}\n" ++
        "\n" ++
        "{\"f\":\"0x3FE0000000000000\",\"k\":\"0x3FF0000000000000\",\"s\":\"0x3FA999999999999A\",\"t\":\"0x3EE3F33830013F33\",\"c\":false,\"delta\":\"0x0000000000000000\",\"gamma\":\"0x0000000000000000\",\"theta\":\"0x8000000000000000\",\"vega\":\"0x0000000000000000\",\"price\":\"0x0000000000000000\",\"g\":\"grid\",\"_\":\"x\"}\n";

    var one: [1]Vector = undefined;
    try std.testing.expectError(error.BufferTooSmall, parseInto(text, &one));

    var two: [2]Vector = undefined;
    try std.testing.expectEqual(@as(usize, 2), try parseInto(text, &two));
    try std.testing.expectEqual(@as(u32, 2), two[0].line_no);
    try std.testing.expectEqual(@as(u32, 4), two[1].line_no); // the blank line counts

    const vs = try parseAlloc(std.testing.allocator, text);
    defer std.testing.allocator.free(vs);
    try std.testing.expectEqual(@as(usize, 2), vs.len);
    try std.testing.expectEqual(b76.Kind.put, vs[1].kind);
}
