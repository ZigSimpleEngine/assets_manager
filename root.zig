/// Public entry point of the `assets_manager` package.
/// Imported by consumers as `@import("assets_manager")` (see `Options.getModule` in `build.zig`).
/// Re-exports every user-facing submodule so generated code and runtime code share one namespace.
/// Generated bundles also refer back through this root (e.g. `@import("assets_manager").asset_loader.Asset`).
/// Re-export of the embed/binary descriptor vtables and `abstract` namespaces.
/// Consumed by `run.zig`, `build_steps_*` and downstream `build.zig` files to pick file/directory handlers.
pub const descriptors = @import("src/descriptors.zig");
/// Re-export of the code/bundle builders (`embed` and `binary`).
/// Consumed by `run.zig` and `build_steps_*` to turn an `assets_tree.Node` hierarchy into Zig source or a binary bundle.
pub const builders = @import("src/builders.zig");
/// Re-export of the `std.Build` integration (`embed.addGeneration`, `binary.addGeneration`).
/// This is what downstream packages call from their own `build.zig` to get `LazyPath` outputs with watch inputs.
pub const build_steps = @import("src/build_steps.zig");
/// Re-export of the filesystem tree model (`Node`, `create`, `createWithIo`).
/// Used by both builders to discover assets before code generation; also useful for custom tooling.
pub const assets_tree = @import("src/assets_tree.zig");
/// Re-export of small string helpers (`filenameToIdentifier`, `repeat`).
/// Used by all descriptors for identifier sanitizing and indentation, and by `Node.toString` for debug dumps.
pub const text_utils = @import("src/text_utils.zig");
/// Re-export of the runtime loader (`Asset`, `AssetLoader`).
/// Referenced by generated code: binary bundles emit `Asset(u8, path, offset, size)` through this namespace.
pub const asset_loader = @import("src/asset_loader.zig");
