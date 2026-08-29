const std = @import("std");

pub const build_steps = @import("src/build_steps.zig");
pub const descriptors = @import("src/descriptors.zig");
pub const binary_descriptors = @import("src/binary_descriptors.zig");
pub const asset_loader = @import("src/asset_loader.zig");
pub const text_utils = @import("src/text_utils.zig");
pub const assets_tree = @import("src/assets_tree.zig");
pub const assets_builder = @import("src/assets_builder.zig");
pub const binary_builder = @import("src/binary_builder.zig");

pub fn build(b: *std.Build) void {
    _ = b.addModule("assets_manager", .{
        .root_source_file = b.path("root.zig"),
    });
}
