/// Standard library for the `std.Build` API and threaded IO setup.
const std = @import("std");
/// In-memory and filesystem bundle functions wrapped by the build step below.
const binary_builder = @import("binary_builder.zig");

/// Vtable type implemented by `RawBinaryDescriptor` and `BinaryDirectoryDescriptor`.
const BinaryDescriptor = @import("binary_descriptors.zig").abstract.BinaryDescriptor;

/// Lazy build outputs for one binary generation.
/// Returned by `addGeneration` so downstream steps can depend on the directory, loader map and bundle bytes.
pub const Result = struct {
    /// WriteFiles step producing the outputs; wired with watch inputs for incremental rebuilds.
    step: *std.Build.Step,
    /// Directory containing both generated files; added as a dependency of compile steps.
    directory: std.Build.LazyPath,
    /// Generated Zig loader map referencing bundle slices via `Asset(u8, ...)`.
    file_zig: std.Build.LazyPath,
    /// Packed raw bundle bytes loaded at runtime through `asset_loader.Asset`.
    file_bin: std.Build.LazyPath,
    /// Runtime bundle location embedded into the loader map; forwarded from `Config.bundle_path`.
    bundle_path: []const u8,
};

/// User configuration for one binary generation.
/// Passed to `addGeneration` from a consumer `build.zig`; mirrors `binary_builder.Config`
/// plus the on-disk locations needed only at build time.
pub const Config = struct {
    /// Name of the generated Zig loader map inside the WriteFiles directory.
    output_name_zig: []const u8 = "assets.zig",
    /// Name of the packed bundle file inside the WriteFiles directory.
    output_name_bin: []const u8 = "assets.bin",
    /// Runtime location embedded into generated `Asset(u8, bundle_path, ...)` references.
    bundle_path: []const u8 = "assets.bin",
    /// Enables stdout dumps of the bundle mapping for manual inspection.
    print_results: bool = false,
    /// Asset file or directory relative to the build root; watched for incremental rebuilds.
    assets_path: []const u8,
    /// Ordered descriptor table consulted for every node during packing.
    descriptors: []const *const BinaryDescriptor,
};

/// Creates a WriteFiles step generating a binary bundle plus its Zig loader map.
/// Handles both recursive directories and single files, registers watch inputs,
/// and returns `Result` with `LazyPath`s. Failures emit placeholder files instead of panicking.
/// - `b` - build graph owning the new WriteFiles step.
/// - `options` - assets location, output names, bundle path, descriptor table and debug flags.
///
/// Return: step plus lazy directory, loader and bundle handles for downstream dependencies.
pub fn addGeneration(b: *std.Build, options: Config) Result {
    const wf = b.addWriteFiles();
    wf.step.name = b.fmt("binarygen {s} -> {s} + {s}", .{ options.assets_path, options.output_name_zig, options.output_name_bin });

    var relative_prefix: []const u8 = "";
    var allocated: ?[]const u8 = null;
    {
        const with_slash = std.fmt.allocPrint(b.allocator, "{s}/", .{options.assets_path}) catch "";
        allocated = with_slash;
        relative_prefix = with_slash;
    }

    const result = generateSync(b, options.assets_path, relative_prefix, options) catch |err| {
        std.debug.print("addGeneration (binary) failed for {s}: {t}\n", .{ options.assets_path, err });
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

/// Synchronously bakes a bundle plus loader map for configure-time generation.
/// Opens a threaded IO pool and branches on directory versus single file.
/// Directories delegate to `binary_builder`; single files are read directly and wrapped in a minimal `Asset` map.
/// Used only by `addGeneration`.
/// - `b` - build graph providing the allocator.
/// - `assets_path` - file or directory being packed.
/// - `relative_prefix` - filesystem prefix used to open real files.
/// - `options` - bundle path, descriptor table and debug flags forwarded to the builder.
///
/// Return: owned `BundleResult` with `code` and `bin`; caller must free both slices.
fn generateSync(b: *std.Build, assets_path: []const u8, relative_prefix: []const u8, options: Config) !binary_builder.BundleResult {
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
