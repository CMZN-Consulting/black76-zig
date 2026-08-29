// diff_vectors.zig -- compare two fixture files, VECTOR LINES ONLY.
//
//   diff-vectors <committed.ndjson> <fresh.ndjson>
//
// Header lines are provenance (compiler, target, CPU, capture time) and are
// expected to differ between captures. Vector lines are the contract and are
// not expected to differ at all. Exit 0 = identical, exit 1 = a finding.

const std = @import("std");

fn readAll(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

fn isHeader(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "{\"header\"");
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();

    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) {
        std.log.err("usage: diff-vectors <a.ndjson> <b.ndjson>", .{});
        return 2;
    }

    const a = try readAll(io, gpa, args[1]);
    const b = try readAll(io, gpa, args[2]);

    var ai = std.mem.tokenizeScalar(u8, a, '\n');
    var bi = std.mem.tokenizeScalar(u8, b, '\n');

    var n: usize = 0;
    var bad: usize = 0;
    while (true) {
        const av = blk: {
            while (ai.next()) |l| if (!isHeader(l)) break :blk l;
            break :blk null;
        };
        const bv = blk: {
            while (bi.next()) |l| if (!isHeader(l)) break :blk l;
            break :blk null;
        };
        if (av == null and bv == null) break;
        if (av == null or bv == null) {
            std.log.err("vector COUNT differs: one file ran out at line {d}", .{n + 1});
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
