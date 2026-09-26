/// Standard library for the `std.Build` API and threaded IO setup.
const std = @import("std");
/// Tree model used for the single-file fallback path.
const assets_tree = @import("assets_tree.zig");
/// In-memory and filesystem bake functions wrapped by the build step below.
const embed_builder = @import("embed_builder.zig");

/// Vtable type implemented by `EmbedFileDescriptor` and `EmbedDirectoryDescriptor`.
const Descriptor = @import("embed_descriptors.zig").abstract.Descriptor;

/// Lazy build outputs for one embed generation.
/// Returned by `addGeneration` so downstream steps can depend on the directory and the generated file.
pub const Result = struct {
    /// WriteFiles step producing the outputs; wired with watch inputs for incremental rebuilds.
    step: *std.Build.Step,
    /// Directory containing `file`; added as a dependency of compile steps.
    directory: std.Build.LazyPath,
    /// Generated Zig source file; added as an anonymous import or module source.
    file: std.Build.LazyPath,
};

/// User configuration for one embed generation.
/// Passed to `addGeneration` from a consumer `build.zig`; mirrors `Config` in `embed_builder`
/// plus the on-disk locations needed only at build time.
pub const Config = struct {
    /// Name of the generated Zig file inside the WriteFiles directory.
    output_name: []const u8 = "generated.zig",
    /// Enables stdout dumps of the bake for manual inspection.
    print_results: bool = false,
    /// Asset file or directory relative to the build root; watched for incremental rebuilds.
    assets_path: []const u8,
    /// Ordered descriptor table consulted for every node during the bake.
    descriptors: []const *const Descriptor,
};

/// Creates a WriteFiles step generating Zig source from assets.
/// Handles both recursive directories and single files, registers directory or file watch inputs,
/// and returns `Result` with `LazyPath`s. Failures emit a placeholder file instead of panicking at configure time.
/// - `b` - build graph owning the new WriteFiles step.
/// - `options` - assets location, output name, descriptor table and debug flags.
///
/// Return: step plus lazy directory and file handles for downstream dependencies.
pub fn addGeneration(b: *std.Build, options: Config) Result {
    const wf = b.addWriteFiles();
    wf.step.name = b.fmt("codegen {s} -> {s}", .{ options.assets_path, options.output_name });

    var relative_prefix: []const u8 = "";
    var allocated: ?[]const u8 = null;
    {
        const with_slash = std.fmt.allocPrint(b.allocator, "{s}/", .{options.assets_path}) catch "";
        allocated = with_slash;
        relative_prefix = with_slash;
    }

    const code = generateSync(b, options.assets_path, relative_prefix, options) catch |err| {
        std.debug.print("addGeneration (embed) failed for {s}: {t}\n", .{ options.assets_path, err });
        const empty = wf.add(options.output_name, "// codegen failed\n");
        if (allocated) |a| b.allocator.free(@constCast(a));
        return .{ .step = &wf.step, .directory = wf.getDirectory(), .file = empty };
    };
    defer b.allocator.free(code);
    if (allocated) |a| b.allocator.free(@constCast(a));

    const file = wf.add(options.output_name, code);

    const lp = b.path(options.assets_path);
    var is_dir = false;
    if (std.Io.Dir.cwd().openDir(b.graph.io, options.assets_path, .{ .iterate = true })) |*dir| {
        var d = dir.*;
        d.close(b.graph.io);
        is_dir = true;
    } else |_| {
        is_dir = false;
    }
    if (is_dir) {
        _ = wf.step.addDirectoryWatchInput(lp) catch {};
    } else {
        wf.step.addWatchInput(lp) catch {};
    }

    return .{ .step = &wf.step, .directory = wf.getDirectory(), .file = file };
}

/// Synchronously bakes Zig source for configure-time generation.
/// Opens a threaded IO pool, detects directory versus single file, and delegates to `embed_builder`.
/// Used only by `addGeneration`; the single-file path synthesizes a one-child root.
/// - `b` - build graph providing the allocator.
/// - `assets_path` - file or directory being converted.
/// - `relative_prefix` - `@embedFile` prefix including the trailing slash.
/// - `options` - descriptor table and debug flags forwarded to the builder.
///
/// Return: owned Zig source; caller must free it.
fn generateSync(b: *std.Build, assets_path: []const u8, relative_prefix: []const u8, options: Config) ![]u8 {
    const gpa = b.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var is_dir = false;
    if (std.Io.Dir.cwd().openDir(io, assets_path, .{ .iterate = true })) |*d| {
        var dir = d.*;
        dir.close(io);
        is_dir = true;
    } else |_| {
        is_dir = false;
    }

    if (is_dir) {
        return embed_builder.bakeCodeToMemoryWithIo(gpa, io, assets_path, relative_prefix, options.descriptors);
    } else {
        var root = try assets_tree.Node.initHeap(gpa, .root, null, null);
        defer root.deinitRecursively(gpa, true);
        const basename = std.fs.path.basename(assets_path);
        const name_copy = try gpa.dupe(u8, basename);
        const child = try assets_tree.Node.initHeap(gpa, .file, name_copy, root);
        try root.children.put(name_copy, child);
        const code = try embed_builder.bakeAssetsTreeToCodeWithIo(gpa, io, relative_prefix, root, 0, .{ .descriptors = options.descriptors, .print_results = options.print_results });
        return code;
    }
}
