/// Namespace facade for the two descriptor families.
/// Groups `embed` descriptors (direct Zig source) and `binary` descriptors (raw bytes plus loader mapping)
/// so `build_steps` configs and `run.zig` can pick them as `descriptors.embed.*` or `descriptors.binary.*`.
/// Re-exported from `root.zig` as the public customization point for asset handling.
/// Descriptors that emit `@embedFile` constants and directory structs.
/// Used by the embed builder and by the default `run.zig` tool setup.
pub const embed = @import("embed_descriptors.zig");
/// Descriptors that extract raw bytes for bundle packing plus a loader-code mapping.
/// Used by the binary builder; each entry pairs a `BinaryDescriptor` with its `MappingDescriptor`.
pub const binary = @import("binary_descriptors.zig");
