const std = @import("std");

// Cross-platform loader via C stdio.h. Works on desktop (glibc/musl/MSVC) and Emscripten.
// Emscripten's virtual FS implements fopen/fseek/fread, so the same bundle
// file must be preloaded/embedded via emcc `--embed-file` or `--preload-file`.

const c = @cImport(@cInclude("stdio.h"));

fn isVecType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "len") and @hasDecl(T, "value_type");
}

/// Generic asset loader parameterized by element type, bundle path, offset and size.
/// Size is in bytes; instance returns a typed slice.
/// For Vec types (e.g. math.Vec(3,f32)), the bundle stores tightly packed scalars (3*f32 per Vec), not padded Vec structs.
/// The loader is a singleton: the first successful `instance` caches the typed array,
/// subsequent calls return the cached slice. `unload` frees it.
/// Cross-platform: uses `fopen`/`fseek`/`fread`/`fclose` from C stdio.
pub fn Asset(comptime T: type, comptime bundle_path: []const u8, comptime offset: usize, comptime size: usize) type {
    return struct {
        var cached: ?[]T = null;

        const bundle_cstr: [:0]const u8 = bundle_path ++ "\x00";
        const is_vec = isVecType(T);
        const Scalar = if (is_vec) T.value_type else T;
        const comps: usize = if (is_vec) T.len else 1;
        const bytes_per_elem: usize = comps * @sizeOf(Scalar);
        const elem_count: usize = if (size == 0) 0 else size / bytes_per_elem;

        /// Load the typed asset slice from the bundle. Returns an immutable view
        /// over heap-allocated memory owned by the loader. Caller must not free
        /// it directly; use `unload` instead.
        pub fn instance(allocator: std.mem.Allocator) ![]const T {
            if (cached) |d| return d;

            if (size % bytes_per_elem != 0) return error.SizeNotMultipleOfType;

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

            const count = elem_count;
            const buf = try allocator.alloc(T, count);
            errdefer allocator.free(buf);

            if (size == 0) {
                cached = buf;
                return buf;
            }

            if (is_vec) {
                // The file stores each Vec element as `comps` tightly packed scalars
                // (e.g. 3xf32 for Vec3 = 12 bytes), regardless of the in-memory Vec
                // size/alignment. Read raw bytes then expand into Vec lanes.
                const tmp = try allocator.alloc(u8, size);
                defer allocator.free(tmp);
                const read: usize = c.fread(tmp.ptr, 1, size, f);
                if (read != size) {
                    allocator.free(buf);
                    return error.ReadFailed;
                }
                for (0..count) |i| {
                    var vec: T = undefined;
                    inline for (0..comps) |j| {
                        const off = (i * comps + j) * @sizeOf(Scalar);
                        const val = std.mem.bytesToValue(Scalar, tmp[off..][0..@sizeOf(Scalar)]);
                        vec.v[j] = val;
                    }
                    buf[i] = vec;
                }
            } else {
                const bytes: []u8 = std.mem.sliceAsBytes(buf);
                if (bytes.len != size) {
                    allocator.free(buf);
                    return error.SizeMismatch;
                }
                const read: usize = c.fread(bytes.ptr, 1, size, f);
                if (read != size) {
                    allocator.free(buf);
                    return error.ReadFailed;
                }
            }

            cached = buf;
            return buf;
        }

        /// Raw bytes view convenience for u8 specialization; for generic T, still returns typed slice as bytes.
        pub fn instanceBytes(allocator: std.mem.Allocator) ![]const u8 {
            const typed = try instance(allocator);
            return std.mem.sliceAsBytes(typed);
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

        pub fn getCached() ?[]const T {
            if (cached) |d| return d;
            return null;
        }

        pub fn getCachedBytes() ?[]const u8 {
            if (cached) |d| return std.mem.sliceAsBytes(d);
            return null;
        }

        pub const bundle = bundle_path;
        pub const byte_offset = offset;
        pub const byte_size = size;
        pub const Element = T;
        pub const len: usize = elem_count;
    };
}

/// Helper that returns a type wrapping `Asset` with a nicer `init` name.
pub const AssetLoader = struct {
    pub fn init(comptime T: type, comptime bundle_path: []const u8, comptime offset: usize, comptime size: usize) type {
        return Asset(T, bundle_path, offset, size);
    }
    pub fn initRaw(comptime bundle_path: []const u8, comptime offset: usize, comptime size: usize) type {
        return Asset(u8, bundle_path, offset, size);
    }
    pub fn initSlice(comptime T: type, comptime bundle_path: []const u8, comptime slice: struct { offset: usize, size: usize }) type {
        return Asset(T, bundle_path, slice.offset, slice.size);
    }
    pub fn initSliceRaw(comptime bundle_path: []const u8, comptime slice: struct { offset: usize, size: usize }) type {
        return Asset(u8, bundle_path, slice.offset, slice.size);
    }
};

test "asset_loader - zero size" {
    const A = Asset(u8, "dummy.bin", 0, 0);
    try std.testing.expectEqual(@as(usize, 0), A.byte_size);
    try std.testing.expectEqual(@as(usize, 0), A.byte_offset);
}

test "asset_loader - distinct types" {
    const A1 = Asset(u8, "bundle.bin", 0, 10);
    const A2 = Asset(u8, "bundle.bin", 10, 20);
    try std.testing.expect(A1 != A2);
}

test "asset_loader - typed distinct" {
    const A_u8 = Asset(u8, "bundle.bin", 0, 4);
    const A_f32 = Asset(f32, "bundle.bin", 0, 4);
    try std.testing.expect(A_u8 != A_f32);
    try std.testing.expectEqual(@as(usize, 4), A_u8.len);
    try std.testing.expectEqual(@as(usize, 1), A_f32.len);
}

test "asset_loader - vec" {
    const Vec3 = struct {
        pub const len = 3;
        pub const value_type = f32;
        v: @Vector(3, f32),
    };
    const A = Asset(Vec3, "dummy.bin", 0, 12);
    try std.testing.expectEqual(@as(usize, 1), A.len);
    try std.testing.expectEqual(@as(usize, 12), A.byte_size);
    const B = Asset(Vec3, "dummy.bin", 0, 24);
    try std.testing.expectEqual(@as(usize, 2), B.len);
}
