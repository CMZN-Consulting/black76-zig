// generate_vectors.zig -- capture the golden fixture.
//
//   zig build generate            # writes vectors/black76-golden.ndjson
//   zig build generate -- <path>  # writes somewhere else
//
// This file owns the CASE LIST. The test does not: it replays the inputs stored
// in the fixture itself, so the fixture stays the contract even if this list is
// later extended. Adding cases is additive and safe; changing an existing
// case's numbers rewrites history and must be argued for.

const std = @import("std");
const b76 = @import("black76");
const builtin = @import("builtin");

const source_text = @embedFile("black76_source");

const Case = struct {
    f: f64,
    k: f64,
    s: f64,
    t: f64,
    c: bool,
    g: []const u8,
};

// -- Grid axes ----------------------------------------------------
//
// Three forward magnitudes six decades apart. Scale is a real axis here and not
// padding: gamma divides by `forward`, so an implementation that is clean at
// 5e2 can still lose digits at 5e-1. The values are deliberately synthetic --
// round numbers chosen for numerical spread and nothing else.
const FORWARDS = [_]f64{ 0.5, 500.0, 500000.0 };

// Moneyness F/K. Strike is derived as K = F/m so the ratio is what is swept.
const MONEYNESS = [_]f64{ 0.5, 0.8, 0.9, 0.95, 0.99, 1.0, 1.01, 1.05, 1.1, 1.25, 2.0 };

const SIGMAS = [_]f64{ 0.05, 0.20, 0.50, 0.80, 1.50, 3.00 };

// Time to maturity in DAYS; converted to years as days/365 at f64 precision.
// 5 minutes through one year.
const TTM_DAYS = [_]f64{ 5.0 / 1440.0, 1.0 / 24.0, 1.0, 3.0, 7.0, 30.0, 90.0, 365.0 };

fn appendCase(list: *std.ArrayList(Case), gpa: std.mem.Allocator, c: Case) !void {
    try list.append(gpa, c);
}

fn buildCases(gpa: std.mem.Allocator) !std.ArrayList(Case) {
    var cases: std.ArrayList(Case) = .empty;

    // 1. The grid. Table stakes, and the smallest part of the story.
    for (FORWARDS) |f| {
        for (MONEYNESS) |m| {
            const k = f / m;
            for (SIGMAS) |s| {
                for (TTM_DAYS) |d| {
                    const t = d / 365.0;
                    for ([_]bool{ true, false }) |call| {
                        try appendCase(&cases, gpa, .{ .f = f, .k = k, .s = s, .t = t, .c = call, .g = "grid" });
                    }
                }
            }
        }
    }

    // 2. The cases this file exists for. Three degenerate branches, all at F == K exactly,
    //    where they disagree with each other on delta:
    //      expired    -> +0.5 / -0.5
    //      zero vol   ->  0.0 /  0.0
    //      asymptotic ->  0.0 /  0.0
    //    A port that "unifies" the branches passes every other vector in this
    //    file and fails these six per magnitude. That is the entire point.
    for (FORWARDS) |f| {
        for ([_]bool{ true, false }) |call| {
            for ([_]f64{ 0.0, -1e-9 }) |t| {
                try appendCase(&cases, gpa, .{ .f = f, .k = f, .s = 0.5, .t = t, .c = call, .g = "atm-expired" });
            }
            for ([_]f64{ 0.0, -1e-9 }) |s| {
                try appendCase(&cases, gpa, .{ .f = f, .k = f, .s = s, .t = 1.0, .c = call, .g = "atm-zerovol" });
            }
            // sigma*sqrt(t) = 1e-11 < 1e-10 -> asymptotic guard, sigma still > 0.
            try appendCase(&cases, gpa, .{ .f = f, .k = f, .s = 1e-11, .t = 1.0, .c = call, .g = "atm-asymptotic" });
        }
    }

    // 3. Straddle each guard: one tick below, exactly on, one tick above.
    const NEAR_ATM = [_]f64{ 0.99, 1.0, 1.01 };
    for (FORWARDS) |f| {
        for (NEAR_ATM) |m| {
            const k = f / m;
            for ([_]bool{ true, false }) |call| {
                for ([_]f64{ -1e-9, 0.0, 1e-9 }) |t| {
                    try appendCase(&cases, gpa, .{ .f = f, .k = k, .s = 0.5, .t = t, .c = call, .g = "guard-ttm" });
                }
                for ([_]f64{ -1e-9, 0.0, 1e-9 }) |s| {
                    try appendCase(&cases, gpa, .{ .f = f, .k = k, .s = s, .t = 1.0 / 365.0, .c = call, .g = "guard-sigma" });
                }
                // ttm = 1.0 exactly, so sigma*sqrt(ttm) == sigma and the
                // 1e-10 guard is straddled to the ulp, boundary included.
                for ([_]f64{ 9.9e-11, 1.0e-10, 1.01e-10 }) |s| {
                    try appendCase(&cases, gpa, .{ .f = f, .k = k, .s = s, .t = 1.0, .c = call, .g = "guard-sigsqrt" });
                }
            }
        }
    }

    // 4. Invalid inputs. Pins that "invalid" means five zeros, not NaN, and
    //    that -0.0 is caught by the <= 0.0 test like any other zero.
    const BAD = [_]f64{ -1.0, -0.0, 0.0, 500.0 };
    for (BAD) |f| {
        for (BAD) |k| {
            if (f > 0.0 and k > 0.0) continue;
            for ([_]bool{ true, false }) |call| {
                try appendCase(&cases, gpa, .{ .f = f, .k = k, .s = 0.5, .t = 1.0 / 365.0, .c = call, .g = "invalid" });
            }
        }
    }

    // 4b. GUARD PRECEDENCE. The four guards are tested in a fixed order --
    //     invalid, then expired, then zero-vol, then asymptotic -- and more
    //     than one can apply at once. Because they DISAGREE at F == K, the
    //     order is observable: ttm=0 with sigma=0 must return the EXPIRED
    //     answer (delta +/-0.5), not the zero-vol answer (0.0).
    //
    //     Nothing else in this file can catch a reordering. Every vector above
    //     satisfies at most one guard, so a port that checks zero-vol first
    //     passes all of them and fails only here.
    for (FORWARDS) |f| {
        for ([_]bool{ true, false }) |call| {
            // expired beats zero-vol
            try appendCase(&cases, gpa, .{ .f = f, .k = f, .s = 0.0, .t = 0.0, .c = call, .g = "precedence" });
            try appendCase(&cases, gpa, .{ .f = f, .k = f, .s = -1e-9, .t = -1e-9, .c = call, .g = "precedence" });
            // expired beats asymptotic
            try appendCase(&cases, gpa, .{ .f = f, .k = f, .s = 1e-11, .t = 0.0, .c = call, .g = "precedence" });
            // zero-vol beats asymptotic (sigma <= 0 is checked before the product)
            try appendCase(&cases, gpa, .{ .f = f, .k = f, .s = 0.0, .t = 1e-30, .c = call, .g = "precedence" });
            // invalid beats everything: five zeros, NOT the expired half-delta
            try appendCase(&cases, gpa, .{ .f = -0.0, .k = f, .s = 0.0, .t = 0.0, .c = call, .g = "precedence" });
            try appendCase(&cases, gpa, .{ .f = f, .k = -0.0, .s = 0.0, .t = 0.0, .c = call, .g = "precedence" });
            try appendCase(&cases, gpa, .{ .f = -1.0, .k = -1.0, .s = -1.0, .t = -1.0, .c = call, .g = "precedence" });
        }
    }

    // 5. Deep wings, low vol, short dated -- where a tail CDF is worst
    //    conditioned and where a "simplification" of the put path would show up
    //    if one were possible. (Whether one is possible in THIS kernel is
    //    discussed in the README; the vectors are worth having either way.)
    for (FORWARDS) |f| {
        for ([_]f64{ 0.2, 5.0 }) |m| {
            const k = f / m;
            for ([_]f64{ 0.05, 0.10 }) |s| {
                for ([_]f64{ 5.0 / 1440.0, 1.0 / 24.0, 1.0 }) |d| {
                    for ([_]bool{ true, false }) |call| {
                        try appendCase(&cases, gpa, .{ .f = f, .k = k, .s = s, .t = d / 365.0, .c = call, .g = "deep-wing" });
                    }
                }
            }
        }
    }

    // 6. Extreme tails: |d1| in the thousands, where exp(-d1^2/2) underflows to
    //    zero and the CDF saturates. Pins the saturated values rather than
    //    leaving them to chance.
    for (FORWARDS) |f| {
        for ([_]f64{ 0.05, 20.0 }) |m| {
            const k = f / m;
            for ([_]bool{ true, false }) |call| {
                try appendCase(&cases, gpa, .{ .f = f, .k = k, .s = 0.05, .t = (5.0 / 1440.0) / 365.0, .c = call, .g = "extreme-tail" });
            }
        }
    }

    return cases;
}

fn hex(x: f64) [18]u8 {
    var buf: [18]u8 = undefined;
    const bits: u64 = @bitCast(x);
    _ = std.fmt.bufPrint(&buf, "0x{X:0>16}", .{bits}) catch unreachable;
    return buf;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    const args = try init.minimal.args.toSlice(gpa);
    const out_path = if (args.len > 1) args[1] else "vectors/black76-golden.ndjson";

    const cases = try buildCases(gpa);
    var out: std.ArrayList(u8) = .empty;

    // -- Provenance header ---------------------------------------------------
    // Not part of the contract. The test skips it. It records WHICH binary
    // produced the numbers, because the numbers are meaningless without that.
    var src_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source_text, &src_digest, .{});

    try out.print(gpa,
        \\{{"header":1,"schema":"black76-golden/1","zig_version":"{s}","target":"{s}-{s}-{s}","cpu":"{s}","optimize":"{s}","source_sha256":"{x}","source_bytes":{d},"vector_count":{d},"r":"0.0 hardcoded","theta_units":"per year","ttm_units":"years"}}
        \\
    , .{
        builtin.zig_version_string,
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.abi),
        builtin.cpu.model.name,
        @tagName(builtin.mode),
        &src_digest,
        source_text.len,
        cases.items.len,
    });

    // -- Vectors -------------------------------------------------------------
    for (cases.items) |cs| {
        var delta: f64 = undefined;
        var gamma: f64 = undefined;
        var theta: f64 = undefined;
        var vega: f64 = undefined;
        var price: f64 = undefined;
        b76.black76_greeks(cs.f, cs.k, cs.s, cs.t, cs.c, &delta, &gamma, &theta, &vega, &price);

        // Compared fields first, hex only. The trailing "_" field is a decimal
        // rendering for human eyes and is NEVER the compared value -- decimal
        // is exactly where byte-identity dies.
        try out.print(gpa,
            \\{{"f":"{s}","k":"{s}","s":"{s}","t":"{s}","c":{},"delta":"{s}","gamma":"{s}","theta":"{s}","vega":"{s}","price":"{s}","g":"{s}","_":"F={d} K={d} sigma={d} T={e}y {s} -> price={e} delta={e} gamma={e} theta={e} vega={e}"}}
            \\
        , .{
            &hex(cs.f),                  &hex(cs.k),  &hex(cs.s),  &hex(cs.t), cs.c,
            &hex(delta),                 &hex(gamma), &hex(theta), &hex(vega), &hex(price),
            cs.g,                        cs.f,        cs.k,        cs.s,       cs.t,
            if (cs.c) "call" else "put", price,       delta,       gamma,      theta,
            vega,
        });
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.items });

    // Success goes to stdout, not the log. A build step that writes to stderr
    // gets reported as a failed command by the build runner even when it
    // succeeded, and a green run that looks red is worse than no message.
    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("wrote {d} vectors ({d} bytes) to {s}\n", .{ cases.items.len, out.items.len, out_path });
    try stdout.interface.flush();
}
