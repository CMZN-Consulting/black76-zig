//! diff_vectors.zig -- compare two fixture files, VECTOR LINES ONLY.
//!
//!   diff-vectors <committed.ndjson> <fresh.ndjson>
//!
//! Header lines are provenance (compiler, target, CPU, capture time) and are
//! expected to differ between captures. Vector lines are the contract and are
//! not expected to differ at all. Exit 0 = identical, exit 1 = a finding,
//! exit 2 = usage.
//!
//! Memory: each file is read once, whole, with an explicit size limit, and
//! freed at the end of `main`. Nothing else is allocated.

const std = @import("std");

/// A fixture is ~1.5 MB. Anything past this is not a fixture.
const file_bytes_max: usize = 64 << 20;

fn isHeader(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "{\"header\"");
}

/// Next vector line, skipping headers. Returns null at end of file.
fn nextVector(it: *std.mem.TokenIterator(u8, .scalar)) ?[]const u8 {
    while (it.next()) |line| {
        if (!isHeader(line)) return line;
    }
    return null;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.log.err("usage: diff-vectors <a.ndjson> <b.ndjson>", .{});
        return 2;
    }

    const a = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(file_bytes_max));
    defer gpa.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .limited(file_bytes_max));
    defer gpa.free(b);

    var ai = std.mem.tokenizeScalar(u8, a, '\n');
    var bi = std.mem.tokenizeScalar(u8, b, '\n');

    var n: usize = 0;
    var bad: usize = 0;
    while (true) {
        const av = nextVector(&ai);
        const bv = nextVector(&bi);
        if (av == null and bv == null) break;
        if (av == null or bv == null) {
            std.log.err("vector COUNT differs: one file ran out at vector {d}", .{n + 1});
            return 1;
        }
        n += 1;
        if (!std.mem.eql(u8, av.?, bv.?)) {
            bad += 1;
            if (bad <= 10) {
                std.log.err("vector {d} differs:\n  committed: {s}\n  fresh:     {s}", .{ n, av.?, bv.? });
            }
        }
    }

    if (bad != 0) {
        std.log.err("FINDING: {d} of {d} vectors differ. This is not a tolerance question -- see README.", .{ bad, n });
        return 1;
    }
    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("reproduced: {d}/{d} vectors bit-identical\n", .{ n, n });
    try stdout.interface.flush();
    return 0;
}
