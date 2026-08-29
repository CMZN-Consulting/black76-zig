const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -- The kernel, as a module and as a C-ABI library ----------------------
    const b76_mod = b.createModule(.{
        .root_source_file = b.path("src/black76.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared object: dlopen this and call black76_greeks / black76_greeks_batch.
    const shared = b.addLibrary(.{
        .name = "black76",
        .root_module = b76_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(shared);

    // Static archive, for hosts that would rather link it in.
    const static = b.addLibrary(.{
        .name = "black76",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/black76.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    b.installArtifact(static);

    // Reference fixture reader, shipped alongside the pricer.
    const fixture_mod = b.createModule(.{
        .root_source_file = b.path("src/fixture.zig"),
        .target = target,
        .optimize = optimize,
    });

    // -- Generator: re-captures the fixture ---------------------------------
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("tools/generate_vectors.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_mod.addImport("black76", b76_mod);
    // Embedded so the fixture header can fingerprint the exact source it came
    // from, without trusting a path at runtime.
    gen_mod.addAnonymousImport("black76_source", .{ .root_source_file = b.path("src/black76.zig") });

    // Deliberately NOT installed: a bare `zig build` should produce the library
    // and nothing else. A binary that rewrites the fixture does not belong
    // sitting in the default output directory.
    const gen = b.addExecutable(.{ .name = "generate-vectors", .root_module = gen_mod });

    const run_gen = b.addRunArtifact(gen);
    run_gen.setCwd(b.path("."));
    if (b.args) |args| run_gen.addArgs(args);
    b.step("generate", "Re-capture vectors/black76-golden.ndjson").dependOn(&run_gen.step);

    // -- Golden test: replays the committed fixture --------------------------
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/golden_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("black76", b76_mod);
    test_mod.addImport("fixture", fixture_mod);
    // The fixture is embedded, so the test is hermetic: no cwd, no file I/O,
    // and `zig build test` means the same thing from any directory.
    test_mod.addAnonymousImport("golden_fixture", .{ .root_source_file = b.path("vectors/black76-golden.ndjson") });

    const golden = b.addTest(.{ .root_module = test_mod });
    const run_golden = b.addRunArtifact(golden);
    b.step("test", "Replay the golden fixture and compare bit-for-bit").dependOn(&run_golden.step);

    // -- cdf-delta: price the cost of "just use a better CDF" ----------------
    const erf_mod = b.createModule(.{
        .root_source_file = b.path("tools/cdf_delta.zig"),
        .target = target,
        .optimize = optimize,
    });
    erf_mod.addImport("black76", b76_mod);
    erf_mod.addImport("fixture", fixture_mod);
    erf_mod.addAnonymousImport("golden_fixture", .{ .root_source_file = b.path("vectors/black76-golden.ndjson") });
    const erf = b.addExecutable(.{ .name = "cdf-delta", .root_module = erf_mod });
    const run_erf = b.addRunArtifact(erf);
    b.step("cdf-delta", "Measure what swapping the normal CDF would cost").dependOn(&run_erf.step);

    // -- Reproduce: capture again, diff against the committed file -----------
    // The acceptance test for the capture itself. Header lines differ by design
    // (they carry provenance); vector lines must not differ at all.
    const diff_mod = b.createModule(.{
        .root_source_file = b.path("tools/diff_vectors.zig"),
        .target = target,
        .optimize = optimize,
    });
    const differ = b.addExecutable(.{ .name = "diff-vectors", .root_module = diff_mod });

    const recapture = b.addRunArtifact(gen);
    recapture.setCwd(b.path("."));
    const fresh = recapture.addOutputFileArg("black76-golden.fresh.ndjson");

    const run_diff = b.addRunArtifact(differ);
    run_diff.addFileArg(b.path("vectors/black76-golden.ndjson"));
    run_diff.addFileArg(fresh);
    b.step("reproduce", "Re-capture into a temp file and diff vector lines").dependOn(&run_diff.step);
}
