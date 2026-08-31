const std = @import("std");
const assets_tree = @import("assets_tree.zig");
const assets_builder = @import("assets_builder.zig");
const binary_builder = @import("binary_builder.zig");
const descriptors_mod = @import("descriptors.zig");
const binary_descriptors_mod = @import("binary_descriptors.zig");

// Helpers that expose asset generation as proper Build steps with LazyPath outputs
// and directory/file dependency tracking.

pub const CodeGenOptions = struct {
    /// Path to asset file or directory. Relative to build root (e.g. "src/shaders").
    assets_path: []const u8,
    /// Name of generated zig file inside the WriteFiles directory (e.g. "shaders.zig").
    output_name: []const u8 = "generated.zig",
    /// Code descriptors (e.g. VertexDescriptor, FragmentDescriptor, ZigDirectory...)
    descriptors: []const *const descriptors_mod.Descriptor,
    print_results: bool = false,
};

pub const CodeGenResult = struct {
    step: *std.Build.Step,
    directory: std.Build.LazyPath,
    file: std.Build.LazyPath,
};

/// Create a WriteFiles step that generates Zig code from assets.
/// Handles single file or recursive directory. Registers directory watch so
/// build system re-runs when assets are added/removed/modified.
pub fn addCodeGeneration(b: *std.Build, options: CodeGenOptions) CodeGenResult {
    const wf = b.addWriteFiles();
    wf.step.name = b.fmt("codegen {s} -> {s}", .{ options.assets_path, options.output_name });

    // For build-time generation, we need cwd-relative path to locate source files.
    // Use assets_path directly as prefix (e.g. "src/textures/").
    var relative_prefix: []const u8 = "";
    var allocated: ?[]const u8 = null;
    {
        const with_slash = std.fmt.allocPrint(b.allocator, "{s}/", .{options.assets_path}) catch "";
        allocated = with_slash;
        relative_prefix = with_slash;
    }

    const code = generateCodeSync(b, options.assets_path, relative_prefix, options) catch |err| {
        std.debug.print("addCodeGeneration failed for {s}: {t}\n", .{ options.assets_path, err });
        // Return empty file to avoid panic; build will fail later
        const empty = wf.add(options.output_name, "// codegen failed\n");
        if (allocated) |a| b.allocator.free(@constCast(a));
        return .{ .step = &wf.step, .directory = wf.getDirectory(), .file = empty };
    };
    defer b.allocator.free(code);
    if (allocated) |a| b.allocator.free(@constCast(a));

    const file = wf.add(options.output_name, code);

    // Dependency tracking: watch the assets path
    // If it's a directory, watch recursive via addDirectoryWatchInput
    // If it's a file, watch single file
    const lp = b.path(options.assets_path);
    // Try to determine if path is directory at configure time (best effort)
    var is_dir = false;
    if (std.Io.Dir.cwd().openDir(b.graph.io, options.assets_path, .{ .iterate = true })) |*dir| {
        var d = dir.*;
        d.close(b.graph.io);
        is_dir = true;
    } else |_| {
        is_dir = false;
    }
    if (is_dir) {
        // `addDirectoryWatchInput` returns bool, but we can ignore
        _ = wf.step.addDirectoryWatchInput(lp) catch {};
    } else {
        wf.step.addWatchInput(lp) catch {};
    }

    return .{ .step = &wf.step, .directory = wf.getDirectory(), .file = file };
}

fn generateCodeSync(b: *std.Build, assets_path: []const u8, relative_prefix: []const u8, options: CodeGenOptions) ![]u8 {
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
        return binary_builder.bakeCodeToMemoryWithIo(gpa, io, assets_path, relative_prefix, options.descriptors);
    } else {
        var root = try assets_tree.Node.initHeap(gpa, .root, null, null);
        defer root.deinitRecursively(gpa, true);
        const basename = std.fs.path.basename(assets_path);
        const name_copy = try gpa.dupe(u8, basename);
        const child = try assets_tree.Node.initHeap(gpa, .file, name_copy, root);
        try root.children.put(name_copy, child);
        const code = try assets_builder.bakeAssetsTreeToCodeWithIo(gpa, io, relative_prefix, root, 0, .{ .descriptors = options.descriptors, .print_results = options.print_results });
        return code;
    }
}

pub const BinaryGenOptions = struct {
    assets_path: []const u8,
    output_name_zig: []const u8 = "assets.zig",
    output_name_bin: []const u8 = "assets.bin",
    /// Path embedded into generated Zig as bundle location at runtime.
    /// For desktop: relative to cwd or executable dir (e.g. "assets.bin" or "bin/assets.bin").
    /// For wasm: virtual FS path (e.g. "assets.bin").
    bundle_path: []const u8 = "assets.bin",
    descriptors: []const *const binary_descriptors_mod.BinaryDescriptor,
    print_results: bool = false,
};

pub const BinaryGenResult = struct {
    step: *std.Build.Step,
    directory: std.Build.LazyPath,
    file_zig: std.Build.LazyPath,
    file_bin: std.Build.LazyPath,
    bundle_path: []const u8,
};

/// Create a WriteFiles step that generates binary bundle + zig mapper.
pub fn addBinaryGeneration(b: *std.Build, options: BinaryGenOptions) BinaryGenResult {
    const wf = b.addWriteFiles();
    wf.step.name = b.fmt("binarygen {s} -> {s} + {s}", .{ options.assets_path, options.output_name_zig, options.output_name_bin });

    var relative_prefix: []const u8 = "";
    var allocated: ?[]const u8 = null;
    {
        const with_slash = std.fmt.allocPrint(b.allocator, "{s}/", .{options.assets_path}) catch "";
        allocated = with_slash;
        relative_prefix = with_slash;
    }

    const result = generateBinarySync(b, options.assets_path, relative_prefix, options) catch |err| {
        std.debug.print("addBinaryGeneration failed for {s}: {t}\n", .{ options.assets_path, err });
        const empty_zig = wf.add(options.output_name_zig, "// binarygen failed\n");
        const empty_bin = wf.add(options.output_name_bin, "");
        if (allocated) |a| b.allocator.free(@constCast(a));
        return .{ .step = &wf.step, .directory = wf.getDirectory(), .file_zig = empty_zig, .file_bin = empty_bin, .bundle_path = options.bundle_path };
    };
    defer b.allocator.free(result.code);
    defer b.allocator.free(result.bin);
    if (allocated) |a| b.allocator.free(@constCast(a));

    const file_zig = wf.add(options.output_name_zig, result.code);
    const file_bin = wf.add(options.output_name_bin, result.bin);

    // Watch inputs
    const lp = b.path(options.assets_path);
    var is_dir = false;
    if (std.Io.Dir.cwd().openDir(b.graph.io, options.assets_path, .{ .iterate = true })) |*d| {
        var dir = d.*;
        dir.close(b.graph.io);
        is_dir = true;
    } else |_| is_dir = false;

    if (is_dir) {
        _ = wf.step.addDirectoryWatchInput(lp) catch {};
    } else {
        wf.step.addWatchInput(lp) catch {};
    }

    return .{ .step = &wf.step, .directory = wf.getDirectory(), .file_zig = file_zig, .file_bin = file_bin, .bundle_path = options.bundle_path };
}

fn generateBinarySync(b: *std.Build, assets_path: []const u8, relative_prefix: []const u8, options: BinaryGenOptions) !binary_builder.BundleResult {
    const gpa = b.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var is_dir = false;
    if (std.Io.Dir.cwd().openDir(io, assets_path, .{ .iterate = true })) |*d| {
        var dir = d.*;
        dir.close(io);
        is_dir = true;
    } else |_| is_dir = false;

    if (is_dir) {
        const res = try binary_builder.bakeBinaryBundleToMemoryWithIo(gpa, io, assets_path, relative_prefix, .{
            .descriptors = options.descriptors,
            .bundle_path = options.bundle_path,
            .print_results = options.print_results,
        });
        return res;
    } else {
        // Single file: create synthetic tree with one node, pack manually
        // For simplicity, treat parent dir as assets_dir and filter to single file
        // Alternative: directly read the file and produce minimal mapper
        const data = blk: {
            var cwd = std.Io.Dir.cwd();
            var file = try cwd.openFile(io, assets_path, .{});
            defer file.close(io);
            const stat = try file.stat(io);
            const sz: usize = @intCast(stat.size);
            const buf = try gpa.alloc(u8, sz);
            errdefer gpa.free(buf);
            var total: usize = 0;
            while (total < sz) {
                const n = try file.readStreaming(io, &.{buf[total..]});
                if (n == 0) break;
                total += n;
            }
            break :blk buf[0..total];
        };
        defer gpa.free(data);
        // Generate code for single asset as top-level const with header alias
        const basename = std.fs.path.basename(assets_path);
        const ident = try @import("text_utils.zig").filenameToIdentifier(gpa, basename);
        defer gpa.free(ident);
        var escaped = std.ArrayList(u8).empty;
        defer escaped.deinit(gpa);
        for (options.bundle_path) |ch| {
            switch (ch) {
                '\\' => try escaped.appendSlice(gpa, "\\\\"),
                '"' => try escaped.appendSlice(gpa, "\\\""),
                '\n' => try escaped.appendSlice(gpa, "\\n"),
                '\r' => {},
                else => try escaped.append(gpa, ch),
            }
        }
        const header = "const Asset = @import(\"assets_manager\").asset_loader.Asset;\n\n";
        const body = try std.fmt.allocPrint(gpa, "pub const {s} = Asset(u8, \"{s}\", 0, {d});\n", .{ ident, escaped.items, data.len });
        defer gpa.free(body);
        const code = try std.fmt.allocPrint(gpa, "{s}{s}", .{ header, body });
        const bin = try gpa.dupe(u8, data);
        return .{ .code = code, .bin = bin };
    }
}
