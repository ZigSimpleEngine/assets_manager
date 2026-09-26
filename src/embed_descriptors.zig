/// Standard library for formatting generated source and path utilities.
const std = @import("std");
/// String helpers for identifier sanitizing and indentation in generated code.
const text_utils = @import("text_utils.zig");

/// Tree node type shared with the builders; carries `name`, `kind` and hierarchy links.
const Node = @import("assets_tree.zig").Node;

/// Vtable namespace for the embed branch.
/// Groups the `EmbedDescriptor` interface so builders and build steps depend on one stable type
/// while file/directory implementations stay side by side in this file.
pub const abstract = struct {
    /// Type-erased code generator turning one `Node` into Zig source via `@embedFile` or a `struct`.
    /// Backs `embed_builder` codegen: builders call `isSuitableData` to pick a handler,
    /// then `getCode` to render it. Concrete instances come from `EmbedFileDescriptor.descriptor`
    /// and `EmbedDirectoryDescriptor.descriptor` in `run.zig` and build-step configs.
    pub const EmbedDescriptor = struct {
        /// Opaque receiver holding the concrete `*EmbedFileDescriptor` or `*EmbedDirectoryDescriptor`.
        ptr: *anyopaque,
        /// Function table dispatching suitability checks and code emission to the concrete handler.
        vtable: VTable,

        /// Vtable selecting and rendering one asset node.
        /// Stored per concrete descriptor and invoked through the type-erased `EmbedDescriptor` wrapper.
        pub const VTable = struct {
            /// Renders Zig source for one node; see `EmbedFileDescriptor.getCode` for the file shape.
            get_code: *const fn (*anyopaque, init: std.process.Init, descripting_data: Data) anyerror![]u8,
            /// Reports whether this handler owns the node (`file` versus `directory`).
            is_suitable_data: *const fn (*anyopaque, init: std.process.Init, descripting_data: Data) anyerror!bool,
        };

        /// Per-node codegen context threaded through the recursive embed walk.
        /// Built by `embed_builder.bakeAssetsTreeToCode` and consumed by every `getCode` implementation.
        pub const Data = struct {
            /// Sibling index driving the leading blank line for every struct after the first.
            id_in_parent: u32,
            /// Indentation depth converted to spaces via `spaces_per_depth`.
            depth: u32,
            /// Tree node being rendered; provides `name`, `kind` and `createPath`.
            node: *Node,
            /// Already rendered child source for directories, `null` for files.
            content: ?[]const u8,
            /// Prefix making `@embedFile` paths resolve relative to the generated file location.
            path_to_root_node: []const u8,
        };

        /// Forwards to the concrete `is_suitable_data` implementation.
        /// Called by builders for every configured descriptor until one claims the node.
        /// - `self` - type-erased descriptor under test.
        /// - `init` - process init threaded through the walk.
        /// - `descripting_data` - node plus recursion context.
        ///
        /// Return: true when this handler owns the node.
        pub fn isSuitableData(self: *const EmbedDescriptor, init: std.process.Init, descripting_data: Data) anyerror!bool {
            return self.vtable.is_suitable_data(self.ptr, init, descripting_data);
        }

        /// Forwards to the concrete `get_code` implementation.
        /// Called once the winning descriptor is known to render its Zig snippet.
        /// - `self` - type-erased winning descriptor.
        /// - `init` - process init threaded through the walk.
        /// - `descripting_data` - node plus recursion context.
        ///
        /// Return: owned code snippet; caller must free it.
        pub fn getCode(self: *const EmbedDescriptor, init: std.process.Init, descripting_data: Data) anyerror![]u8 {
            return self.vtable.get_code(self.ptr, init, descripting_data);
        }
    };
};

/// Handler emitting `pub const <id> = @embedFile("prefix/path");` for file leaves.
/// Instantiated in `run.zig` and build-step configs; selected when `node.kind == .file`.
pub const EmbedFileDescriptor = struct {
    /// Spaces emitted per tree depth for the generated constant.
    spaces_per_depth: usize = 4,

    /// Binds this file handler to the type-erased `abstract.EmbedDescriptor` interface.
    /// The returned value is stored in descriptor tables consumed by `embed_builder`.
    /// - `self` - live file handler; must outlive the bake because only the pointer is captured.
    ///
    /// Return: vtable view forwarding to `isSuitableData` and `getCode` below.
    pub fn descriptor(self: *EmbedFileDescriptor) abstract.EmbedDescriptor {
        return .{
            .ptr = self,
            .vtable = .{
                .get_code = getCode,
                .is_suitable_data = isSuitableData,
            },
        };
    }

    /// Claims only file leaves for `@embedFile` emission.
    /// - `ptr` - opaque `*EmbedFileDescriptor`; ignored because suitability depends only on the node.
    /// - `init` - process init threaded through the walk; unused here.
    /// - `descripting_data` - node plus recursion context; `node.kind` decides the answer.
    ///
    /// Return: true exactly when `node.kind == .file`.
    pub fn isSuitableData(ptr: *anyopaque, init: std.process.Init, descripting_data: abstract.EmbedDescriptor.Data) anyerror!bool {
        _ = ptr;
        _ = init;
        const node = descripting_data.node;
        return node.kind == .file;
    }

    /// Renders one `@embedFile` constant with depth-aware indentation.
    /// Resolves the on-disk path with `Node.createPath`, sanitizes the binding with `filenameToIdentifier`,
    /// and prefixes it with `path_to_root_node` so the generated file resolves correctly.
    /// - `ptr` - opaque `*EmbedFileDescriptor` providing `spaces_per_depth`.
    /// - `init` - process init providing the allocator.
    /// - `descripting_data` - file node, depth and path prefix.
    ///
    /// Return: owned one-line constant including the trailing newline; caller must free it.
    pub fn getCode(ptr: *anyopaque, init: std.process.Init, descripting_data: abstract.EmbedDescriptor.Data) anyerror![]u8 {
        const self: *EmbedFileDescriptor = @ptrCast(@alignCast(ptr));
        const node = descripting_data.node;
        const depth = descripting_data.depth;
        const gpa = init.gpa;
        const path = try node.createPath(gpa);
        defer gpa.free(path);

        const prefix = try text_utils.repeat(gpa, " ", depth * self.spaces_per_depth);
        defer if (prefix) |prefix_value| gpa.free(prefix_value);

        if (node.name) |name| {
            const var_name = try text_utils.filenameToIdentifier(gpa, name);
            defer gpa.free(var_name);
            return std.fmt.allocPrint(gpa, "{s}pub const {s} = @embedFile(\"{s}{s}\");\n", .{
                prefix orelse "",
                var_name,
                descripting_data.path_to_root_node,
                path,
            });
        } else {
            return error.AttemptToCreateZigCodeFromNodeWithoutName;
        }
    }
};

/// Handler emitting `pub const <id> = struct { ... };` for directory nodes.
/// Instantiated alongside `EmbedFileDescriptor`; selected when `node.kind == .directory`.
/// Its `content` input is the already baked child source from `embed_builder`.
pub const EmbedDirectoryDescriptor = struct {
    /// Spaces emitted per tree depth for the `struct` wrapper and its children.
    spaces_per_depth: usize = 4,

    /// Binds this directory handler to the type-erased `abstract.EmbedDescriptor` interface.
    /// Stored next to the file descriptor in every embed descriptor table.
    /// - `self` - live directory handler; must outlive the bake.
    ///
    /// Return: vtable view forwarding to `isSuitableData` and `getCode` below.
    pub fn descriptor(self: *EmbedDirectoryDescriptor) abstract.EmbedDescriptor {
        return .{
            .ptr = self,
            .vtable = .{
                .get_code = getCode,
                .is_suitable_data = isSuitableData,
            },
        };
    }

    /// Claims only directory nodes for struct emission.
    /// - `ptr` - opaque `*EmbedDirectoryDescriptor`; ignored.
    /// - `init` - process init threaded through the walk; unused here.
    /// - `descripting_data` - node plus recursion context; `node.kind` decides the answer.
    ///
    /// Return: true exactly when `node.kind == .directory`.
    pub fn isSuitableData(ptr: *anyopaque, init: std.process.Init, descripting_data: abstract.EmbedDescriptor.Data) anyerror!bool {
        _ = ptr;
        _ = init;
        const node = descripting_data.node;
        return node.kind == .directory;
    }

    /// Wraps already baked child source in a namespaced `struct`.
    /// Sanitizes the binding with `filenameToIdentifier`, indents with `spaces_per_depth`,
    /// and inserts a leading blank line for every struct after the first sibling.
    /// - `ptr` - opaque `*EmbedDirectoryDescriptor` providing `spaces_per_depth`.
    /// - `init` - process init providing the allocator.
    /// - `descripting_data` - directory node, depth, child `content` and sibling index.
    ///
    /// Return: owned struct source including the trailing newline; caller must free it.
    pub fn getCode(ptr: *anyopaque, init: std.process.Init, descripting_data: abstract.EmbedDescriptor.Data) anyerror![]u8 {
        const self: *EmbedDirectoryDescriptor = @ptrCast(@alignCast(ptr));
        const node = descripting_data.node;
        const depth = descripting_data.depth;
        const gpa = init.gpa;
        const content = descripting_data.content;

        const prefix = try text_utils.repeat(gpa, " ", depth * self.spaces_per_depth);
        defer if (prefix) |prefix_value| gpa.free(prefix_value);

        const new_line_after_content =
            if (content != null and content.?[content.?.len - 1] == '\n') "" else "\n";

        if (node.name) |name| {
            const var_name = try text_utils.filenameToIdentifier(gpa, name);
            defer gpa.free(var_name);
            return std.fmt.allocPrint(gpa, "{s}{s}pub const {s} = struct {{\n{s}{s}{s}}};\n", .{
                if (descripting_data.id_in_parent == 0) "" else "\n",
                prefix orelse "",
                var_name,
                descripting_data.content orelse "",
                new_line_after_content,
                prefix orelse "",
            });
        } else {
            return error.AttemptToCreateZigCodeFromNodeWithoutName;
        }
    }
};
