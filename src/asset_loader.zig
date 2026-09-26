/// Standard library for allocators, vector helpers and the test runner.
const std = @import("std");
/// C stdio (`fopen`, `fseek`, `fread`, `fclose`) for portable bundle loading.
/// Works on desktop libc variants and on Emscripten, whose virtual FS implements the same calls,
/// so the same bundle file only needs `--embed-file` or `--preload-file` on web.
const c = @cImport(@cInclude("stdio.h"));

/// Friendly facade over the `Asset` factory with intent-revealing constructor names.
/// Used by generated code indirectly and by hand-written code that prefers `initRaw` over spelling `u8`.
/// All four constructors return a loader type; the loader itself is a singleton caching its slice.
pub const AssetLoader = struct {
    /// Generic loader type for an arbitrary element type and bundle slice.
    /// Forwards to `Asset` unchanged; used for typed assets such as `f32` samples or `Vec` arrays.
    /// - `T` - element type of the returned slice.
    /// - `bundle_path` - compile-time bundle location probed at runtime through several candidate paths.
    /// - `offset` - byte offset of this asset inside the bundle.
    /// - `size` - byte length of this asset inside the bundle.
    ///
    /// Return: loader type owning the cached slice lifecycle.
    pub fn init(comptime T: type, comptime bundle_path: []const u8, comptime offset: usize, comptime size: usize) type {
        return Asset(T, bundle_path, offset, size);
    }

    /// Raw byte loader type for an opaque bundle slice.
    /// Shorthand for `Asset(u8, ...)` used by `RawBinaryDescriptor` output and single-file fallbacks.
    /// - `bundle_path` - compile-time bundle location probed at runtime.
    /// - `offset` - byte offset of this asset inside the bundle.
    /// - `size` - byte length of this asset inside the bundle.
    ///
    /// Return: loader type for `[]const u8`.
    pub fn initRaw(comptime bundle_path: []const u8, comptime offset: usize, comptime size: usize) type {
        return Asset(u8, bundle_path, offset, size);
    }

    /// Generic loader type taking a packed offset/size pair.
    /// Unpacks `slice.offset`/`slice.size` for call sites that already group geometry as one value.
    /// - `T` - element type of the returned slice.
    /// - `bundle_path` - compile-time bundle location probed at runtime.
    /// - `slice` - anonymous struct carrying `offset` and `size` together.
    ///
    /// Return: loader type owning the cached slice lifecycle.
    pub fn initSlice(comptime T: type, comptime bundle_path: []const u8, comptime slice: struct { offset: usize, size: usize }) type {
        return Asset(T, bundle_path, slice.offset, slice.size);
    }

    /// Raw byte loader type taking a packed offset/size pair.
    /// Combines `initRaw` and `initSlice` conveniences for untyped blobs described by one slice value.
    /// - `bundle_path` - compile-time bundle location probed at runtime.
    /// - `slice` - anonymous struct carrying `offset` and `size` together.
    ///
    /// Return: loader type for `[]const u8`.
    pub fn initSliceRaw(comptime bundle_path: []const u8, comptime slice: struct { offset: usize, size: usize }) type {
        return Asset(u8, bundle_path, slice.offset, slice.size);
    }
};

/// Generic asset loader parameterized by element type and bundle slice.
/// Emitted by name from `binary_builder` as `Asset(u8, path, offset, size)` and used at runtime
/// through `instance`/`unload`. Acts as a singleton: the first successful `instance` caches the typed
/// array, later calls return the same slice, and `unload` frees it. `Vec` element types with
/// `len` plus `value_type` are stored tightly packed as scalars and expanded on load.
/// - `T` - element type of the returned slice.
/// - `bundle_path` - compile-time bundle location probed through cwd, `zig-out` and VFS candidates.
/// - `offset` - byte offset of this asset inside the bundle.
/// - `size` - byte length of this asset inside the bundle; must be a multiple of the element stride.
///
/// Return: loader struct type with the singleton cache and typed accessors below.
pub fn Asset(comptime T: type, comptime bundle_path: []const u8, comptime offset: usize, comptime size: usize) type {
    return struct {
        /// Element type echoed back for generic consumers and compile-time tests.
        /// Lets callers name `A.Element` without repeating the original `T` parameter.
        pub const Element = T;

        /// Scalar lane type used for byte math; `T.value_type` for `Vec` types, otherwise `T` itself.
        /// Drives `bytes_per_elem` and the tight scalar unpacking path in `instance`.
        const Scalar = if (is_vec) T.value_type else T;

        /// Original bundle location echoed for introspection and debugging.
        /// Same value passed as `bundle_path`; not used for IO directly (see `bundle_cstr`).
        pub const bundle = bundle_path;
        /// Byte offset echoed for introspection and tests.
        /// Same value passed as `offset`; the actual seek happens in `instance`.
        pub const byte_offset = offset;
        /// Byte length echoed for introspection and tests.
        /// Same value passed as `size`; also guards `SizeNotMultipleOfType` checks in `instance`.
        pub const byte_size = size;
        /// Precomputed element count (`size / bytes_per_elem`, or `0` for empty assets).
        /// Backs `instance` allocation size and the `A.len` assertions in tests.
        pub const len: usize = elem_count;

        /// Null-terminated bundle path for `c.fopen`.
        /// Built once at comptime by appending `0x00` to `bundle_path`.
        const bundle_cstr: [:0]const u8 = bundle_path ++ "\x00";
        /// Whether `T` is a tight vector type detected by `isVecType`.
        /// Selects the scalar-expansion branch in `instance` instead of a direct byte copy.
        const is_vec = isVecType(T);
        /// Scalar lane count per element; `T.len` for vectors, otherwise `1`.
        /// Multiplied by `@sizeOf(Scalar)` to obtain the on-disk stride.
        const comps: usize = if (is_vec) T.len else 1;
        /// On-disk bytes per element (`comps * @sizeOf(Scalar)`).
        /// Validates `size` alignment and sizes the `instance` allocation.
        const bytes_per_elem: usize = comps * @sizeOf(Scalar);
        /// Element count derived from `size` and `bytes_per_elem`.
        /// Backs the public `len` above and the `count` used in `instance`.
        const elem_count: usize = if (size == 0) 0 else size / bytes_per_elem;

        /// Singleton cache holding the loaded typed array between `instance` and `unload`.
        /// `null` means not loaded yet; set on first success and cleared by `unload`.
        var cached: ?[]T = null;

        /// Loads the typed asset slice, caching it on first success.
        /// Probes several candidate bundle paths for desktop versus web layouts, seeks to `offset`,
        /// then either expands tightly packed scalars for `Vec` types or streams bytes directly.
        /// Subsequent calls return the cached slice without touching the filesystem.
        /// - `allocator` - allocator owning the cached buffer; must match the one passed to `unload`.
        ///
        /// Return: immutable view over loader-owned memory; do not free directly, call `unload`.
        pub fn instance(allocator: std.mem.Allocator) ![]const T {
            if (cached) |d| return d;

            if (size % bytes_per_elem != 0) return error.SizeNotMultipleOfType;

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

        /// Loads the asset and reinterprets it as raw bytes.
        /// Convenience over `instance` for consumers that need the underlying storage
        /// without caring about the element type.
        /// - `allocator` - allocator forwarded to `instance`.
        ///
        /// Return: byte view over the same cached buffer returned by `instance`.
        pub fn instanceBytes(allocator: std.mem.Allocator) ![]const u8 {
            const typed = try instance(allocator);
            return std.mem.sliceAsBytes(typed);
        }

        /// Frees the cached buffer when loaded; idempotent otherwise.
        /// Must be called with the same allocator that loaded the asset.
        /// - `allocator` - allocator that owns the cached buffer.
        pub fn unload(allocator: std.mem.Allocator) void {
            if (cached) |d| {
                allocator.free(d);
                cached = null;
            }
        }

        /// Reports whether the singleton cache currently holds loaded data.
        ///
        /// Return: true after a successful `instance` and before `unload`.
        pub fn isLoaded() bool {
            return cached != null;
        }

        /// Returns the cached typed slice without triggering IO.
        ///
        /// Return: cached view when loaded, otherwise `null`.
        pub fn getCached() ?[]const T {
            if (cached) |d| return d;
            return null;
        }

        /// Returns the cached buffer reinterpreted as bytes without triggering IO.
        ///
        /// Return: byte view over the cache when loaded, otherwise `null`.
        pub fn getCachedBytes() ?[]const u8 {
            if (cached) |d| return std.mem.sliceAsBytes(d);
            return null;
        }
    };
}

/// Detects tight vector element types eligible for scalar expansion on load.
/// Returns true for structs exposing both `len` and `value_type` declarations,
/// such as math `Vec(N, T)` types stored as `N` packed scalars rather than padded structs.
/// Used at comptime by `Asset` to select the unpacking branch.
/// - `T` - element type under test.
///
/// Return: true when `T` looks like a vector, otherwise false.
fn isVecType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "len") and @hasDecl(T, "value_type");
}

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
        pub const value_type = f32;

        pub const len = 3;

        v: @Vector(3, f32),
    };
    const A = Asset(Vec3, "dummy.bin", 0, 12);
    try std.testing.expectEqual(@as(usize, 1), A.len);
    try std.testing.expectEqual(@as(usize, 12), A.byte_size);
    const B = Asset(Vec3, "dummy.bin", 0, 24);
    try std.testing.expectEqual(@as(usize, 2), B.len);
}
