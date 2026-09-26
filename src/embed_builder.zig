/// Standard library for filesystem access, sorting and the `std.process.Init` plumbing.
const std = @import("std");
/// Tree model walked by every bake function below.
const assets_tree = @import("assets_tree.zig");

/// Alias for the tree node type, avoiding the `assets_tree.` prefix in signatures.
const Node = assets_tree.Node;
/// Vtable type implemented by `EmbedFileDescriptor` and `EmbedDirectoryDescriptor`.
/// Selected per node via `isSuitableData` and invoked via `getCode` during the recursive walk.
const EmbedDescriptor = @import("embed_descriptors.zig").abstract.EmbedDescriptor;

/// Codegen options shared by the filesystem and in-memory embed paths.
/// Carries the descriptor table plus a debug-print toggle used by `createCodeFileFromAssets`.
pub const Config = struct {
    /// Enables stdout dumps of the walked directory and the emitted source for manual inspection.
    print_results: bool = false,
    /// Ordered vtable table consulted for every node; first `isSuitableData` hit wins.
    /// Typically file plus directory descriptors from `descriptors.embed`.
    descriptors: []const *const EmbedDescriptor,
};

/// Writes generated Zig source to disk, creating parent directories as needed.
/// Used by `createCodeFileFromAssets` for the final `*.zig` artifact; the binary backend has its own twin.
/// - `init` - process init providing IO and the allocator-free path helpers.
/// - `path` - working-directory-relative output file.
/// - `text` - complete generated source to persist.
///
/// Return: void on success, otherwise an IO error.
pub fn writeFile(init: std.process.Init, path: []const u8, text: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    if (std.fs.path.dirname(path)) |dir| {
        try cwd.createDirPath(init.io, dir);
    }

    const file = try cwd.createFile(init.io, path, .{});
    defer file.close(init.io);

    try file.writeStreamingAll(init.io, text);
}

/// In-memory codegen using explicit threaded IO.
/// Adapter over `bakeAssetsTreeToCode` for build-step contexts that already split allocator and IO.
/// Used by `bakeCodeToMemoryWithIo` and `build_steps_embed.generateSync`.
/// - `gpa` - allocator for the tree, sorting buffer and emitted source.
/// - `io` - threaded IO used for directory iteration.
/// - `path_to_root_node` - prefix prepended to every `@embedFile` path so generated files resolve correctly.
/// - `assets_tree_root` - hierarchy built by `assets_tree.createWithIo`.
/// - `depth` - starting indentation level, always `0` for top-level calls.
/// - `config` - descriptor table selecting per-node emitters.
///
/// Return: owned source slice; caller must free it.
pub fn bakeAssetsTreeToCodeWithIo(gpa: std.mem.Allocator, io: std.Io, path_to_root_node: []const u8, assets_tree_root: *Node, depth: u32, config: Config) ![]u8 {
    var dummy: std.process.Init = undefined;
    dummy.gpa = gpa;
    dummy.io = io;
    return bakeAssetsTreeToCode(dummy, path_to_root_node, assets_tree_root, depth, config);
}

/// Recursively renders a `Node` hierarchy as Zig source.
/// Sorts children with `Node.lessThan` for deterministic output, recurses into directories,
/// then delegates each node to the first suitable `EmbedDescriptor`. Backs every embed entry point.
/// - `init` - process init carrying allocator and IO.
/// - `path_to_root_node` - prefix for `@embedFile` paths, computed from output versus assets locations.
/// - `assets_tree_root` - subtree being rendered at this recursion level.
/// - `depth` - indentation depth forwarded to descriptors.
/// - `config` - descriptor table driving per-node codegen.
///
/// Return: owned source for this subtree; caller must free it.
pub fn bakeAssetsTreeToCode(init: std.process.Init, path_to_root_node: []const u8, assets_tree_root: *Node, depth: u32, config: Config) ![]u8 {
    var str_list: std.ArrayList(u8) = .empty;
    const gpa = init.gpa;
    errdefer str_list.deinit(gpa);

    var map_it = assets_tree_root.children.iterator();
    var children: std.ArrayList(*Node) = .empty;
    defer children.deinit(gpa);

    while (map_it.next()) |entry| {
        try children.append(gpa, entry.value_ptr.*);
    }
    std.mem.sort(*Node, children.items, {}, Node.lessThan);
    for (children.items, 0..) |node, i| {
        var content: ?[]u8 = null;
        defer if (content) |c| gpa.free(c);
        if (!node.isLeaf()) {
            content = try bakeAssetsTreeToCode(
                init,
                path_to_root_node,
                node,
                depth + 1,
                config,
            );
        }

        const descripting_data: EmbedDescriptor.Data = .{
            .id_in_parent = @intCast(i),
            .depth = depth,
            .node = node,
            .content = content,
            .path_to_root_node = path_to_root_node,
        };

        var suitable_descriptor: ?*const EmbedDescriptor = null;
        for (config.descriptors) |descriptor| {
            if (try descriptor.isSuitableData(init, descripting_data)) {
                suitable_descriptor = descriptor;
                break;
            }
        }

        if (suitable_descriptor) |descriptor| {
            const code = try descriptor.getCode(init, descripting_data);
            defer gpa.free(code);

            try str_list.appendSlice(gpa, code);
        } else {
            return error.NoSuitableDescriptorForNode;
        }
    }

    return str_list.toOwnedSlice(gpa);
}

/// Filesystem codegen writing one `*.zig` file from an assets directory.
/// Builds the tree with `assets_tree.create`, derives the `@embedFile` prefix with `relativePosix`,
/// then persists the baked source with `writeFile`. Used by `run.zig` for `generated/src.zig`.
/// - `init` - process init for walking, allocation and file output.
/// - `file_path` - destination Zig file; its directory decides the relative embed prefix.
/// - `assets_dir` - directory walked for asset files.
/// - `config` - descriptor table plus optional result printing.
pub fn createCodeFileFromAssets(init: std.process.Init, file_path: []const u8, assets_dir: []const u8, config: Config) !void {
    const gpa = init.gpa;
    var root = try assets_tree.create(init, assets_dir);
    defer root.deinitRecursively(gpa, true);

    var relative_path = assets_dir;
    var relative_path_formated = relative_path;
    var free_relative_path = false;
    if (std.fs.path.dirname(file_path)) |dir| {
        relative_path = try std.fs.path.relativePosix(gpa, ".", dir, assets_dir);
        relative_path_formated = try std.fmt.allocPrint(gpa, "{s}/", .{relative_path});
        free_relative_path = true;
    }

    defer if (free_relative_path) {
        gpa.free(relative_path);
        gpa.free(relative_path_formated);
    };

    if (config.print_results) std.debug.print("Asset \"{s}\": \n", .{assets_dir});
    const toStructText_result = try bakeAssetsTreeToCode(
        init,
        relative_path_formated,
        root,
        0,
        config,
    );
    try writeFile(init, file_path, toStructText_result);
    defer gpa.free(toStructText_result);
    if (config.print_results) std.debug.print("{s}\n", .{toStructText_result});
}

/// In-memory codegen using explicit threaded IO.
/// Builds the tree, bakes it with `bakeAssetsTreeToCodeWithIo`, and returns the owned source.
/// Used by `build_steps_embed.generateSync` to feed `WriteFiles` without touching disk.
/// - `gpa` - allocator for the tree and emitted source.
/// - `io` - threaded IO for directory iteration.
/// - `assets_dir` - directory walked for asset files.
/// - `relative_path_formated` - `@embedFile` prefix including the trailing slash.
/// - `descriptors` - ordered descriptor table consulted per node.
///
/// Return: owned Zig source; caller must free it.
pub fn bakeCodeToMemoryWithIo(gpa: std.mem.Allocator, io: std.Io, assets_dir: []const u8, relative_path_formated: []const u8, descriptors: []const *const EmbedDescriptor) ![]u8 {
    var root = try assets_tree.createWithIo(gpa, io, assets_dir);
    defer root.deinitRecursively(gpa, true);
    return bakeAssetsTreeToCodeWithIo(gpa, io, relative_path_formated, root, 0, .{ .descriptors = descriptors });
}

/// In-memory codegen behind the ambient process IO.
/// Adapter over `bakeCodeToMemoryWithIo` for callers that already hold a `std.process.Init`.
/// - `init` - process init providing allocator and IO.
/// - `assets_dir` - directory walked for asset files.
/// - `relative_path_formated` - `@embedFile` prefix including the trailing slash.
/// - `descriptors` - ordered descriptor table consulted per node.
///
/// Return: owned Zig source; caller must free it.
pub fn bakeCodeToMemory(init: std.process.Init, assets_dir: []const u8, relative_path_formated: []const u8, descriptors: []const *const EmbedDescriptor) ![]u8 {
    return bakeCodeToMemoryWithIo(init.gpa, init.io, assets_dir, relative_path_formated, descriptors);
}
