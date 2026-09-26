/// Standard library used for the `std.process.Init` entry protocol.
const std = @import("std");
/// Builder backend used by this dev tool.
/// Only the `embed` branch is exercised here to regenerate `generated/src.zig` from the working directory.
const builders = @import("src/builders.zig");
/// Descriptor family used by this dev tool.
/// Provides `EmbedFileDescriptor`, `EmbedDirectoryDescriptor` and the `abstract.Descriptor` vtable type below.
const descriptors = @import("src/descriptors.zig");

/// Developer entry point that regenerates the checked-in `generated/src.zig`.
/// Builds a two-entry descriptor table (file plus directory), then calls
/// `builders.embed.createCodeFileFromAssets` over `"."` so local runs refresh the sample output.
/// Not part of the library API; downstream projects use `build_steps` instead.
/// - `init` - process init carrying the allocator and threaded IO needed for directory walking and file output.
pub fn main(init: std.process.Init) !void {
    var file_descriptor: descriptors.embed.EmbedFileDescriptor = .{};
    var dir_descriptor: descriptors.embed.EmbedDirectoryDescriptor = .{};

    const descriptors_array = [_]*const descriptors.embed.abstract.Descriptor{
        &file_descriptor.descriptor(),
        &dir_descriptor.descriptor(),
    };

    try builders.embed.createCodeFileFromAssets(init, "generated/src.zig", ".", .{
        .print_results = false,
        .descriptors = &descriptors_array,
    });
}
