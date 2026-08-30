const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // In-repo exp/log, lane-generic. The kernel's numbers depend on these and
    // on nothing outside this repository.
    const libm_mod = b.createModule(.{
        .root_source_file = b.path("src/libm.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The normal distribution, lane-generic, on top of libm.
    const normal_mod = b.createModule(.{
        .root_source_file = b.path("src/normal.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "libm", .module = libm_mod }},
    });

    // -- The kernel, as a module and as a C-ABI library ----------------------
    const b76_mod = b.createModule(.{
        .root_source_file = b.path("src/black76.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "libm", .module = libm_mod }, .{ .name = "normal", .module = normal_mod } },
    });

    // Shared object: dlopen this and call black76_greeks / black76_greeks_batch.
    const shared = b.addLibrary(.{
        .name = "black76",
        .root_module = b76_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(shared);

    // Static archive, for hosts that would rather link it in. A library needs
    // its own root module, so this is the kernel a second time.
    const static = b.addLibrary(.{
        .name = "black76",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/black76.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "libm", .module = libm_mod }, .{ .name = "normal", .module = normal_mod } },
        }),
        .linkage = .static,
    });
    b.installArtifact(static);

    // Reference fixture reader, shipped alongside the pricer. It names the
    // kernel's `Kind`, so it imports the kernel module rather than the file:
    // one `Kind`, not two structurally identical ones.
    const fixture_mod = b.createModule(.{
        .root_source_file = b.path("src/fixture.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixture_mod.addImport("black76", b76_mod);

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

    // -- Tests: the golden replay, plus the reader's own unit tests ----------
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
    const reader_tests = b.addTest(.{ .root_module = fixture_mod });

    // libm differential tests: millions of samples under `test`, a billion
    // under `libm-soak`. Same file, two entry points.
    const libm_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/libm_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    libm_test_mod.addImport("libm", libm_mod);
    const libm_tests = b.addTest(.{ .root_module = libm_test_mod });
    const libm_soak = b.addExecutable(.{ .name = "libm-soak", .root_module = libm_test_mod });
    b.step("libm-soak", "Compare in-repo exp/log with compiler_rt over 1e9 samples").dependOn(&b.addRunArtifact(libm_soak).step);

    const normal_tests = b.addTest(.{ .root_module = normal_mod });

    const test_step = b.step("test", "Replay the golden fixture and compare bit-for-bit");
    test_step.dependOn(&b.addRunArtifact(golden).step);
    test_step.dependOn(&b.addRunArtifact(reader_tests).step);
    test_step.dependOn(&b.addRunArtifact(libm_tests).step);
    test_step.dependOn(&b.addRunArtifact(normal_tests).step);

    // -- cdf-delta: price the cost of "just use a better CDF" ----------------
    const cdf_mod = b.createModule(.{
        .root_source_file = b.path("tools/cdf_delta.zig"),
        .target = target,
        .optimize = optimize,
    });
    cdf_mod.addImport("black76", b76_mod);
    cdf_mod.addImport("fixture", fixture_mod);
    cdf_mod.addAnonymousImport("golden_fixture", .{ .root_source_file = b.path("vectors/black76-golden.ndjson") });
    const cdf_delta = b.addExecutable(.{ .name = "cdf-delta", .root_module = cdf_mod });
    b.step("cdf-delta", "Measure what swapping the normal CDF would cost").dependOn(&b.addRunArtifact(cdf_delta).step);

    // -- bench: ns/option, so "optimised" is a number ------------------------
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("black76", b76_mod);
    const bench = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    b.step("bench", "Time the kernel (use -Doptimize=ReleaseFast)").dependOn(&b.addRunArtifact(bench).step);

    // -- assoc-delta: price the v2 -> v3 re-association ----------------------
    // Built to the `cdf-delta` template, and for the same reason: a model
    // change that moves golden vectors has to ship with the instrument that
    // measures what it moved. It embeds the RETAINED v2 fixture rather than the
    // current one, so it keeps measuring this change after regeneration --
    // exactly as `cdf-delta` keeps measuring v1 -> v2.
    const assoc_mod = b.createModule(.{
        .root_source_file = b.path("tools/assoc_delta.zig"),
        .target = target,
        .optimize = optimize,
    });
    assoc_mod.addImport("black76", b76_mod);
    assoc_mod.addImport("fixture", fixture_mod);
    assoc_mod.addAnonymousImport("golden_fixture_v2", .{ .root_source_file = b.path("vectors/black76-golden.v2.ndjson") });
    const assoc_delta = b.addExecutable(.{ .name = "assoc-delta", .root_module = assoc_mod });
    b.step("assoc-delta", "Measure what the v2 -> v3 re-association moved").dependOn(&b.addRunArtifact(assoc_delta).step);

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
