const std = @import("std");

const ThisBuild = @This();

pub const build_steps = @import("src/build_steps.zig");
pub const descriptors = @import("src/descriptors.zig");
pub const binary_descriptors = @import("src/binary_descriptors.zig");
pub const asset_loader = @import("src/asset_loader.zig");
pub const text_utils = @import("src/text_utils.zig");
pub const assets_tree = @import("src/assets_tree.zig");
pub const assets_builder = @import("src/assets_builder.zig");
pub const binary_builder = @import("src/binary_builder.zig");

pub const Options = struct {
    /// The target architecture for which the module will be built.
    target: ?std.Build.ResolvedTarget = null,
    /// The optimization mode used to compile the module.
    optimize: ?std.builtin.OptimizeMode = null,

    pub fn initFromOptions(b: *std.Build) Options {
        return .{
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        };
    }

    /// Create the `assets_manager` module in the caller's build graph.
    ///
    /// Intended for parent packages that want a single shared instance:
    /// ```zig
    /// const assets_mod = (@import("assets_manager").Options{
    ///     .target = target,
    ///     .optimize = optimize,
    /// }).getModule(b);
    /// ```
    /// Uses `dependencyFromBuildZig` so source paths stay correct when
    /// called from a parent build via `@import("assets_manager")`.
    pub fn getModule(self: Options, b: *std.Build) *std.Build.Module {
        const target = self.target orelse b.standardTargetOptions(.{});
        const optimize = self.optimize orelse b.standardOptimizeOption(.{});
        const self_dep = b.dependencyFromBuildZig(ThisBuild, .{
            .target = target,
            .optimize = optimize,
        });
        return b.createModule(.{
            .root_source_file = self_dep.path("root.zig"),
            .target = target,
            .optimize = optimize,
        });
    }
};

/// Create the `assets_manager` module in the *own* package graph (standalone `zig build`).
/// Same wiring as `Options.getModule` but uses `b.path` (valid only for own build).
fn createModuleOwn(b: *std.Build, options: Options) *std.Build.Module {
    const target = options.target orelse b.standardTargetOptions(.{});
    const optimize = options.optimize orelse b.standardOptimizeOption(.{});
    return b.addModule("assets_manager", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });
}

pub fn build(b: *std.Build) void {
    const options = Options.initFromOptions(b);
    _ = createModuleOwn(b, options);
}
