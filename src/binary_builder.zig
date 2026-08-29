const std = @import("std");
const assets_tree = @import("assets_tree.zig");
const Node = assets_tree.Node;
const BinaryDescriptor = @import("binary_descriptors.zig").BinaryDescriptor;

pub const BinaryConfig = struct {
    print_results: bool = false,
    descriptors: []const *const BinaryDescriptor,
    bundle_path: []const u8 = "assets.bin",
};

fn writeBinFile(init: std.process.Init, path: []const u8, data: []const u8) !void {
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| {
        try cwd.createDirPath(io, dir);
    }
    const file = try cwd.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

fn bakeBinaryTreeToCodeWithIo(
    gpa: std.mem.Allocator,
    io: std.Io,
    path_to_root_node: []const u8,
    bundle_path: []const u8,
    assets_tree_root: *Node,
    depth: u32,
    config: BinaryConfig,
    binary: *std.ArrayList(u8),
    offset: *usize,
) ![]u8 {
    var dummy: std.process.Init = undefined;
    dummy.gpa = gpa;
    dummy.io = io;
    return bakeBinaryTreeToCode(dummy, path_to_root_node, bundle_path, assets_tree_root, depth, config, binary, offset);
}

// Recursive helper that traverses tree, packs binary data sequentially,
// and returns generated Zig code for this subtree.
// `offset` is passed by reference and advances as we pack leaves.
fn bakeBinaryTreeToCode(
    init: std.process.Init,
    path_to_root_node: []const u8,
    bundle_path: []const u8,
    assets_tree_root: *Node,
    depth: u32,
    config: BinaryConfig,
    binary: *std.ArrayList(u8),
    offset: *usize,
) ![]u8 {
    var str_list: std.ArrayList(u8) = .empty;
    const gpa = init.gpa;
    errdefer str_list.deinit(gpa);

    var children: std.ArrayList(*Node) = .empty;
    defer children.deinit(gpa);
    var it = assets_tree_root.children.iterator();
    while (it.next()) |entry| {
        try children.append(gpa, entry.value_ptr.*);
    }
    std.mem.sort(*Node, children.items, {}, Node.lessThan);

    for (children.items, 0..) |node, i| {
        const node_path = try node.createPath(gpa);
        defer gpa.free(node_path);
        const full_path = if (path_to_root_node.len == 0) node_path else try std.fs.path.join(gpa, &.{ path_to_root_node, node_path });
        defer if (path_to_root_node.len != 0) gpa.free(full_path);
        const effective_path = if (path_to_root_node.len == 0) node_path else full_path;

        if (!node.isLeaf()) {
            // Directory: recurse first to get child content
            const child_content = try bakeBinaryTreeToCode(init, path_to_root_node, bundle_path, node, depth + 1, config, binary, offset);
            defer gpa.free(child_content);

            const data: BinaryDescriptor.Data = .{
                .id_in_parent = @intCast(i),
                .depth = depth,
                .node = node,
                .content = child_content,
                .path_to_root_node = path_to_root_node,
                .bundle_path = bundle_path,
                .offset = 0,
                .size = 0,
            };
            var suitable: ?*const BinaryDescriptor = null;
            for (config.descriptors) |desc| {
                if (try desc.isSuitableData(init, node)) {
                    suitable = desc;
                    break;
                }
            }
            if (suitable) |desc| {
                const code = try desc.getLoaderCode(init, data);
                defer gpa.free(code);
                try str_list.appendSlice(gpa, code);
            } else {
                return error.NoSuitableDescriptorForNode;
            }
        } else {
            // Leaf file: find descriptor, extract data, pack into binary, then generate loader code
            var suitable: ?*const BinaryDescriptor = null;
            for (config.descriptors) |desc| {
                if (try desc.isSuitableData(init, node)) {
                    suitable = desc;
                    break;
                }
            }
            if (suitable) |desc| {
                const data_bytes = try desc.getData(init, effective_path);
                defer {
                    desc.deinitData(init, data_bytes);
                }
                const cur_offset = offset.*;
                const cur_size = data_bytes.len;
                try binary.appendSlice(gpa, data_bytes);
                offset.* += cur_size;

                const d: BinaryDescriptor.Data = .{
                    .id_in_parent = @intCast(i),
                    .depth = depth,
                    .node = node,
                    .content = null,
                    .path_to_root_node = path_to_root_node,
                    .bundle_path = bundle_path,
                    .offset = cur_offset,
                    .size = cur_size,
                };
                const code = try desc.getLoaderCode(init, d);
                defer gpa.free(code);
                try str_list.appendSlice(gpa, code);
            } else {
                return error.NoSuitableDescriptorForNode;
            }
        }
    }

    return str_list.toOwnedSlice(gpa);
}

pub fn createBinaryBundleFromAssets(
    init: std.process.Init,
    code_output_path: []const u8,
    bin_output_path: []const u8,
    assets_dir: []const u8,
    config: BinaryConfig,
) !void {
    const gpa = init.gpa;
    var root = try assets_tree.create(init, assets_dir);
    defer root.deinitRecursively(gpa, true);

    // Determine relative path prefix for createPath resolving.
    // Similar to createCodeFileFromAssets: relative from output dir to assets_dir.
    var relative_path_formated: []const u8 = "";
    var need_free_relative = false;
    var allocated_relative: []u8 = &.{};
    var allocated_formated: []u8 = &.{};
    if (std.fs.path.dirname(code_output_path)) |dir| {
        const rel = try std.fs.path.relativePosix(gpa, ".", dir, assets_dir);
        allocated_relative = rel;
        const formated = try std.fmt.allocPrint(gpa, "{s}/", .{rel});
        allocated_formated = formated;
        relative_path_formated = formated;
        need_free_relative = true;
    }
    defer if (need_free_relative) {
        gpa.free(allocated_relative);
        gpa.free(allocated_formated);
    };

    if (config.print_results) std.debug.print("Binary bundle \"{s}\" -> \"{s}\" + \"{s}\"\n", .{ assets_dir, code_output_path, bin_output_path });

    var binary: std.ArrayList(u8) = .empty;
    defer binary.deinit(gpa);
    var offset: usize = 0;

    const code = try bakeBinaryTreeToCode(
        init,
        relative_path_formated,
        config.bundle_path,
        root,
        0,
        config,
        &binary,
        &offset,
    );
    defer gpa.free(code);

    try writeBinFile(init, bin_output_path, binary.items);
    try writeFile(init, code_output_path, code);

    if (config.print_results) {
        std.debug.print("Bundle bytes: {d} assets, {d} bytes total\n", .{ root.children.count(), binary.items.len });
        std.debug.print("{s}\n", .{code});
    }
}

fn writeFile(init: std.process.Init, path: []const u8, text: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| {
        try cwd.createDirPath(init.io, dir);
    }
    const file = try cwd.createFile(init.io, path, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, text);
}

pub const BundleResult = struct { code: []u8, bin: []u8 };

pub fn bakeBinaryBundleToMemoryWithIo(
    gpa: std.mem.Allocator,
    io: std.Io,
    assets_dir: []const u8,
    relative_path_formated: []const u8,
    config: BinaryConfig,
) !BundleResult {
    var root = try assets_tree.createWithIo(gpa, io, assets_dir);
    defer root.deinitRecursively(gpa, true);

    var binary: std.ArrayList(u8) = .empty;
    errdefer binary.deinit(gpa);
    var offset: usize = 0;
    const code = try bakeBinaryTreeToCodeWithIo(gpa, io, relative_path_formated, config.bundle_path, root, 0, config, &binary, &offset);
    errdefer gpa.free(code);
    const bin = try binary.toOwnedSlice(gpa);
    return .{ .code = code, .bin = bin };
}

/// Synchronous in-memory variant that returns owned slices without touching
/// filesystem. Useful for build steps that use `addWriteFiles`.
pub fn bakeBinaryBundleToMemory(
    init: std.process.Init,
    assets_dir: []const u8,
    relative_path_formated: []const u8,
    config: BinaryConfig,
) !BundleResult {
    return bakeBinaryBundleToMemoryWithIo(init.gpa, init.io, assets_dir, relative_path_formated, config);
}

pub fn bakeCodeToMemoryWithIo(
    gpa: std.mem.Allocator,
    io: std.Io,
    assets_dir: []const u8,
    relative_path_formated: []const u8,
    descriptors: []const *const @import("descriptors.zig").Descriptor,
) ![]u8 {
    var root = try assets_tree.createWithIo(gpa, io, assets_dir);
    defer root.deinitRecursively(gpa, true);
    return @import("assets_builder.zig").bakeAssetsTreeToCodeWithIo(gpa, io, relative_path_formated, root, 0, .{ .descriptors = descriptors });
}

pub fn bakeCodeToMemory(
    init: std.process.Init,
    assets_dir: []const u8,
    relative_path_formated: []const u8,
    descriptors: []const *const @import("descriptors.zig").Descriptor,
) ![]u8 {
    return bakeCodeToMemoryWithIo(init.gpa, init.io, assets_dir, relative_path_formated, descriptors);
}
