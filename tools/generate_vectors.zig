//! generate_vectors.zig -- capture the golden fixture.
//!
//!   zig build generate            # writes vectors/black76-golden.ndjson
//!   zig build generate -- <path>  # writes somewhere else
//!
//! This file owns the CASE LIST. The test does not: it replays the inputs stored
//! in the fixture itself, so the fixture stays the contract even if this list is
//! later extended. Adding cases is additive and safe; changing an existing
//! case's numbers rewrites history and must be argued for.
//!
//! Memory: the number of cases is a compile-time constant derived from the
//! axes below (`case_count`), the case list is allocated once at exactly that
//! size with an explicit allocator, and the file is streamed through a fixed
//! buffer rather than assembled in memory. Nothing grows.

const std = @import("std");
const assert = std.debug.assert;
const b76 = @import("black76");
const builtin = @import("builtin");

const source_text = @embedFile("black76_source");

const Case = struct {
    f: f64,
    k: f64,
    s: f64,
    t: f64,
    kind: b76.Kind,
    g: []const u8,
};

// -- Grid axes ----------------------------------------------------------------
//
// Three forward magnitudes six decades apart. Scale is a real axis here and not
// padding: gamma divides by `forward`, so an implementation that is clean at
// 5e2 can still lose digits at 5e-1. The values are deliberately synthetic --
// round numbers chosen for numerical spread and nothing else.
const forwards = [_]f64{ 0.5, 500.0, 500000.0 };

// Moneyness F/K. Strike is derived as K = F/m so the ratio is what is swept.
const moneyness = [_]f64{ 0.5, 0.8, 0.9, 0.95, 0.99, 1.0, 1.01, 1.05, 1.1, 1.25, 2.0 };

const sigmas = [_]f64{ 0.05, 0.20, 0.50, 0.80, 1.50, 3.00 };

// Time to maturity in DAYS; converted to years as days/365 at f64 precision.
// 5 minutes through one year.
const ttm_days = [_]f64{ 5.0 / 1440.0, 1.0 / 24.0, 1.0, 3.0, 7.0, 30.0, 90.0, 365.0 };

const kinds = [_]b76.Kind{ .call, .put };

// -- Degenerate-case axes -----------------------------------------------------

const near_atm = [_]f64{ 0.99, 1.0, 1.01 };
const guard_ticks = [_]f64{ -1e-9, 0.0, 1e-9 };
const sigsqrt_ticks = [_]f64{ 9.9e-11, 1.0e-10, 1.01e-10 };
const bad = [_]f64{ -1.0, -0.0, 0.0, 500.0 };
const wing_moneyness = [_]f64{ 0.2, 5.0 };
const wing_sigmas = [_]f64{ 0.05, 0.10 };
const wing_days = [_]f64{ 5.0 / 1440.0, 1.0 / 24.0, 1.0 };
const tail_moneyness = [_]f64{ 0.05, 20.0 };

/// Every group's size, derived from the axes so the total is a compile-time
/// fact and `buildCases` can be checked against it.
const group_counts = .{
    .grid = forwards.len * moneyness.len * sigmas.len * ttm_days.len * kinds.len,
    .atm_expired = forwards.len * kinds.len * 2,
    .atm_zerovol = forwards.len * kinds.len * 2,
    .atm_asymptotic = forwards.len * kinds.len,
    .guard_ttm = forwards.len * near_atm.len * kinds.len * guard_ticks.len,
    .guard_sigma = forwards.len * near_atm.len * kinds.len * guard_ticks.len,
    .guard_sigsqrt = forwards.len * near_atm.len * kinds.len * sigsqrt_ticks.len,
    .invalid = (bad.len * bad.len - 1) * kinds.len,
    .precedence = forwards.len * kinds.len * 7,
    .deep_wing = forwards.len * wing_moneyness.len * wing_sigmas.len * wing_days.len * kinds.len,
    .extreme_tail = forwards.len * tail_moneyness.len * kinds.len,
};

pub const case_count: u32 = blk: {
    var total: u32 = 0;
    for (@typeInfo(@TypeOf(group_counts)).@"struct".fields) |field| {
        total += @field(group_counts, field.name);
    }
    break :blk total;
};

comptime {
    // The README quotes these; if the axes change, the README must too.
    assert(group_counts.grid == 3168);
    assert(case_count == 3516);
}

/// Fixed-capacity appender over a caller-owned slice. Appending past the end
/// is a programming error, not a runtime condition, so it asserts.
const Cases = struct {
    items: []Case,
    len: usize = 0,

    fn add(cases: *Cases, c: Case) void {
        assert(cases.len < cases.items.len);
        cases.items[cases.len] = c;
        cases.len += 1;
    }
};

fn buildCases(out: []Case) void {
    assert(out.len == case_count);
    var cases: Cases = .{ .items = out };

    // 1. The grid. Table stakes, and the smallest part of the story.
    for (forwards) |f| {
        for (moneyness) |m| {
            const k = f / m;
            for (sigmas) |s| {
                for (ttm_days) |d| {
                    const t = d / 365.0;
                    for (kinds) |kind| {
                        cases.add(.{ .f = f, .k = k, .s = s, .t = t, .kind = kind, .g = "grid" });
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
    for (forwards) |f| {
        for (kinds) |kind| {
            for ([_]f64{ 0.0, -1e-9 }) |t| {
                cases.add(.{ .f = f, .k = f, .s = 0.5, .t = t, .kind = kind, .g = "atm-expired" });
            }
            for ([_]f64{ 0.0, -1e-9 }) |s| {
                cases.add(.{ .f = f, .k = f, .s = s, .t = 1.0, .kind = kind, .g = "atm-zerovol" });
            }
            // sigma*sqrt(t) = 1e-11 < 1e-10 -> asymptotic guard, sigma still > 0.
            cases.add(.{ .f = f, .k = f, .s = 1e-11, .t = 1.0, .kind = kind, .g = "atm-asymptotic" });
        }
    }

    // 3. Straddle each guard: one tick below, exactly on, one tick above.
    for (forwards) |f| {
        for (near_atm) |m| {
            const k = f / m;
            for (kinds) |kind| {
                for (guard_ticks) |t| {
                    cases.add(.{ .f = f, .k = k, .s = 0.5, .t = t, .kind = kind, .g = "guard-ttm" });
                }
                for (guard_ticks) |s| {
                    cases.add(.{ .f = f, .k = k, .s = s, .t = 1.0 / 365.0, .kind = kind, .g = "guard-sigma" });
                }
                // ttm = 1.0 exactly, so sigma*sqrt(ttm) == sigma and the
                // 1e-10 guard is straddled to the ulp, boundary included.
                for (sigsqrt_ticks) |s| {
                    cases.add(.{ .f = f, .k = k, .s = s, .t = 1.0, .kind = kind, .g = "guard-sigsqrt" });
                }
            }
        }
    }

    // 4. Invalid inputs. Pins that "invalid" means five zeros, not NaN, and
    //    that -0.0 is caught by the <= 0.0 test like any other zero.
    for (bad) |f| {
        for (bad) |k| {
            if (f > 0.0 and k > 0.0) continue;
            for (kinds) |kind| {
                cases.add(.{ .f = f, .k = k, .s = 0.5, .t = 1.0 / 365.0, .kind = kind, .g = "invalid" });
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
    for (forwards) |f| {
        for (kinds) |kind| {
            // expired beats zero-vol
            cases.add(.{ .f = f, .k = f, .s = 0.0, .t = 0.0, .kind = kind, .g = "precedence" });
            cases.add(.{ .f = f, .k = f, .s = -1e-9, .t = -1e-9, .kind = kind, .g = "precedence" });
            // expired beats asymptotic
            cases.add(.{ .f = f, .k = f, .s = 1e-11, .t = 0.0, .kind = kind, .g = "precedence" });
            // zero-vol beats asymptotic (sigma <= 0 is checked before the product)
            cases.add(.{ .f = f, .k = f, .s = 0.0, .t = 1e-30, .kind = kind, .g = "precedence" });
            // invalid beats everything: five zeros, NOT the expired half-delta
            cases.add(.{ .f = -0.0, .k = f, .s = 0.0, .t = 0.0, .kind = kind, .g = "precedence" });
            cases.add(.{ .f = f, .k = -0.0, .s = 0.0, .t = 0.0, .kind = kind, .g = "precedence" });
            cases.add(.{ .f = -1.0, .k = -1.0, .s = -1.0, .t = -1.0, .kind = kind, .g = "precedence" });
        }
    }

    // 5. Deep wings, low vol, short dated -- where a tail CDF is worst
    //    conditioned and where a "simplification" of the put path would show up
    //    if one were possible.
    for (forwards) |f| {
        for (wing_moneyness) |m| {
            const k = f / m;
            for (wing_sigmas) |s| {
                for (wing_days) |d| {
                    for (kinds) |kind| {
                        cases.add(.{ .f = f, .k = k, .s = s, .t = d / 365.0, .kind = kind, .g = "deep-wing" });
                    }
                }
            }
        }
    }

    // 6. Extreme tails: |d1| in the thousands, where exp(-d1^2/2) underflows to
    //    zero and the CDF saturates. Pins the saturated values rather than
    //    leaving them to chance.
    for (forwards) |f| {
        for (tail_moneyness) |m| {
            const k = f / m;
            for (kinds) |kind| {
                cases.add(.{ .f = f, .k = k, .s = 0.05, .t = (5.0 / 1440.0) / 365.0, .kind = kind, .g = "extreme-tail" });
            }
        }
    }

    assert(cases.len == case_count);
}

fn hex(x: f64) [18]u8 {
    var buf: [18]u8 = undefined;
    const bits: u64 = @bitCast(x);
    _ = std.fmt.bufPrint(&buf, "0x{X:0>16}", .{bits}) catch unreachable;
    return buf;
}

/// Provenance header. Not part of the contract; the test skips it. It records
/// WHICH binary produced the numbers, because the numbers are meaningless
/// without that.
fn writeHeader(w: *std.Io.Writer) !void {
    var src_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source_text, &src_digest, .{});

    try w.print(
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
        case_count,
    });
}

/// One vector line. Compared fields first, hex only. The trailing "_" field is
/// a decimal rendering for human eyes and is NEVER the compared value --
/// decimal is exactly where byte-identity dies.
fn writeVector(w: *std.Io.Writer, c: Case) !void {
    const out = b76.greeks(.{ .forward = c.f, .strike = c.k, .sigma = c.s, .ttm = c.t, .kind = c.kind });
    const is_call = c.kind == .call;
    try w.print(
        \\{{"f":"{s}","k":"{s}","s":"{s}","t":"{s}","c":{},"delta":"{s}","gamma":"{s}","theta":"{s}","vega":"{s}","price":"{s}","g":"{s}","_":"F={d} K={d} sigma={d} T={e}y {s} -> price={e} delta={e} gamma={e} theta={e} vega={e}"}}
        \\
    , .{
        &hex(c.f),                      &hex(c.k),       &hex(c.s),       &hex(c.t),      is_call,
        &hex(out.delta),                &hex(out.gamma), &hex(out.theta), &hex(out.vega), &hex(out.price),
        c.g,                            c.f,             c.k,             c.s,            c.t,
        if (is_call) "call" else "put", out.price,       out.delta,       out.gamma,      out.theta,
        out.vega,
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Process-lifetime scraps (argv) go in the arena; the case list, the one
    // real allocation, goes through the leak-checked general purpose allocator
    // and is freed here, explicitly.
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(arena);
    const out_path = if (args.len > 1) args[1] else "vectors/black76-golden.ndjson";

    const cases = try gpa.alloc(Case, case_count);
    defer gpa.free(cases);
    buildCases(cases);

    const file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);

    var write_buf: [1 << 16]u8 = undefined;
    var file_writer = file.writer(io, &write_buf);
    const w = &file_writer.interface;

    try writeHeader(w);
    for (cases) |c| try writeVector(w, c);
    try w.flush();

    // Success goes to stdout, not the log. A build step that writes to stderr
    // gets reported as a failed command by the build runner even when it
    // succeeded, and a green run that looks red is worse than no message.
    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print("wrote {d} vectors to {s}\n", .{ cases.len, out_path });
    try stdout.interface.flush();
}
