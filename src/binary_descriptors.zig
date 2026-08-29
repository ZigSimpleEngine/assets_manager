const std = @import("std");
const text_utils = @import("text_utils.zig");
const Node = @import("assets_tree.zig").Node;

/// Descriptor for binary bundling. Unlike `descriptors.Descriptor` which generates
/// Zig source directly, this descriptor knows how to extract raw bytes to be
/// appended to the bundle and how to generate the loader code that references
/// a slice of the bundle.
pub const BinaryDescriptor = struct {
    pub const Data = struct {
        id_in_parent: u32,
        depth: u32,
        node: *Node,
        content: ?[]const u8, // generated child code for directory
        path_to_root_node: []const u8,
        bundle_path: []const u8,
        offset: usize,
        size: usize,
    };

    pub const VTable = struct {
        get_data: *const fn (*anyopaque, init: std.process.Init, node_path: []const u8) anyerror![]u8,
        get_loader_code: *const fn (*anyopaque, init: std.process.Init, data: Data) anyerror![]u8,
        is_suitable_data: *const fn (*anyopaque, init: std.process.Init, node: *Node) anyerror!bool,
        deinit_data: ?*const fn (*anyopaque, init: std.process.Init, data: []u8) void = null,
    };

    ptr: *anyopaque,
    vtable: VTable,

    pub fn isSuitableData(self: *const BinaryDescriptor, init: std.process.Init, node: *Node) anyerror!bool {
        return self.vtable.is_suitable_data(self.ptr, init, node);
    }

    pub fn getData(self: *const BinaryDescriptor, init: std.process.Init, node_path: []const u8) anyerror![]u8 {
        return self.vtable.get_data(self.ptr, init, node_path);
    }

    pub fn getLoaderCode(self: *const BinaryDescriptor, init: std.process.Init, data: Data) anyerror![]u8 {
        return self.vtable.get_loader_code(self.ptr, init, data);
    }

    pub fn deinitData(self: *const BinaryDescriptor, init: std.process.Init, data: []u8) void {
        if (self.vtable.deinit_data) |f| f(self.ptr, init, data);
    }
};

/// Default binary descriptor: dumb byte-for-byte embedding.
/// Reads the file as-is and produces a loader that slices the bundle.
pub const RawBinaryDescriptor = struct {
    spaces_per_depth: usize = 4,

    pub fn isSuitableData(ptr: *anyopaque, init: std.process.Init, node: *Node) anyerror!bool {
        _ = ptr;
        _ = init;
        return node.kind == .file;
    }

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
            // file truncated
            const trimmed = try gpa.realloc(buf, total);
            return trimmed;
        }
        return buf;
    }

    pub fn deinitData(ptr: *anyopaque, init: std.process.Init, data: []u8) void {
        _ = ptr;
        init.gpa.free(data);
    }

    pub fn getLoaderCode(ptr: *anyopaque, init: std.process.Init, data: BinaryDescriptor.Data) anyerror![]u8 {
        const self: *RawBinaryDescriptor = @ptrCast(@alignCast(ptr));
        const gpa = init.gpa;
        const node = data.node;
        const depth = data.depth;

        const prefix = try text_utils.repeat(gpa, " ", depth * self.spaces_per_depth);
        defer if (prefix) |p| gpa.free(p);

        const name = node.name orelse return error.MissingName;
        const var_name = try text_utils.filenameToIdentifier(gpa, name);
        defer gpa.free(var_name);

        // Escape bundle_path for Zig string literal
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

        // Generate: pub const <name> = @import("assets_manager").asset_loader.Asset("<bundle>", offset, size);
        return std.fmt.allocPrint(gpa,
            "{s}pub const {s} = @import(\"assets_manager\").asset_loader.Asset(\"{s}\", {d}, {d});\n",
            .{ prefix orelse "", var_name, escaped.items, data.offset, data.size });
    }

    pub fn descriptor(self: *RawBinaryDescriptor) BinaryDescriptor {
        return .{
            .ptr = self,
            .vtable = .{
                .get_data = getData,
                .get_loader_code = getLoaderCode,
                .is_suitable_data = isSuitableData,
                .deinit_data = deinitData,
            },
        };
    }
};

/// Directory descriptor for binary bundling. Generates struct hierarchy
/// identical to `ZigDirectoryDescriptor` but wraps loader constants.
pub const BinaryDirectoryDescriptor = struct {
    spaces_per_depth: usize = 4,

    pub fn isSuitableData(ptr: *anyopaque, init: std.process.Init, node: *Node) anyerror!bool {
        _ = ptr;
        _ = init;
        return node.kind == .directory;
    }

    pub fn getData(ptr: *anyopaque, init: std.process.Init, node_path: []const u8) anyerror![]u8 {
        _ = ptr;
        _ = init;
        _ = node_path;
        return error.NotApplicableForDirectory;
    }

    pub fn getLoaderCode(ptr: *anyopaque, init: std.process.Init, data: BinaryDescriptor.Data) anyerror![]u8 {
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

    pub fn descriptor(self: *BinaryDirectoryDescriptor) BinaryDescriptor {
        return .{
            .ptr = self,
            .vtable = .{
                .get_data = getData,
                .get_loader_code = getLoaderCode,
                .is_suitable_data = isSuitableData,
            },
        };
    }
};
