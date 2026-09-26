/// Shared Zig standard library import.
/// Provides `mem.Allocator`, `ArrayList`, `ascii` helpers and `fmt` used by both utilities below.
const std = @import("std");

/// Converts an arbitrary file name into a valid Zig identifier.
/// Sanitizes digits at the start, keeps alphanumerics and `_`, and collapses any other run into one `_`.
/// Used by `embed`/`binary` descriptors to derive `pub const <name>` bindings from `Node.name`,
/// and by `build_steps_binary.generateSync` for the single-file fallback.
/// - `allocator` - general purpose allocator owning the returned slice.
/// - `filename` - raw file or directory base name from the assets tree or filesystem.
///
/// Return: newly owned identifier string; caller owns it and must free it.
pub fn filenameToIdentifier(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    if (filename.len == 0) {
        return allocator.dupe(u8, "_");
    }

    if (std.ascii.isDigit(filename[0])) {
        try out.append(allocator, '_');
    }

    var last_was_underscore = false;

    for (filename) |c| {
        if (std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '_') {
            try out.append(allocator, c);
            last_was_underscore = false;
        } else {
            if (!last_was_underscore) {
                try out.append(allocator, '_');
                last_was_underscore = true;
            }
        }
    }

    if (out.items.len == 0) {
        try out.append(allocator, '_');
    }

    return out.toOwnedSlice(allocator);
}

/// Repeats a string slice `n` times.
/// Used for codegen indentation (`" "` times `depth * spaces_per_depth` in descriptors)
/// and for tree-dump prefixes (`Node.depth_prefix` times `depth` in `Node.toString`).
/// - `allocator` - general purpose allocator owning the returned slice.
/// - `s` - slice to repeat; may be any short pattern such as `" "` or `"----"`.
/// - `n` - repeat count; `0` is a special case returning `null` instead of an empty allocation.
///
/// Return: owned repeated string, or `null` when `n == 0` so callers can use `prefix orelse ""`.
pub fn repeat(allocator: std.mem.Allocator, s: []const u8, n: usize) !?[]u8 {
    if (n == 0) return null;

    const out = try allocator.alloc(u8, s.len * n);
    errdefer allocator.free(out);

    for (0..n) |i| {
        const start = i * s.len;
        @memcpy(out[start .. start + s.len], s);
    }

    return out;
}
