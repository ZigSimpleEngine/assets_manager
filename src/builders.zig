/// Namespace facade for the two builder backends.
/// Keeps `embed` (Zig source via `@embedFile`) and `binary` (packed `.bin` bundle plus loader map)
/// behind one import so callers write `builders.embed.*` or `builders.binary.*`.
/// Used by `run.zig`, `build_steps_embed`, `build_steps_binary` and re-exported from `root.zig`.
/// Embed backend that generates Zig source directly.
/// Walks an `assets_tree.Node` and emits `@embedFile` constants and `struct` hierarchy.
/// Used for small assets and shaders where a separate bundle file is unwanted.
pub const embed = @import("embed_builder.zig");
/// Binary backend that packs raw bytes into one bundle file.
/// Walks an `assets_tree.Node`, appends leaf bytes sequentially and emits `Asset(u8, ...)` loader code.
/// Used for large assets and web builds where one bundle file is preloaded or embedded.
pub const binary = @import("binary_builder.zig");
