/// Standard library for formatting generated loader code and path utilities.
const std = @import("std");
/// String helpers for identifier sanitizing and indentation in generated loader maps.
const text_utils = @import("text_utils.zig");

/// Tree node type shared with the binary builder; carries `name`, `kind` and hierarchy links.
const Node = @import("assets_tree.zig").Node;

/// Vtable namespace for the binary branch.
/// Separates byte extraction (`BinaryDescriptor`) from loader-code rendering (`MappingDescriptor`)
/// so one file entry pairs raw packing with its `Asset(u8, ...)` line while directories only render structs.
pub const abstract = struct {
    /// Type-erased loader-code renderer turning packed bytes into `Asset(u8, ...)` or `struct` source.
    /// Backs `binary_builder` codegen: every `BinaryDescriptor` owns one `mapping` used by `getCode`.
    /// Concrete instances come from `RawBinaryDescriptor.mapping` and `BinaryDirectoryDescriptor.mapping`.
    pub const MappingDescriptor = struct {
        /// Opaque receiver holding the concrete `*RawBinaryDescriptor` or `*BinaryDirectoryDescriptor`.
        ptr: *anyopaque,
        /// Function table dispatching code emission to the concrete `getMappingCode`.
        vtable: VTable,

        /// Vtable rendering loader source for one packed node.
        pub const VTable = struct {
            /// Renders the `Asset(...)` line or directory struct for the packed data.
            get_code: *const fn (*anyopaque, init: std.process.Init, data: Data) anyerror![]u8,
        };

        /// Per-node loader context built by `binary_builder.bakeBinaryTreeToCode`.
        /// Carries the packed `offset`/`size` for files and the already rendered child `content` for directories.
        pub const Data = struct {
            /// Sibling index driving the leading blank line for every struct after the first.
            id_in_parent: u32,
            /// Indentation depth converted to spaces via `spaces_per_depth`.
            depth: u32,
            /// Tree node being rendered; provides `name` and `kind`.
            node: *Node,
            /// Already rendered child source for directories, `null` for files.
            content: ?[]const u8,
            /// Filesystem prefix used to open the real file during packing; not embedded in output.
            path_to_root_node: []const u8,
            /// Runtime bundle location embedded into the generated `Asset(u8, bundle_path, ...)` line.
            bundle_path: []const u8,
            /// Byte offset of this leaf inside the packed bundle; `0` for directories.
            offset: usize,
            /// Byte length of this leaf inside the packed bundle; `0` for directories.
            size: usize,
        };

        /// Forwards to the concrete `getMappingCode` implementation.
        /// Called by `BinaryDescriptor.getCode` once the winning binary handler is known.
        /// - `self` - type-erased mapping under test.
        /// - `init` - process init threaded through the bake.
        /// - `data` - packed offset/size plus recursion context.
        ///
        /// Return: owned loader snippet; caller must free it.
        pub fn getCode(self: *const MappingDescriptor, init: std.process.Init, data: Data) anyerror![]u8 {
            return self.vtable.get_code(self.ptr, init, data);
        }
    };

    /// Type-erased byte extractor paired with its loader-code mapping.
    /// Backs `binary_builder` packing: builders call `isSuitableData` to pick a handler,
    /// `getData` to append bytes, then `getCode` (via `mapping`) to render the loader line.
    pub const BinaryDescriptor = struct {
        /// Shared loader context type; aliases `MappingDescriptor.Data` so both sides stay in sync.
        pub const Data = MappingDescriptor.Data;

        /// Opaque loader mapping rendering this handler's code; built by `mapping()` below.
        mapping: MappingDescriptor,
        /// Opaque receiver holding the concrete `*RawBinaryDescriptor` or `*BinaryDirectoryDescriptor`.
        ptr: *anyopaque,
        /// Function table dispatching byte extraction and lifetime handling.
        vtable: VTable,

        /// Vtable extracting raw bytes for bundle packing.
        pub const VTable = struct {
            /// Reads the asset bytes for one node; see `RawBinaryDescriptor.getData`.
            get_data: *const fn (*anyopaque, init: std.process.Init, node_path: []const u8) anyerror![]u8,
            /// Reports whether this handler owns the node (`file` versus `directory`).
            is_suitable_data: *const fn (*anyopaque, init: std.process.Init, node: *Node) anyerror!bool,
            /// Releases bytes from `get_data` when packing is done; `null` means nothing to free.
            deinit_data: ?*const fn (*anyopaque, init: std.process.Init, data: []u8) void = null,
        };

        /// Forwards to the concrete `is_suitable_data` implementation.
        /// Called for every configured descriptor until one claims the node.
        /// - `self` - type-erased descriptor under test.
        /// - `init` - process init threaded through the bake.
        /// - `node` - tree node being classified.
        ///
        /// Return: true when this handler owns the node.
        pub fn isSuitableData(self: *const BinaryDescriptor, init: std.process.Init, node: *Node) anyerror!bool {
            return self.vtable.is_suitable_data(self.ptr, init, node);
        }

        /// Forwards to the concrete `get_data` implementation.
        /// Called for leaves to obtain the bytes appended to the bundle.
        /// - `self` - type-erased winning descriptor.
        /// - `init` - process init providing allocator and IO.
        /// - `node_path` - real filesystem path resolved via `Node.createPath`.
        ///
        /// Return: owned bytes; released later with `deinitData`.
        pub fn getData(self: *const BinaryDescriptor, init: std.process.Init, node_path: []const u8) anyerror![]u8 {
            return self.vtable.get_data(self.ptr, init, node_path);
        }

        /// Renders loader source through the paired `mapping` descriptor.
        /// Called after packing to emit the `Asset(...)` line or directory struct.
        /// - `self` - type-erased winning descriptor.
        /// - `init` - process init threaded through the bake.
        /// - `data` - packed offset/size plus recursion context.
        ///
        /// Return: owned loader snippet; caller must free it.
        pub fn getCode(self: *const BinaryDescriptor, init: std.process.Init, data: Data) anyerror![]u8 {
            return self.mapping.getCode(init, data);
        }

        /// Releases bytes from `getData` when the handler provides a `deinit_data` hook.
        /// Called with `defer` right after appending so packing never leaks on error paths.
        /// - `self` - type-erased descriptor that produced the bytes.
        /// - `init` - process init providing the allocator.
        /// - `data` - bytes previously returned by `getData`.
        pub fn deinitData(self: *const BinaryDescriptor, init: std.process.Init, data: []u8) void {
            if (self.vtable.deinit_data) |f| f(self.ptr, init, data);
        }
    };
};

/// Handler packing directory nodes as loader structs.
/// Selected when `node.kind == .directory`; its `getData` is never meaningful and returns an error.
/// Its mapping wraps already packed child code in the same `struct` shape as the embed backend.
pub const BinaryDirectoryDescriptor = struct {
    /// Spaces emitted per tree depth for the generated `struct` wrapper.
    spaces_per_depth: usize = 4,

    /// Binds this directory handler to the type-erased `MappingDescriptor` interface.
    /// Stored inside the `BinaryDescriptor` returned by `descriptor` below.
    /// - `self` - live directory handler; must outlive the bake.
    ///
    /// Return: mapping view forwarding to `getMappingCode`.
    pub fn mapping(self: *BinaryDirectoryDescriptor) abstract.MappingDescriptor {
        return .{
            .ptr = self,
            .vtable = .{
                .get_code = getMappingCode,
            },
        };
    }

    /// Binds this directory handler plus its mapping to the type-erased `BinaryDescriptor` interface.
    /// Stored in binary descriptor tables consumed by `binary_builder` and `build_steps_binary`.
    /// - `self` - live directory handler; must outlive the bake.
    ///
    /// Return: binary view forwarding suitability, data and code paths below.
    pub fn descriptor(self: *BinaryDirectoryDescriptor) abstract.BinaryDescriptor {
        return .{
            .ptr = self,
            .mapping = self.mapping(),
            .vtable = .{
                .get_data = getData,
                .is_suitable_data = isSuitableData,
            },
        };
    }

    /// Claims only directory nodes for struct emission.
    /// - `ptr` - opaque `*BinaryDirectoryDescriptor`; ignored.
    /// - `init` - process init threaded through the bake; unused here.
    /// - `node` - tree node being classified.
    ///
    /// Return: true exactly when `node.kind == .directory`.
    pub fn isSuitableData(ptr: *anyopaque, init: std.process.Init, node: *Node) anyerror!bool {
        _ = ptr;
        _ = init;
        return node.kind == .directory;
    }

    /// Rejects byte extraction because directories pack no bytes.
    /// Exists only to satisfy the `BinaryDescriptor.VTable` shape; the builder never calls it for directories.
    /// - `ptr` - opaque `*BinaryDirectoryDescriptor`; ignored.
    /// - `init` - process init threaded through the bake; unused here.
    /// - `node_path` - filesystem path that would have been packed; ignored.
    ///
    /// Return: always `error.NotApplicableForDirectory`.
    pub fn getData(ptr: *anyopaque, init: std.process.Init, node_path: []const u8) anyerror![]u8 {
        _ = ptr;
        _ = init;
        _ = node_path;
        return error.NotApplicableForDirectory;
    }

    /// Wraps already packed child loader code in a namespaced `struct`.
    /// Mirrors `EmbedDirectoryDescriptor.getCode` but emits through the binary mapping path.
    /// - `ptr` - opaque `*BinaryDirectoryDescriptor` providing `spaces_per_depth`.
    /// - `init` - process init providing the allocator.
    /// - `data` - directory node, depth, child `content` and sibling index.
    ///
    /// Return: owned struct source; caller must free it.
    pub fn getMappingCode(ptr: *anyopaque, init: std.process.Init, data: abstract.MappingDescriptor.Data) anyerror![]u8 {
        const self: *BinaryDirectoryDescriptor = @ptrCast(@alignCast(ptr));
        const gpa = init.gpa;
        const node = data.node;
        const depth = data.depth;
        const content = data.content;

        const prefix = try text_utils.repeat(gpa, " ", depth * self.spaces_per_depth);
        defer if (prefix) |p| gpa.free(p);

        const new_line_after_content =
            if (content != null and content.?[content.?.len - 1] == '\n') "" else "\n";

        const name = node.name orelse return error.MissingName;
        const var_name = try text_utils.filenameToIdentifier(gpa, name);
        defer gpa.free(var_name);

        return std.fmt.allocPrint(gpa, "{s}{s}pub const {s} = struct {{\n{s}{s}{s}}};\n", .{
            if (data.id_in_parent == 0) "" else "\n",
            prefix orelse "",
            var_name,
            content orelse "",
            new_line_after_content,
            prefix orelse "",
        });
    }
};

/// Handler packing file leaves byte-for-byte and emitting `Asset(u8, ...)` loader lines.
/// Default binary descriptor instantiated in binary build-step configs; selected for `.file` nodes.
pub const RawBinaryDescriptor = struct {
    /// Spaces emitted per tree depth for the generated `Asset` constant.
    spaces_per_depth: usize = 4,

    /// Binds this raw handler to the type-erased `MappingDescriptor` interface.
    /// Stored inside the `BinaryDescriptor` returned by `descriptor` below.
    /// - `self` - live raw handler; must outlive the bake.
    ///
    /// Return: mapping view forwarding to `getMappingCode`.
    pub fn mapping(self: *RawBinaryDescriptor) abstract.MappingDescriptor {
        return .{
            .ptr = self,
            .vtable = .{
                .get_code = getMappingCode,
            },
        };
    }

    /// Binds this raw handler plus its mapping to the type-erased `BinaryDescriptor` interface.
    /// Stored in binary descriptor tables; the first `isSuitableData` hit wins during packing.
    /// - `self` - live raw handler; must outlive the bake.
    ///
    /// Return: binary view forwarding suitability, data and code paths below.
    pub fn descriptor(self: *RawBinaryDescriptor) abstract.BinaryDescriptor {
        return .{
            .ptr = self,
            .mapping = self.mapping(),
            .vtable = .{
                .get_data = getData,
                .is_suitable_data = isSuitableData,
                .deinit_data = deinitData,
            },
        };
    }

    /// Claims only file leaves for raw byte packing.
    /// - `ptr` - opaque `*RawBinaryDescriptor`; ignored.
    /// - `init` - process init threaded through the bake; unused here.
    /// - `node` - tree node being classified.
    ///
    /// Return: true exactly when `node.kind == .file`.
    pub fn isSuitableData(ptr: *anyopaque, init: std.process.Init, node: *Node) anyerror!bool {
        _ = ptr;
        _ = init;
        return node.kind == .file;
    }

    /// Reads one file verbatim for bundle packing.
    /// Opens `node_path` with threaded IO, stats its size, and streams the exact bytes.
    /// Used by `binary_builder` before advancing the shared `offset`.
    /// - `ptr` - opaque `*RawBinaryDescriptor`; ignored.
    /// - `init` - process init providing allocator and IO.
    /// - `node_path` - real filesystem path resolved via `Node.createPath`.
    ///
    /// Return: owned file bytes; released later with `deinitData`.
    pub fn getData(ptr: *anyopaque, init: std.process.Init, node_path: []const u8) anyerror![]u8 {
        _ = ptr;
        const gpa = init.gpa;
        const io = init.io;
        var cwd = std.Io.Dir.cwd();
        var file = cwd.openFile(io, node_path, .{}) catch |err| {
            std.debug.print("RawBinaryDescriptor: open {s} failed: {t}\n", .{ node_path, err });
            return err;
        };
        defer file.close(io);
        const stat = try file.stat(io);
        const size: usize = @intCast(stat.size);
        if (size == 0) return try gpa.alloc(u8, 0);
        const buf = try gpa.alloc(u8, size);
        errdefer gpa.free(buf);
        var total: usize = 0;
        while (total < size) {
            const n = try file.readStreaming(io, &.{buf[total..]});
            if (n == 0) break;
            total += n;
        }
        if (total != size) {
            const trimmed = try gpa.realloc(buf, total);
            return trimmed;
        }
        return buf;
    }

    /// Releases bytes previously returned by `getData`.
    /// Registered as `deinit_data` so `binary_builder` can `defer` cleanup right after appending.
    /// - `ptr` - opaque `*RawBinaryDescriptor`; ignored.
    /// - `init` - process init providing the allocator.
    /// - `data` - bytes to free.
    pub fn deinitData(ptr: *anyopaque, init: std.process.Init, data: []u8) void {
        _ = ptr;
        init.gpa.free(data);
    }

    /// Emits one `Asset(u8, bundle_path, offset, size)` loader constant.
    /// Escapes `bundle_path` for Zig string syntax and indents with `spaces_per_depth`.
    /// The file-local `Asset` alias comes from `binary_header` injected by `binary_builder`.
    /// - `ptr` - opaque `*RawBinaryDescriptor` providing `spaces_per_depth`.
    /// - `init` - process init providing the allocator.
    /// - `data` - packed `offset`/`size`, bundle path and tree node for naming.
    ///
    /// Return: owned one-line constant; caller must free it.
    pub fn getMappingCode(ptr: *anyopaque, init: std.process.Init, data: abstract.MappingDescriptor.Data) anyerror![]u8 {
        const self: *RawBinaryDescriptor = @ptrCast(@alignCast(ptr));
        const gpa = init.gpa;
        const node = data.node;
        const depth = data.depth;

        const prefix = try text_utils.repeat(gpa, " ", depth * self.spaces_per_depth);
        defer if (prefix) |p| gpa.free(p);

        const name = node.name orelse return error.MissingName;
        const var_name = try text_utils.filenameToIdentifier(gpa, name);
        defer gpa.free(var_name);

        var escaped = std.ArrayList(u8).empty;
        defer escaped.deinit(gpa);
        for (data.bundle_path) |ch| {
            switch (ch) {
                '\\' => try escaped.appendSlice(gpa, "\\\\"),
                '"' => try escaped.appendSlice(gpa, "\\\""),
                '\n' => try escaped.appendSlice(gpa, "\\n"),
                '\r' => {},
                else => try escaped.append(gpa, ch),
            }
        }

        return std.fmt.allocPrint(gpa, "{s}pub const {s} = Asset(u8, \"{s}\", {d}, {d});\n", .{ prefix orelse "", var_name, escaped.items, data.offset, data.size });
    }
};
