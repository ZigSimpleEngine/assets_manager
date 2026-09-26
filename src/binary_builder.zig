/// Standard library for filesystem access, sorting and the `std.process.Init` plumbing.
const std = @import("std");
/// Tree model walked and packed by every bake function below.
const assets_tree = @import("assets_tree.zig");

/// Alias for the tree node type, avoiding the `assets_tree.` prefix in signatures.
const Node = assets_tree.Node;
/// Vtable type implemented by `RawBinaryDescriptor` and `BinaryDirectoryDescriptor`.
/// Each entry knows how to extract bytes (`getData`) and which loader mapping (`mapping`) emits its code.
const BinaryDescriptor = @import("binary_descriptors.zig").abstract.BinaryDescriptor;

/// Header prepended to every generated loader map.
/// Declares the file-local `Asset` alias so emitted `Asset(u8, path, offset, size)` lines compile
/// without the consumer importing `asset_loader` manually. Checked by `prependHeader` before prepending.
const binary_header = "const std = @import(\"std\");\nconst Asset = @import(\"assets_manager\").asset_loader.Asset;\n\n";

/// In-memory result of a binary bake.
/// Holds two independently owned slices produced by `bakeBinaryBundleToMemoryWithIo` and returned
/// through `build_steps_binary.generateSync` into `WriteFiles`; both must be freed by the caller.
pub const BundleResult = struct {
    /// Generated Zig loader map referencing slices of the bundle via `Asset(u8, ...)`.
    code: []u8,
    /// Packed raw bytes of every leaf asset in deterministic `Node.lessThan` order.
    bin: []u8,
};

/// Bundle options shared by the filesystem and in-memory binary paths.
/// Carries the descriptor table, the runtime bundle location embedded into `Asset(...)` lines,
/// and a debug-print toggle used by `createBinaryBundleFromAssets`.
pub const Config = struct {
    /// Enables stdout dumps of the bundle mapping and byte counts for manual inspection.
    print_results: bool = false,
    /// Runtime location baked into generated `Asset(u8, bundle_path, ...)` references.
    /// Desktop uses a cwd-relative path, wasm uses the virtual-FS path.
    bundle_path: []const u8 = "assets.bin",
    /// Ordered vtable table consulted for every node; first `isSuitableData` hit wins.
    /// Typically raw-file plus binary-directory descriptors from `descriptors.binary`.
    descriptors: []const *const BinaryDescriptor,
};

/// Filesystem bundle creation writing both the loader map and the packed `.bin` file.
/// Builds the tree with `assets_tree.create`, packs leaves with `bakeBinaryTreeToCode`,
/// then persists both artifacts. Used for manual runs; build steps prefer the in-memory bake.
/// - `init` - process init for walking, allocation and file output.
/// - `code_output_path` - destination Zig loader map; its directory decides the relative asset prefix.
/// - `bin_output_path` - destination packed bundle file.
/// - `assets_dir` - directory walked for asset files.
/// - `config` - bundle path, descriptor table and optional result printing.
pub fn createBinaryBundleFromAssets(init: std.process.Init, code_output_path: []const u8, bin_output_path: []const u8, assets_dir: []const u8, config: Config) !void {
    const gpa = init.gpa;
    var root = try assets_tree.create(init, assets_dir);
    defer root.deinitRecursively(gpa, true);

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

    const raw_code = try bakeBinaryTreeToCode(
        init,
        relative_path_formated,
        config.bundle_path,
        root,
        0,
        config,
        &binary,
        &offset,
    );
    defer gpa.free(raw_code);
    const code = try prependHeader(gpa, raw_code);
    defer gpa.free(code);

    try writeBinFile(init, bin_output_path, binary.items);
    try writeFile(init, code_output_path, code);

    if (config.print_results) {
        std.debug.print("Bundle bytes: {d} assets, {d} bytes total\n", .{ root.children.count(), binary.items.len });
        std.debug.print("{s}\n", .{code});
    }
}

/// In-memory bundle bake using explicit threaded IO.
/// Builds the tree, packs it with `bakeBinaryTreeToCodeWithIo`, and returns both owned slices.
/// Used by `build_steps_binary.generateSync` to feed `WriteFiles` without touching disk.
/// - `gpa` - allocator for the tree, bundle bytes and loader source.
/// - `io` - threaded IO for directory iteration.
/// - `assets_dir` - directory walked for asset files.
/// - `relative_path_formated` - filesystem prefix used to open real files during packing.
/// - `config` - bundle path, descriptor table and debug flags.
///
/// Return: owned `BundleResult`; caller must free both `code` and `bin`.
pub fn bakeBinaryBundleToMemoryWithIo(gpa: std.mem.Allocator, io: std.Io, assets_dir: []const u8, relative_path_formated: []const u8, config: Config) !BundleResult {
    var root = try assets_tree.createWithIo(gpa, io, assets_dir);
    defer root.deinitRecursively(gpa, true);

    var binary: std.ArrayList(u8) = .empty;
    errdefer binary.deinit(gpa);
    var offset: usize = 0;
    const raw_code = try bakeBinaryTreeToCodeWithIo(gpa, io, relative_path_formated, config.bundle_path, root, 0, config, &binary, &offset);
    errdefer gpa.free(raw_code);
    const code = try prependHeader(gpa, raw_code);
    gpa.free(raw_code);
    errdefer gpa.free(code);
    const bin = try binary.toOwnedSlice(gpa);
    return .{ .code = code, .bin = bin };
}

/// In-memory bundle bake behind the ambient process IO.
/// Adapter over `bakeBinaryBundleToMemoryWithIo` for callers holding a `std.process.Init`.
/// - `init` - process init providing allocator and IO.
/// - `assets_dir` - directory walked for asset files.
/// - `relative_path_formated` - filesystem prefix used to open real files.
/// - `config` - bundle path, descriptor table and debug flags.
///
/// Return: owned `BundleResult`; caller must free both slices.
pub fn bakeBinaryBundleToMemory(init: std.process.Init, assets_dir: []const u8, relative_path_formated: []const u8, config: Config) !BundleResult {
    return bakeBinaryBundleToMemoryWithIo(init.gpa, init.io, assets_dir, relative_path_formated, config);
}

/// Writes packed bundle bytes to disk, creating parent directories as needed.
/// Called by `createBinaryBundleFromAssets` for the `.bin` artifact.
/// - `init` - process init providing IO.
/// - `path` - working-directory-relative bundle destination.
/// - `data` - packed bytes accumulated by `bakeBinaryTreeToCode`.
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

/// Recursive packing adapter using explicit threaded IO.
/// Forwards to `bakeBinaryTreeToCode` for build-step contexts that split allocator and IO.
/// - `gpa` - allocator for sorting buffers and emitted code.
/// - `io` - threaded IO (carried inside a synthetic `Init`).
/// - `path_to_root_node` - filesystem prefix for opening real asset files.
/// - `bundle_path` - runtime location embedded into generated `Asset(...)` lines.
/// - `assets_tree_root` - subtree being packed at this recursion level.
/// - `depth` - indentation depth forwarded to descriptors.
/// - `config` - descriptor table driving per-node packing and codegen.
/// - `binary` - append-only bundle accumulator advanced in deterministic order.
/// - `offset` - running byte offset updated as leaves are appended.
///
/// Return: owned source for this subtree; caller must free it.
fn bakeBinaryTreeToCodeWithIo(gpa: std.mem.Allocator, io: std.Io, path_to_root_node: []const u8, bundle_path: []const u8, assets_tree_root: *Node, depth: u32, config: Config, binary: *std.ArrayList(u8), offset: *usize) ![]u8 {
    var dummy: std.process.Init = undefined;
    dummy.gpa = gpa;
    dummy.io = io;
    return bakeBinaryTreeToCode(dummy, path_to_root_node, bundle_path, assets_tree_root, depth, config, binary, offset);
}

/// Recursively packs a `Node` hierarchy into bundle bytes plus loader source.
/// Sorts children with `Node.lessThan`, appends leaf bytes from `getData` into `binary`,
/// tracks `offset`/`size` per leaf, then delegates code emission to the suitable mapping descriptor.
/// Backs every binary entry point; directories recurse first so child code exists before the parent struct.
/// - `init` - process init carrying allocator and IO.
/// - `path_to_root_node` - filesystem prefix for opening real asset files.
/// - `bundle_path` - runtime location embedded into generated `Asset(...)` lines.
/// - `assets_tree_root` - subtree being packed at this recursion level.
/// - `depth` - indentation depth forwarded to descriptors.
/// - `config` - descriptor table driving per-node packing and codegen.
/// - `binary` - append-only bundle accumulator.
/// - `offset` - running byte offset into `binary`, advanced by each packed leaf.
///
/// Return: owned source for this subtree; caller must free it.
fn bakeBinaryTreeToCode(init: std.process.Init, path_to_root_node: []const u8, bundle_path: []const u8, assets_tree_root: *Node, depth: u32, config: Config, binary: *std.ArrayList(u8), offset: *usize) ![]u8 {
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
                const code = try desc.getCode(init, data);
                defer gpa.free(code);
                try str_list.appendSlice(gpa, code);
            } else {
                return error.NoSuitableDescriptorForNode;
            }
        } else {
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
                const code = try desc.getCode(init, d);
                defer gpa.free(code);
                try str_list.appendSlice(gpa, code);
            } else {
                return error.NoSuitableDescriptorForNode;
            }
        }
    }

    return str_list.toOwnedSlice(gpa);
}

/// Prepends `binary_header` to generated code unless it is already present.
/// Guarantees every loader map compiles standalone by declaring the file-local `Asset` alias exactly once.
/// Called at the end of both filesystem and in-memory bakes before returning or persisting `code`.
/// - `gpa` - allocator owning the returned slice.
/// - `code` - raw concatenated descriptor output for one bake.
///
/// Return: owned source starting with `binary_header`; caller must free it.
fn prependHeader(gpa: std.mem.Allocator, code: []const u8) ![]u8 {
    if (code.len >= binary_header.len and std.mem.startsWith(u8, code, binary_header)) return gpa.dupe(u8, code);
    const out = try gpa.alloc(u8, binary_header.len + code.len);
    @memcpy(out[0..binary_header.len], binary_header);
    @memcpy(out[binary_header.len..], code);
    return out;
}

/// Writes a generated Zig loader map to disk, creating parent directories as needed.
/// Called by `createBinaryBundleFromAssets` for the `*.zig` side of the bundle.
/// - `init` - process init providing IO.
/// - `path` - working-directory-relative destination for the loader source.
/// - `text` - complete generated source including `binary_header`.
fn writeFile(init: std.process.Init, path: []const u8, text: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| {
        try cwd.createDirPath(init.io, dir);
    }
    const file = try cwd.createFile(init.io, path, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, text);
}
