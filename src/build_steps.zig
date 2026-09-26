/// Namespace facade for the `std.Build` integration.
/// Exposes `embed.addGeneration` and `binary.addGeneration` behind one import
/// so downstream `build.zig` files write `build_steps.embed.*` or `build_steps.binary.*`.
/// Re-exported from `root.zig` and `build.zig` as the recommended build-time entry point.
/// Build step that generates Zig source via `@embedFile`.
/// Wraps `embed_builder` with `WriteFiles`, `LazyPath` outputs and directory watch inputs.
/// Used when assets should be compiled into the binary without a separate bundle file.
pub const embed = @import("build_steps_embed.zig");
/// Build step that generates a packed binary bundle plus a Zig loader map.
/// Wraps `binary_builder` with `WriteFiles`, `LazyPath` outputs and directory watch inputs.
/// Used for large assets, desktop bundles and Emscripten virtual-FS payloads.
pub const binary = @import("build_steps_binary.zig");
