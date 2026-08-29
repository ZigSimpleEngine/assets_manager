const std = @import("std");
const mem = std.mem;
const text_utils = @import("text_utils.zig");

fn printHashMap(map: std.StringHashMap(Node)) void {
    var map_it = map.iterator();
    var counter: usize = 0;
    while (map_it.next()) |entry| : (counter += 1) {
        std.debug.print("    [{}]k: {s}\n", .{ counter, entry.key_ptr.* });
    }
}

pub const Node = struct {
    pub const Kind = enum {
        root,
        file,
        directory,

        pub fn getSeparator(self: Kind) []const u8 {
            return switch (self) {
                .root => "",
                .directory => "/",
                .file => "",
            };
        }
    };

    name: ?[]const u8,
    children: std.StringHashMap(*Node),
    kind: Kind,
    parent: ?*const Node,

    pub var depth_prefix = "----";

    pub fn init(allocator: mem.Allocator, kind: Kind, name: ?[]const u8, parent: ?*const Node) Node {
        return .{
            .children = .init(allocator),
            .kind = kind,
            .name = name,
            .parent = parent,
        };
    }

    pub fn initHeap(allocator: mem.Allocator, kind: Kind, name: ?[]const u8, parent: ?*const Node) !*Node {
        const node = try allocator.create(Node);
        node.* = .init(allocator, kind, name, parent);
        return node;
    }

    pub fn deinitRecursively(self: *Node, allocator: std.mem.Allocator, destroy_nodes: bool) void {
        var map_it = self.children.iterator();
        while (map_it.next()) |entry| {
            entry.value_ptr.*.deinitRecursively(allocator, destroy_nodes);
        }

        self.children.deinit();
        if (self.name) |name| allocator.free(name);

        if (destroy_nodes) allocator.destroy(self);
    }

    pub fn isLeaf(self: Node) bool {
        return self.children.count() == 0;
    }

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

    pub fn lessThan(_: void, a: *Node, b: *Node) bool {
        if (a.isLeaf() == b.isLeaf() or (a.name == null and b.name == null)) {
            if (a.name == null) return false;
            if (b.name == null) return true;

            return mem.lessThan(u8, a.name.?, b.name.?);
        } else {
            return @as(u32, @intFromEnum(a.kind)) < @as(u32, @intFromEnum(b.kind));
        }
    }

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
};

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

pub fn create(init: std.process.Init, target_dir: []const u8) !*Node {
    return createWithIo(init.gpa, init.io, target_dir);
}
