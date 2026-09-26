/// Standard library for hash maps, directory walking and the `std.Io`/`std.process.Init` plumbing.
const std = @import("std");
/// String helpers used by `Node.toString` to repeat `depth_prefix` per tree depth.
const text_utils = @import("text_utils.zig");

/// Short alias for `std.mem`, used for `Allocator` and `lessThan` throughout this module.
const mem = std.mem;

/// In-memory filesystem hierarchy shared by the embed and binary backends.
/// Built by `create`/`createWithIo` from a directory walk, then consumed by builders that sort children
/// with `lessThan` and resolve on-disk locations with `createPath`. Heap nodes are created with
/// `initHeap` and released with `deinitRecursively`; the `root` node itself carries no name.
pub const Node = struct {
    /// Owned file or directory base name, or `null` for the synthetic root.
    /// Duplicated with `gpa.dupe` during `createWithIo`; freed by `deinitRecursively`.
    name: ?[]const u8,
    /// Child nodes keyed by the same owned name slice stored in `name`.
    /// Backs `isLeaf`, `lessThan` sorting in builders, and recursive code generation.
    children: std.StringHashMap(*Node),
    /// Discriminant deciding whether this node packs bytes, emits a struct, or is the invisible root.
    /// Selected in `createWithIo` from the walker position and matched by descriptors.
    kind: Kind,
    /// Link to the containing directory, `null` only for the root.
    /// Walked upwards by `createPath` to rebuild the relative filesystem path.
    parent: ?*const Node,

    /// Prefix repeated `depth` times by `toString` when pretty-printing nested levels.
    /// Mutable global so debug dumps can switch style without touching call sites.
    pub var depth_prefix = "----";

    /// Role of a `Node` inside the hierarchy.
    /// Chosen during `createWithIo` and later used by descriptors (`file` versus `directory`),
    /// by `lessThan` for deterministic ordering, and by `getSeparator` when joining paths.
    pub const Kind = enum {
        /// Synthetic container returned by `create`/`createWithIo`; never maps to a real file.
        root,
        /// Leaf holding packable or embeddable bytes; `isLeaf` reports true exactly for these nodes.
        file,
        /// Intermediate node whose generated code is the concatenation of its children's code.
        directory,

        /// Separator fragment contributed by one path component in `Node.createPath`.
        /// Returns `"/"` for directories and `""` otherwise so joined names form a relative path.
        /// - `self` - kind of the ancestor component currently being prepended.
        ///
        /// Return: separator slice; never owned.
        pub fn getSeparator(self: Kind) []const u8 {
            return switch (self) {
                .root => "",
                .directory => "/",
                .file => "",
            };
        }
    };

    /// Recursively frees the subtree without freeing sibling pointers held by the caller.
    /// Destroys every descendant map, frees each owned `name`, and optionally destroys the heap nodes.
    /// Called with `destroy_nodes = true` by builders after code generation to release the whole walk.
    /// - `self` - subtree root being torn down; its own storage is destroyed only when `destroy_nodes` is set.
    /// - `allocator` - allocator that created the nodes, maps and name copies.
    /// - `destroy_nodes` - when true also calls `allocator.destroy` on every visited node including `self`.
    pub fn deinitRecursively(self: *Node, allocator: std.mem.Allocator, destroy_nodes: bool) void {
        var map_it = self.children.iterator();
        while (map_it.next()) |entry| {
            entry.value_ptr.*.deinitRecursively(allocator, destroy_nodes);
        }

        self.children.deinit();
        if (self.name) |name| allocator.free(name);

        if (destroy_nodes) allocator.destroy(self);
    }

    /// Reports whether this node has no children and therefore holds asset bytes.
    /// Used by builders to choose the leaf packing path versus directory recursion,
    /// and by `lessThan` together with `kind` for deterministic output.
    /// - `self` - node under test; taken by value because only the child count is read.
    ///
    /// Return: true when `children.count() == 0`.
    pub fn isLeaf(self: Node) bool {
        return self.children.count() == 0;
    }

    /// Rebuilds the relative filesystem path by walking `parent` links to the root.
    /// Prepends each ancestor `name` plus its `Kind.getSeparator`, so embed/binary builders can open the real file.
    /// - `self` - leaf or directory whose on-disk location is needed.
    /// - `allocator` - allocator owning the returned path slice.
    ///
    /// Return: newly owned path; caller must free it.
    pub fn createPath(self: *const Node, allocator: mem.Allocator) ![]u8 {
        var path_list = std.ArrayList(u8).empty;
        errdefer path_list.deinit(allocator);
        var node: ?*const Node = self;
        while (node) |node_value| : (node = node_value.parent) {
            if (node_value.name) |name| {
                try path_list.insertSlice(allocator, 0, node_value.kind.getSeparator());
                try path_list.insertSlice(allocator, 0, name);
            }
        }

        return path_list.toOwnedSlice(allocator);
    }

    /// Renders the subtree as an indented text dump for debugging.
    /// Repeats `depth_prefix` via `text_utils.repeat` and recurses into non-leaf children.
    /// Not used by codegen; handy in tests and manual inspection of `create` results.
    /// - `self` - subtree to render; taken by value because rendering never mutates the tree.
    /// - `allocator` - allocator owning the returned dump.
    /// - `depth` - current nesting level controlling prefix repetition.
    ///
    /// Return: newly owned dump string; caller must free it.
    pub fn toString(self: Node, allocator: mem.Allocator, depth: u32) ![]u8 {
        var str_list: std.ArrayList(u8) = .empty;
        errdefer str_list.deinit(allocator);

        var prefix: []u8 = "";
        if (depth != 0) {
            prefix = try text_utils.repeat(allocator, Node.depth_prefix, depth);
        }

        var map_it = self.children.iterator();
        while (map_it.next()) |entry| {
            if (depth != 0) try str_list.appendSlice(allocator, prefix);
            if (entry.value_ptr.isLeaf()) {
                try str_list.appendSlice(allocator, entry.key_ptr.*);
                try str_list.append(allocator, '\n');
            } else {
                try str_list.appendSlice(allocator, entry.key_ptr.*);
                try str_list.append(allocator, '\n');
                const subnode_string = try entry.value_ptr.toString(allocator, depth + 1);
                try str_list.appendSlice(allocator, subnode_string);
                allocator.free(subnode_string);
            }
        }

        if (depth != 0) allocator.free(prefix);

        return str_list.toOwnedSlice(allocator);
    }

    /// Stack constructor for a tree node.
    /// Initializes an empty `children` map for `allocator` and stores `kind`, `name` and `parent` verbatim.
    /// Used by `initHeap` and therefore indirectly by every `create*` path.
    /// - `allocator` - allocator backing the new `children` map.
    /// - `kind` - role assigned from the walker position (`file`, `directory` or `root`).
    /// - `name` - owned name slice or `null` for the root; ownership moves to the new node.
    /// - `parent` - containing node used later by `createPath`; `null` only for the root.
    ///
    /// Return: initialized value node; heap placement still requires `initHeap`.
    pub fn init(allocator: mem.Allocator, kind: Kind, name: ?[]const u8, parent: ?*const Node) Node {
        return .{
            .children = .init(allocator),
            .kind = kind,
            .name = name,
            .parent = parent,
        };
    }

    /// Heap constructor for a tree node.
    /// Allocates with `allocator.create`, initializes via `init`, and returns the stable pointer
    /// stored in `children` maps by `createWithIo` and the single-file fallback in `build_steps_embed`.
    /// - `allocator` - allocator creating the heap node and its `children` map.
    /// - `kind` - role assigned from the walker position.
    /// - `name` - owned name slice or `null` for the root.
    /// - `parent` - containing node; `null` only for the root.
    ///
    /// Return: heap pointer owned by the caller and ultimately freed by `deinitRecursively`.
    pub fn initHeap(allocator: mem.Allocator, kind: Kind, name: ?[]const u8, parent: ?*const Node) !*Node {
        const node = try allocator.create(Node);
        node.* = .init(allocator, kind, name, parent);
        return node;
    }

    /// Deterministic ordering for builder output.
    /// Directories sort before files via the `Kind` discriminant, names break ties with `mem.lessThan`,
    /// so repeated builds emit identical Zig source and bundle layouts. Passed as the comparator to `std.mem.sort`.
    /// - `_` - unused sort context required by the `std.mem.sort` signature.
    /// - `a` - left-hand node being compared.
    /// - `b` - right-hand node being compared.
    ///
    /// Return: true when `a` must come before `b`.
    pub fn lessThan(_: void, a: *Node, b: *Node) bool {
        if (a.isLeaf() == b.isLeaf() or (a.name == null and b.name == null)) {
            if (a.name == null) return false;
            if (b.name == null) return true;

            return mem.lessThan(u8, a.name.?, b.name.?);
        } else {
            return @as(u32, @intFromEnum(a.kind)) < @as(u32, @intFromEnum(b.kind));
        }
    }
};

/// Builds an asset tree from a directory using explicit threaded IO.
/// Opens `target_dir`, walks it for files, and materializes intermediate directory nodes on demand.
/// Used by `embed_builder.bakeCodeToMemoryWithIo`, `binary_builder.bakeBinaryBundleToMemoryWithIo` and tests.
/// - `gpa` - allocator for nodes, maps and duplicated names.
/// - `io` - threaded IO used for directory iteration.
/// - `target_dir` - working-directory-relative directory scanned for asset files.
///
/// Return: heap root with `kind = .root`; caller must call `deinitRecursively(gpa, true)`.
pub fn createWithIo(gpa: std.mem.Allocator, io: std.Io, target_dir: []const u8) !*Node {
    var dir = try std.Io.Dir.cwd().openDir(io, target_dir, .{
        .iterate = true,
    });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    const root = try Node.initHeap(gpa, .root, null, null);

    while (try walker.next(io)) |dir_entry| {
        if (dir_entry.kind == .file) {
            var component_it = std.fs.path.componentIterator(dir_entry.path);
            var target = root;

            while (component_it.next()) |component_entry| {
                const kind: Node.Kind = if (component_it.peekNext() == null) .file else .directory;
                const component_name = component_entry.name;
                const sub_node = target.children.getPtr(component_name);

                if (sub_node) |node| {
                    target = node.*;
                } else {
                    const name_copy = try gpa.dupe(u8, component_name);
                    const child = try Node.initHeap(gpa, kind, name_copy, target);
                    try target.children.put(name_copy, child);
                    target = child;
                }
            }
        }
    }

    return root;
}

/// Builds an asset tree using the ambient process IO.
/// Thin adapter over `createWithIo` for filesystem code paths that already hold a `std.process.Init`.
/// Used by `embed_builder.createCodeFileFromAssets` and `binary_builder.createBinaryBundleFromAssets`.
/// - `init` - process init providing both `gpa` and `io`.
/// - `target_dir` - directory scanned for asset files.
///
/// Return: heap root owned by the caller; free with `deinitRecursively(init.gpa, true)`.
pub fn create(init: std.process.Init, target_dir: []const u8) !*Node {
    return createWithIo(init.gpa, init.io, target_dir);
}

/// Debug helper dumping the keys of a `StringHashMap(Node)`.
/// Prints index plus key to stdout; currently not called by builders and kept for manual troubleshooting.
/// - `map` - map whose keys are inspected; values are never touched.
fn printHashMap(map: std.StringHashMap(Node)) void {
    var map_it = map.iterator();
    var counter: usize = 0;
    while (map_it.next()) |entry| : (counter += 1) {
        std.debug.print("    [{}]k: {s}\n", .{ counter, entry.key_ptr.* });
    }
}
