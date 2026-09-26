/// Build-time re-export of the `std.Build` integration.
/// Lets downstream `build.zig` files reach `build_steps.embed/binary` through this package
/// without adding a second dependency; mirrors the same export in `root.zig`.
pub const build_steps = @import("src/build_steps.zig");
/// Build-time re-export of the descriptor families.
/// Exposed here so codegen configuration in a consumer build script needs only one import.
pub const descriptors = @import("src/descriptors.zig");
/// Build-time re-export of both builder backends.
/// Exposed here for symmetry with `root.zig`; most consumers prefer the `build_steps` wrappers.
pub const builders = @import("src/builders.zig");
/// Build-time re-export of the runtime loader.
/// Allows build scripts to name `asset_loader.Asset` without importing the runtime module separately.
pub const asset_loader = @import("src/asset_loader.zig");
/// Build-time re-export of the string helpers.
/// Handy for custom descriptors written inside a consumer `build.zig`.
pub const text_utils = @import("src/text_utils.zig");
/// Build-time re-export of the asset tree model.
/// Used by custom build-time tooling that walks assets before delegating to a builder.
pub const assets_tree = @import("src/assets_tree.zig");

/// Standard library for the `std.Build` API used below.
const std = @import("std");

/// The build script's own type, captured for `dependencyFromBuildZig`.
/// Passed as the build root in `Options.getModule` so source paths stay correct
/// when this package is consumed as a parent dependency rather than built standalone.
const ThisBuild = @This();

/// Shared module-construction options for this package.
/// Carries optional `target`/`optimize` so both the standalone `build` and the parent-facing
/// `getModule` resolve the same compilation settings instead of duplicating option parsing.
pub const Options = struct {
    /// Target architecture the `assets_manager` module is compiled for.
    /// `null` means fall back to `standardTargetOptions` at use time.
    target: ?std.Build.ResolvedTarget = null,
    /// Optimization mode the `assets_manager` module is compiled with.
    /// `null` means fall back to `standardOptimizeOption` at use time.
    optimize: ?std.builtin.OptimizeMode = null,

    /// Creates the shared `assets_manager` module for a parent package graph.
    /// Uses `dependencyFromBuildZig` with `ThisBuild` so `root.zig` resolves inside this package
    /// even when called from another build script; used as `(@import("assets_manager").Options{...}).getModule(b)`.
    /// - `self` - options holding the resolved target and optimize mode.
    /// - `b` - parent build graph receiving the new module.
    ///
    /// Return: module handle pointing at this package's `root.zig`.
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

    /// Reads this package's own command-line build options.
    /// Called by the standalone `build` below; parent packages normally construct `Options` literally instead.
    /// - `b` - own build graph providing `standardTargetOptions` and `standardOptimizeOption`.
    ///
    /// Return: options populated from the current `zig build` invocation.
    pub fn initFromOptions(b: *std.Build) Options {
        return .{
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        };
    }
};

/// Standalone package build wiring.
/// Resolves `Options` from the command line and registers the `assets_manager` module via `b.path`.
/// Only valid for the own package graph; parent consumers must use `Options.getModule` instead.
/// - `b` - own build graph receiving the `assets_manager` module.
pub fn build(b: *std.Build) void {
    const options = Options.initFromOptions(b);
    _ = createModuleOwn(b, options);
}

/// Registers the `assets_manager` module in the own package graph.
/// Uses `b.path("root.zig")`, which is only valid when building this repository directly.
/// Factored out of `build` so module creation stays testable and separate from option parsing.
/// - `b` - own build graph receiving the module.
/// - `options` - target and optimize settings resolved by `Options.initFromOptions`.
///
/// Return: module handle for the locally registered `assets_manager` module.
fn createModuleOwn(b: *std.Build, options: Options) *std.Build.Module {
    const target = options.target orelse b.standardTargetOptions(.{});
    const optimize = options.optimize orelse b.standardOptimizeOption(.{});
    return b.addModule("assets_manager", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });
}
