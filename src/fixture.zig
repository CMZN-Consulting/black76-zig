// fixture.zig -- reference reader for vectors/black76-golden.ndjson.
//
// Shipped as part of the library, not hidden in the test, because anyone
// porting this kernel to another language has to read the file first and
// should not have to reverse-engineer the format from a test.
//
// The format is deliberately boring: one JSON object per line, every f64 held
// as its 64-bit pattern in "0x%016X" form. Parsing it needs no JSON library --
// find the key, take the next 16 hex digits. That is the point. A fixture you
// need a dependency to read is a fixture people stop checking.

const std = @import("std");

pub const Vector = struct {
    f: f64,
    k: f64,
    s: f64,
    t: f64,
    c: bool,
    delta: f64,
    gamma: f64,
    theta: f64,
    vega: f64,
    price: f64,
    /// Group tag. Metadata, never compared.
    g: []const u8,
    /// 1-based line number in the source file, for legible failure messages.
    line_no: usize,
};

pub const ParseError = error{
    MissingField,
    TruncatedField,
    NotABool,
    Unterminated,
    Overflow,
    InvalidCharacter,
};

/// True for the provenance line. Headers are skipped by every consumer: they
/// record which binary produced the numbers, and are EXPECTED to differ between
/// captures. The vector lines are the contract.
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

pub fn parseLine(line: []const u8, line_no: usize) ParseError!Vector {
    return .{
        .f = try hexField(line, "f"),
        .k = try hexField(line, "k"),
        .s = try hexField(line, "s"),
        .t = try hexField(line, "t"),
        .c = try boolField(line, "c"),
        .delta = try hexField(line, "delta"),
        .gamma = try hexField(line, "gamma"),
        .theta = try hexField(line, "theta"),
        .vega = try hexField(line, "vega"),
        .price = try hexField(line, "price"),
        .g = try strField(line, "g"),
        .line_no = line_no,
    };
}

/// Parse every vector line in `text`, skipping the header.
pub fn parseAll(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(Vector) {
    var out: std.ArrayList(Vector) = .empty;
    // splitScalar, not tokenizeScalar: tokenize silently swallows empty lines,
    // which would make every "MISMATCH line N" after a blank line point at the
    // wrong row. A diagnostic that misreports where it looked is worse than no
    // diagnostic.
    var it = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (it.next()) |line| {
        line_no += 1;
        if (line.len == 0 or isHeader(line)) continue;
        try out.append(gpa, try parseLine(line, line_no));
    }
    return out;
}

/// Bit equality, NOT numeric equality. -0.0 is not 0.0 here, and two NaNs with
/// the same payload ARE equal. The comparison deliberately has no opinion about
/// what the numbers mean.
pub fn bitEq(a: f64, b: f64) bool {
    const ba: u64 = @bitCast(a);
    const bb: u64 = @bitCast(b);
    return ba == bb;
}

pub fn bits(x: f64) u64 {
    return @bitCast(x);
}
