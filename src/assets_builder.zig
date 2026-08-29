const std = @import("std");
const mem = std.mem;
const text_utils = @import("text_utils.zig");
const assets_tree = @import("assets_tree.zig");
const Node = assets_tree.Node;
const Descriptor = @import("descriptors.zig").Descriptor;

pub fn writeFile(init: std.process.Init, path: []const u8, text: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    if (std.fs.path.dirname(path)) |dir| {
        try cwd.createDirPath(init.io, dir);
    }

    const file = try cwd.createFile(init.io, path, .{});
    defer file.close(init.io);

    try file.writeStreamingAll(init.io, text);
}

pub const Config = struct {
    print_results: bool = false,
    descriptors: []const *const Descriptor,
};

pub fn bakeAssetsTreeToCodeWithIo(
    gpa: std.mem.Allocator,
    io: std.Io,
    path_to_root_node: []const u8,
    assets_tree_root: *Node,
    depth: u32,
    config: Config,
) ![]u8 {
    var dummy: std.process.Init = undefined;
    dummy.gpa = gpa;
    dummy.io = io;
    return bakeAssetsTreeToCode(dummy, path_to_root_node, assets_tree_root, depth, config);
}

pub fn bakeAssetsTreeToCode(
    init: std.process.Init,
    path_to_root_node: []const u8,
    assets_tree_root: *Node,
    depth: u32,
    config: Config,
) ![]u8 {
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

        const descripting_data: Descriptor.Data = .{
            .id_in_parent = @intCast(i),
            .depth = depth,
            .node = node,
            .content = content,
            .path_to_root_node = path_to_root_node,
        };

        var suitable_descriptor: ?*const Descriptor = null;
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

pub fn createCodeFileFromAssets(
    init: std.process.Init,
    file_path: []const u8,
    assets_dir: []const u8,
    config: Config,
) !void {
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
