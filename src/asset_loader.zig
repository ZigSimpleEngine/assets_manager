const std = @import("std");

// Cross-platform loader via C stdio.h. Works on desktop (glibc/musl/MSVC) and Emscripten.
// Emscripten's virtual FS implements fopen/fseek/fread, so the same bundle
// file must be preloaded/embedded via emcc `--embed-file` or `--preload-file`.

const c = @cImport(@cInclude("stdio.h"));

/// Generic asset loader parameterized by bundle path, offset and size.
/// The loader is a singleton: the first successful `instance` caches the bytes,
/// subsequent calls return the cached slice. `unload` frees it.
/// Cross-platform: uses `fopen`/`fseek`/`fread`/`fclose` from C stdio.
pub fn Asset(comptime bundle_path: []const u8, comptime offset: usize, comptime size: usize) type {
    return struct {
        var cached: ?[]u8 = null;

        const bundle_cstr: [:0]const u8 = bundle_path ++ "\x00";

        /// Load the asset slice from the bundle. Returns an immutable view
        /// over heap-allocated memory owned by the loader. Caller must not free
        /// it directly; use `unload` instead.
        pub fn instance(allocator: std.mem.Allocator) ![]const u8 {
            if (cached) |d| return d;

            // Try multiple candidate paths for cross-platform robustness:
            // - bundle_path as given (works when file is in cwd or VFS root)
            // - "zig-out/bin/<bundle>" (desktop run from project root)
            // - "zig-out/web/<bundle>" (web)
            // - "/<bundle>" (emscripten absolute VFS)
            // - "./<bundle>"
            const candidates = [_][:0]const u8{
                bundle_cstr,
                "zig-out/bin/" ++ bundle_path ++ "\x00",
                "zig-out/web/" ++ bundle_path ++ "\x00",
                "/" ++ bundle_path ++ "\x00",
                "./" ++ bundle_path ++ "\x00",
            };
            var file: ?*c.FILE = null;
            for (candidates) |cand| {
                file = c.fopen(cand.ptr, "rb");
                if (file != null) break;
            }
            const f = file orelse return error.OpenFailed;
            defer _ = c.fclose(f);

            if (c.fseek(f, @intCast(offset), c.SEEK_SET) != 0) return error.SeekFailed;

            const buf = try allocator.alloc(u8, size);
            errdefer allocator.free(buf);

            if (size == 0) {
                cached = buf;
                return buf;
            }

            const read: usize = c.fread(buf.ptr, 1, size, f);
            if (read != size) {
                allocator.free(buf);
                return error.ReadFailed;
            }

            cached = buf;
            return buf;
        }

        /// Free the cached buffer if loaded. Idempotent.
        pub fn unload(allocator: std.mem.Allocator) void {
            if (cached) |d| {
                allocator.free(d);
                cached = null;
            }
        }

        pub fn isLoaded() bool {
            return cached != null;
        }

        pub fn getCached() ?[]const u8 {
            if (cached) |d| return d;
            return null;
        }

        pub const bundle = bundle_path;
        pub const byte_offset = offset;
        pub const byte_size = size;
    };
}

/// Helper that returns a type wrapping `Asset` with a nicer `init` name matching spec:
/// `const MyFile_data = AssetLoader.init("bundle.bin", .{ .offset = 0, .size = 123 })`
/// is equivalent to aliasing `Asset`.
pub const AssetLoader = struct {
    pub fn init(comptime bundle_path: []const u8, comptime offset: usize, comptime size: usize) type {
        return Asset(bundle_path, offset, size);
    }
    pub fn initSlice(comptime bundle_path: []const u8, comptime slice: struct { offset: usize, size: usize }) type {
        return Asset(bundle_path, slice.offset, slice.size);
    }
};

test "asset_loader - zero size" {
    const A = Asset("dummy.bin", 0, 0);
    try std.testing.expectEqual(@as(usize, 0), A.byte_size);
    try std.testing.expectEqual(@as(usize, 0), A.byte_offset);
}

test "asset_loader - distinct types" {
    const A1 = Asset("bundle.bin", 0, 10);
    const A2 = Asset("bundle.bin", 10, 20);
    try std.testing.expect(A1 != A2);
}
