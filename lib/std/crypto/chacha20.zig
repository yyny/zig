// Based on public domain Supercop by Daniel J. Bernstein

const std = @import("../std.zig");
const mem = std.mem;
const endian = std.endian;
const assert = std.debug.assert;
const testing = std.testing;
const builtin = @import("builtin");
const maxInt = std.math.maxInt;
const Poly1305 = std.crypto.Poly1305;

const QuarterRound = struct {
    a: usize,
    b: usize,
    c: usize,
    d: usize,
};

fn Rp(a: usize, b: usize, c: usize, d: usize) QuarterRound {
    return QuarterRound{
        .a = a,
        .b = b,
        .c = c,
        .d = d,
    };
}

fn initContext(key: [8]u32, d: [4]u32) [16]u32 {
    var ctx: [16]u32 = undefined;
    const c = "expand 32-byte k";
    const constant_le = comptime [_]u32{
        mem.readIntLittle(u32, c[0..4]),
        mem.readIntLittle(u32, c[4..8]),
        mem.readIntLittle(u32, c[8..12]),
        mem.readIntLittle(u32, c[12..16]),
    };
    mem.copy(u32, ctx[0..], constant_le[0..4]);
    mem.copy(u32, ctx[4..12], key[0..8]);
    mem.copy(u32, ctx[12..16], d[0..4]);

    return ctx;
}

// The chacha family of ciphers are based on the salsa family.
fn chacha20Core(x: []u32, input: [16]u32) void {
    for (x) |_, i|
        x[i] = input[i];

    const rounds = comptime [_]QuarterRound{
        Rp(0, 4, 8, 12),
        Rp(1, 5, 9, 13),
        Rp(2, 6, 10, 14),
        Rp(3, 7, 11, 15),
        Rp(0, 5, 10, 15),
        Rp(1, 6, 11, 12),
        Rp(2, 7, 8, 13),
        Rp(3, 4, 9, 14),
    };

    comptime var j: usize = 0;
    inline while (j < 20) : (j += 2) {
        // two-round cycles
        inline for (rounds) |r| {
            x[r.a] +%= x[r.b];
            x[r.d] = std.math.rotl(u32, x[r.d] ^ x[r.a], @as(u32, 16));
            x[r.c] +%= x[r.d];
            x[r.b] = std.math.rotl(u32, x[r.b] ^ x[r.c], @as(u32, 12));
            x[r.a] +%= x[r.b];
            x[r.d] = std.math.rotl(u32, x[r.d] ^ x[r.a], @as(u32, 8));
            x[r.c] +%= x[r.d];
            x[r.b] = std.math.rotl(u32, x[r.b] ^ x[r.c], @as(u32, 7));
        }
    }
}

fn hashToBytes(out: []u8, x: [16]u32) void {
    for (x) |_, i| {
        mem.writeIntLittle(u32, out[4 * i ..][0..4], x[i]);
    }
}

fn chaCha20_internal(out: []u8, in: []const u8, key: [8]u32, counter: [4]u32) void {
    var ctx = initContext(key, counter);
    var remaining: usize = if (in.len > out.len) in.len else out.len;
    var cursor: usize = 0;

    while (true) {
        var x: [16]u32 = undefined;
        var buf: [64]u8 = undefined;
        chacha20Core(x[0..], ctx);
        for (x) |_, i| {
            x[i] +%= ctx[i];
        }
        hashToBytes(buf[0..], x);
        if (remaining < 64) {
            var i: usize = 0;
            while (i < remaining) : (i += 1)
                out[cursor + i] = in[cursor + i] ^ buf[i];
            return;
        }

        var i: usize = 0;
        while (i < 64) : (i += 1)
            out[cursor + i] = in[cursor + i] ^ buf[i];

        cursor += 64;
        remaining -= 64;

        ctx[12] += 1;
    }
}

fn keyToWords(key: [32]u8) [8]u32 {
    var k: [8]u32 = undefined;
    k[0] = mem.readIntLittle(u32, key[0..4]);
    k[1] = mem.readIntLittle(u32, key[4..8]);
    k[2] = mem.readIntLittle(u32, key[8..12]);
    k[3] = mem.readIntLittle(u32, key[12..16]);
    k[4] = mem.readIntLittle(u32, key[16..20]);
    k[5] = mem.readIntLittle(u32, key[20..24]);
    k[6] = mem.readIntLittle(u32, key[24..28]);
    k[7] = mem.readIntLittle(u32, key[28..32]);

    return k;
}

/// ChaCha20 avoids the possibility of timing attacks, as there are no branches
/// on secret key data.
///
/// in and out should be the same length.
/// counter should generally be 0 or 1
///
/// ChaCha20 is self-reversing. To decrypt just run the cipher with the same
/// counter, nonce, and key.
pub fn chaCha20IETF(out: []u8, in: []const u8, counter: u32, key: [32]u8, nonce: [12]u8) void {
    assert(in.len >= out.len);
    assert((in.len >> 6) + counter <= maxInt(u32));

    var c: [4]u32 = undefined;
    c[0] = counter;
    c[1] = mem.readIntLittle(u32, nonce[0..4]);
    c[2] = mem.readIntLittle(u32, nonce[4..8]);
    c[3] = mem.readIntLittle(u32, nonce[8..12]);
    chaCha20_internal(out, in, keyToWords(key), c);
}

/// This is the original ChaCha20 before RFC 7539, which recommends using the
/// orgininal version on applications such as disk or file encryption that might
/// exceed the 256 GiB limit of the 96-bit nonce version.
pub fn chaCha20With64BitNonce(out: []u8, in: []const u8, counter: u64, key: [32]u8, nonce: [8]u8) void {
    assert(in.len >= out.len);
    assert(counter +% (in.len >> 6) >= counter);

    var cursor: usize = 0;
    const k = keyToWords(key);
    var c: [4]u32 = undefined;
    c[0] = @truncate(u32, counter);
    c[1] = @truncate(u32, counter >> 32);
    c[2] = mem.readIntLittle(u32, nonce[0..4]);
    c[3] = mem.readIntLittle(u32, nonce[4..8]);

    const block_size = (1 << 6);
    // The full block size is greater than the address space on a 32bit machine
    const big_block = if (@sizeOf(usize) > 4) (block_size << 32) else maxInt(usize);

    // first partial big block
    if (((@intCast(u64, maxInt(u32) - @truncate(u32, counter)) + 1) << 6) < in.len) {
        chaCha20_internal(out[cursor..big_block], in[cursor..big_block], k, c);
        cursor = big_block - cursor;
        c[1] += 1;
        if (comptime @sizeOf(usize) > 4) {
            // A big block is giant: 256 GiB, but we can avoid this limitation
            var remaining_blocks: u32 = @intCast(u32, (in.len / big_block));
            var i: u32 = 0;
            while (remaining_blocks > 0) : (remaining_blocks -= 1) {
                chaCha20_internal(out[cursor .. cursor + big_block], in[cursor .. cursor + big_block], k, c);
                c[1] += 1; // upper 32-bit of counter, generic chaCha20_internal() doesn't know about this.
                cursor += big_block;
            }
        }
    }

    chaCha20_internal(out[cursor..], in[cursor..], k, c);
}

// https://tools.ietf.org/html/rfc7539#section-2.4.2
test "crypto.chacha20 test vector sunscreen" {
    const expected_result = [_]u8{
        0x6e, 0x2e, 0x35, 0x9a, 0x25, 0x68, 0xf9, 0x80,
        0x41, 0xba, 0x07, 0x28, 0xdd, 0x0d, 0x69, 0x81,
        0xe9, 0x7e, 0x7a, 0xec, 0x1d, 0x43, 0x60, 0xc2,
        0x0a, 0x27, 0xaf, 0xcc, 0xfd, 0x9f, 0xae, 0x0b,
        0xf9, 0x1b, 0x65, 0xc5, 0x52, 0x47, 0x33, 0xab,
        0x8f, 0x59, 0x3d, 0xab, 0xcd, 0x62, 0xb3, 0x57,
        0x16, 0x39, 0xd6, 0x24, 0xe6, 0x51, 0x52, 0xab,
        0x8f, 0x53, 0x0c, 0x35, 0x9f, 0x08, 0x61, 0xd8,
        0x07, 0xca, 0x0d, 0xbf, 0x50, 0x0d, 0x6a, 0x61,
        0x56, 0xa3, 0x8e, 0x08, 0x8a, 0x22, 0xb6, 0x5e,
        0x52, 0xbc, 0x51, 0x4d, 0x16, 0xcc, 0xf8, 0x06,
        0x81, 0x8c, 0xe9, 0x1a, 0xb7, 0x79, 0x37, 0x36,
        0x5a, 0xf9, 0x0b, 0xbf, 0x74, 0xa3, 0x5b, 0xe6,
        0xb4, 0x0b, 0x8e, 0xed, 0xf2, 0x78, 0x5e, 0x42,
        0x87, 0x4d,
    };
    const input = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    var result: [114]u8 = undefined;
    const key = [_]u8{
        0,  1,  2,  3,  4,  5,  6,  7,
        8,  9,  10, 11, 12, 13, 14, 15,
        16, 17, 18, 19, 20, 21, 22, 23,
        24, 25, 26, 27, 28, 29, 30, 31,
    };
    const nonce = [_]u8{
        0, 0, 0, 0,
        0, 0, 0, 0x4a,
        0, 0, 0, 0,
    };

    chaCha20IETF(result[0..], input[0..], 1, key, nonce);
    testing.expectEqualSlices(u8, &expected_result, &result);

    // Chacha20 is self-reversing.
    var plaintext: [114]u8 = undefined;
    chaCha20IETF(plaintext[0..], result[0..], 1, key, nonce);
    testing.expect(mem.order(u8, input, &plaintext) == .eq);
}

// https://tools.ietf.org/html/draft-agl-tls-chacha20poly1305-04#section-7
test "crypto.chacha20 test vector 1" {
    const expected_result = [_]u8{
        0x76, 0xb8, 0xe0, 0xad, 0xa0, 0xf1, 0x3d, 0x90,
        0x40, 0x5d, 0x6a, 0xe5, 0x53, 0x86, 0xbd, 0x28,
        0xbd, 0xd2, 0x19, 0xb8, 0xa0, 0x8d, 0xed, 0x1a,
        0xa8, 0x36, 0xef, 0xcc, 0x8b, 0x77, 0x0d, 0xc7,
        0xda, 0x41, 0x59, 0x7c, 0x51, 0x57, 0x48, 0x8d,
        0x77, 0x24, 0xe0, 0x3f, 0xb8, 0xd8, 0x4a, 0x37,
        0x6a, 0x43, 0xb8, 0xf4, 0x15, 0x18, 0xa1, 0x1c,
        0xc3, 0x87, 0xb6, 0x69, 0xb2, 0xee, 0x65, 0x86,
    };
    const input = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var result: [64]u8 = undefined;
    const key = [_]u8{
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    };
    const nonce = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };

    chaCha20With64BitNonce(result[0..], input[0..], 0, key, nonce);
    testing.expectEqualSlices(u8, &expected_result, &result);
}

test "crypto.chacha20 test vector 2" {
    const expected_result = [_]u8{
        0x45, 0x40, 0xf0, 0x5a, 0x9f, 0x1f, 0xb2, 0x96,
        0xd7, 0x73, 0x6e, 0x7b, 0x20, 0x8e, 0x3c, 0x96,
        0xeb, 0x4f, 0xe1, 0x83, 0x46, 0x88, 0xd2, 0x60,
        0x4f, 0x45, 0x09, 0x52, 0xed, 0x43, 0x2d, 0x41,
        0xbb, 0xe2, 0xa0, 0xb6, 0xea, 0x75, 0x66, 0xd2,
        0xa5, 0xd1, 0xe7, 0xe2, 0x0d, 0x42, 0xaf, 0x2c,
        0x53, 0xd7, 0x92, 0xb1, 0xc4, 0x3f, 0xea, 0x81,
        0x7e, 0x9a, 0xd2, 0x75, 0xae, 0x54, 0x69, 0x63,
    };
    const input = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var result: [64]u8 = undefined;
    const key = [_]u8{
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 1,
    };
    const nonce = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };

    chaCha20With64BitNonce(result[0..], input[0..], 0, key, nonce);
    testing.expectEqualSlices(u8, &expected_result, &result);
}

test "crypto.chacha20 test vector 3" {
    const expected_result = [_]u8{
        0xde, 0x9c, 0xba, 0x7b, 0xf3, 0xd6, 0x9e, 0xf5,
        0xe7, 0x86, 0xdc, 0x63, 0x97, 0x3f, 0x65, 0x3a,
        0x0b, 0x49, 0xe0, 0x15, 0xad, 0xbf, 0xf7, 0x13,
        0x4f, 0xcb, 0x7d, 0xf1, 0x37, 0x82, 0x10, 0x31,
        0xe8, 0x5a, 0x05, 0x02, 0x78, 0xa7, 0x08, 0x45,
        0x27, 0x21, 0x4f, 0x73, 0xef, 0xc7, 0xfa, 0x5b,
        0x52, 0x77, 0x06, 0x2e, 0xb7, 0xa0, 0x43, 0x3e,
        0x44, 0x5f, 0x41, 0xe3,
    };
    const input = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var result: [60]u8 = undefined;
    const key = [_]u8{
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    };
    const nonce = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

    chaCha20With64BitNonce(result[0..], input[0..], 0, key, nonce);
    testing.expectEqualSlices(u8, &expected_result, &result);
}

test "crypto.chacha20 test vector 4" {
    const expected_result = [_]u8{
        0xef, 0x3f, 0xdf, 0xd6, 0xc6, 0x15, 0x78, 0xfb,
        0xf5, 0xcf, 0x35, 0xbd, 0x3d, 0xd3, 0x3b, 0x80,
        0x09, 0x63, 0x16, 0x34, 0xd2, 0x1e, 0x42, 0xac,
        0x33, 0x96, 0x0b, 0xd1, 0x38, 0xe5, 0x0d, 0x32,
        0x11, 0x1e, 0x4c, 0xaf, 0x23, 0x7e, 0xe5, 0x3c,
        0xa8, 0xad, 0x64, 0x26, 0x19, 0x4a, 0x88, 0x54,
        0x5d, 0xdc, 0x49, 0x7a, 0x0b, 0x46, 0x6e, 0x7d,
        0x6b, 0xbd, 0xb0, 0x04, 0x1b, 0x2f, 0x58, 0x6b,
    };
    const input = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var result: [64]u8 = undefined;
    const key = [_]u8{
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    };
    const nonce = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0 };

    chaCha20With64BitNonce(result[0..], input[0..], 0, key, nonce);
    testing.expectEqualSlices(u8, &expected_result, &result);
}

test "crypto.chacha20 test vector 5" {
    const expected_result = [_]u8{
        0xf7, 0x98, 0xa1, 0x89, 0xf1, 0x95, 0xe6, 0x69,
        0x82, 0x10, 0x5f, 0xfb, 0x64, 0x0b, 0xb7, 0x75,
        0x7f, 0x57, 0x9d, 0xa3, 0x16, 0x02, 0xfc, 0x93,
        0xec, 0x01, 0xac, 0x56, 0xf8, 0x5a, 0xc3, 0xc1,
        0x34, 0xa4, 0x54, 0x7b, 0x73, 0x3b, 0x46, 0x41,
        0x30, 0x42, 0xc9, 0x44, 0x00, 0x49, 0x17, 0x69,
        0x05, 0xd3, 0xbe, 0x59, 0xea, 0x1c, 0x53, 0xf1,
        0x59, 0x16, 0x15, 0x5c, 0x2b, 0xe8, 0x24, 0x1a,

        0x38, 0x00, 0x8b, 0x9a, 0x26, 0xbc, 0x35, 0x94,
        0x1e, 0x24, 0x44, 0x17, 0x7c, 0x8a, 0xde, 0x66,
        0x89, 0xde, 0x95, 0x26, 0x49, 0x86, 0xd9, 0x58,
        0x89, 0xfb, 0x60, 0xe8, 0x46, 0x29, 0xc9, 0xbd,
        0x9a, 0x5a, 0xcb, 0x1c, 0xc1, 0x18, 0xbe, 0x56,
        0x3e, 0xb9, 0xb3, 0xa4, 0xa4, 0x72, 0xf8, 0x2e,
        0x09, 0xa7, 0xe7, 0x78, 0x49, 0x2b, 0x56, 0x2e,
        0xf7, 0x13, 0x0e, 0x88, 0xdf, 0xe0, 0x31, 0xc7,

        0x9d, 0xb9, 0xd4, 0xf7, 0xc7, 0xa8, 0x99, 0x15,
        0x1b, 0x9a, 0x47, 0x50, 0x32, 0xb6, 0x3f, 0xc3,
        0x85, 0x24, 0x5f, 0xe0, 0x54, 0xe3, 0xdd, 0x5a,
        0x97, 0xa5, 0xf5, 0x76, 0xfe, 0x06, 0x40, 0x25,
        0xd3, 0xce, 0x04, 0x2c, 0x56, 0x6a, 0xb2, 0xc5,
        0x07, 0xb1, 0x38, 0xdb, 0x85, 0x3e, 0x3d, 0x69,
        0x59, 0x66, 0x09, 0x96, 0x54, 0x6c, 0xc9, 0xc4,
        0xa6, 0xea, 0xfd, 0xc7, 0x77, 0xc0, 0x40, 0xd7,

        0x0e, 0xaf, 0x46, 0xf7, 0x6d, 0xad, 0x39, 0x79,
        0xe5, 0xc5, 0x36, 0x0c, 0x33, 0x17, 0x16, 0x6a,
        0x1c, 0x89, 0x4c, 0x94, 0xa3, 0x71, 0x87, 0x6a,
        0x94, 0xdf, 0x76, 0x28, 0xfe, 0x4e, 0xaa, 0xf2,
        0xcc, 0xb2, 0x7d, 0x5a, 0xaa, 0xe0, 0xad, 0x7a,
        0xd0, 0xf9, 0xd4, 0xb6, 0xad, 0x3b, 0x54, 0x09,
        0x87, 0x46, 0xd4, 0x52, 0x4d, 0x38, 0x40, 0x7a,
        0x6d, 0xeb, 0x3a, 0xb7, 0x8f, 0xab, 0x78, 0xc9,
    };
    const input = [_]u8{
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,

        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    };
    var result: [256]u8 = undefined;
    const key = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    };
    const nonce = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    };

    chaCha20With64BitNonce(result[0..], input[0..], 0, key, nonce);
    testing.expectEqualSlices(u8, &expected_result, &result);
}

pub const chacha20poly1305_tag_size = 16;

pub fn chacha20poly1305SealDetached(ciphertext: []u8, tag: *[chacha20poly1305_tag_size]u8, plaintext: []const u8, data: []const u8, key: [32]u8, nonce: [12]u8) void {
    assert(ciphertext.len >= plaintext.len);

    // derive poly1305 key
    var polyKey = [_]u8{0} ** 32;
    chaCha20IETF(polyKey[0..], polyKey[0..], 0, key, nonce);

    // encrypt plaintext
    chaCha20IETF(ciphertext[0..plaintext.len], plaintext, 1, key, nonce);

    // construct mac
    var mac = Poly1305.init(polyKey[0..]);
    mac.update(data);
    if (data.len % 16 != 0) {
        const zeros = [_]u8{0} ** 16;
        const padding = 16 - (data.len % 16);
        mac.update(zeros[0..padding]);
    }
    mac.update(ciphertext[0..plaintext.len]);
    if (plaintext.len % 16 != 0) {
        const zeros = [_]u8{0} ** 16;
        const padding = 16 - (plaintext.len % 16);
        mac.update(zeros[0..padding]);
    }
    var lens: [16]u8 = undefined;
    mem.writeIntLittle(u64, lens[0..8], data.len);
    mem.writeIntLittle(u64, lens[8..16], plaintext.len);
    mac.update(lens[0..]);
    mac.final(tag);
}

pub fn chacha20poly1305Seal(ciphertextAndTag: []u8, plaintext: []const u8, data: []const u8, key: [32]u8, nonce: [12]u8) void {
    return chacha20poly1305SealDetached(ciphertextAndTag[0..plaintext.len], ciphertextAndTag[plaintext.len..][0..chacha20poly1305_tag_size], plaintext, data, key, nonce);
}

/// Verifies and decrypts an authenticated message produced by chacha20poly1305SealDetached.
pub fn chacha20poly1305OpenDetached(dst: []u8, ciphertext: []const u8, tag: *const [chacha20poly1305_tag_size]u8, data: []const u8, key: [32]u8, nonce: [12]u8) !void {
    // split ciphertext and tag
    assert(dst.len >= ciphertext.len);

    // derive poly1305 key
    var polyKey = [_]u8{0} ** 32;
    chaCha20IETF(polyKey[0..], polyKey[0..], 0, key, nonce);

    // construct mac
    var mac = Poly1305.init(polyKey[0..]);

    mac.update(data);
    if (data.len % 16 != 0) {
        const zeros = [_]u8{0} ** 16;
        const padding = 16 - (data.len % 16);
        mac.update(zeros[0..padding]);
    }
    mac.update(ciphertext);
    if (ciphertext.len % 16 != 0) {
        const zeros = [_]u8{0} ** 16;
        const padding = 16 - (ciphertext.len % 16);
        mac.update(zeros[0..padding]);
    }
    var lens: [16]u8 = undefined;
    mem.writeIntLittle(u64, lens[0..8], data.len);
    mem.writeIntLittle(u64, lens[8..16], ciphertext.len);
    mac.update(lens[0..]);
    var computedTag: [16]u8 = undefined;
    mac.final(computedTag[0..]);

    // verify mac in constant time
    // TODO: we can't currently guarantee that this will run in constant time.
    // See https://github.com/ziglang/zig/issues/1776
    var acc: u8 = 0;
    for (computedTag) |_, i| {
        acc |= (computedTag[i] ^ tag.*[i]);
    }
    if (acc != 0) {
        return error.AuthenticationFailed;
    }

    // decrypt ciphertext
    chaCha20IETF(dst[0..ciphertext.len], ciphertext, 1, key, nonce);
}

/// Verifies and decrypts an authenticated message produced by chacha20poly1305Seal.
pub fn chacha20poly1305Open(dst: []u8, ciphertextAndTag: []const u8, data: []const u8, key: [32]u8, nonce: [12]u8) !void {
    if (ciphertextAndTag.len < chacha20poly1305_tag_size) {
        return error.InvalidMessage;
    }
    const ciphertextLen = ciphertextAndTag.len - chacha20poly1305_tag_size;
    return try chacha20poly1305OpenDetached(dst, ciphertextAndTag[0..ciphertextLen], ciphertextAndTag[ciphertextLen..][0..chacha20poly1305_tag_size], data, key, nonce);
}

fn hchacha20(input: [16]u8, key: [32]u8) [32]u8 {
    var c: [4]u32 = undefined;
    for (c) |_, i| {
        c[i] = mem.readIntLittle(u32, input[4 * i ..][0..4]);
    }
    const ctx = initContext(keyToWords(key), c);
    var x: [16]u32 = undefined;
    chacha20Core(x[0..], ctx);
    var out: [32]u8 = undefined;
    mem.writeIntLittle(u32, out[0..4], x[0]);
    mem.writeIntLittle(u32, out[4..8], x[1]);
    mem.writeIntLittle(u32, out[8..12], x[2]);
    mem.writeIntLittle(u32, out[12..16], x[3]);
    mem.writeIntLittle(u32, out[16..20], x[12]);
    mem.writeIntLittle(u32, out[20..24], x[13]);
    mem.writeIntLittle(u32, out[24..28], x[14]);
    mem.writeIntLittle(u32, out[28..32], x[15]);

    return out;
}

fn extend(key: [32]u8, nonce: [24]u8) struct { key: [32]u8, nonce: [12]u8 } {
    var subnonce: [12]u8 = undefined;
    mem.set(u8, subnonce[0..4], 0);
    mem.copy(u8, subnonce[4..], nonce[16..24]);
    return .{
        .key = hchacha20(nonce[0..16].*, key),
        .nonce = subnonce,
    };
}

pub fn xChaCha20IETF(out: []u8, in: []const u8, counter: u32, key: [32]u8, nonce: [24]u8) void {
    const extended = extend(key, nonce);
    chaCha20IETF(out, in, counter, extended.key, extended.nonce);
}

pub const xchacha20poly1305_tag_size = 16;

pub fn xchacha20poly1305SealDetached(ciphertext: []u8, tag: *[chacha20poly1305_tag_size]u8, plaintext: []const u8, data: []const u8, key: [32]u8, nonce: [24]u8) void {
    const extended = extend(key, nonce);
    return chacha20poly1305SealDetached(ciphertext, tag, plaintext, data, extended.key, extended.nonce);
}

pub fn xchacha20poly1305Seal(ciphertextAndTag: []u8, plaintext: []const u8, data: []const u8, key: [32]u8, nonce: [24]u8) void {
    const extended = extend(key, nonce);
    return chacha20poly1305Seal(ciphertextAndTag, plaintext, data, extended.key, extended.nonce);
}

/// Verifies and decrypts an authenticated message produced by xchacha20poly1305SealDetached.
pub fn xchacha20poly1305OpenDetached(plaintext: []u8, ciphertext: []const u8, tag: *const [chacha20poly1305_tag_size]u8, data: []const u8, key: [32]u8, nonce: [24]u8) !void {
    const extended = extend(key, nonce);
    return try chacha20poly1305OpenDetached(plaintext, ciphertext, tag, data, extended.key, extended.nonce);
}

/// Verifies and decrypts an authenticated message produced by xchacha20poly1305Seal.
pub fn xchacha20poly1305Open(ciphertextAndTag: []u8, msgAndTag: []const u8, data: []const u8, key: [32]u8, nonce: [24]u8) !void {
    const extended = extend(key, nonce);
    return try chacha20poly1305Open(ciphertextAndTag, msgAndTag, data, extended.key, extended.nonce);
}

test "seal" {
    {
        const plaintext = "";
        const data = "";
        const key = [_]u8{
            0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f,
            0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
        };
        const nonce = [_]u8{ 0x7, 0x0, 0x0, 0x0, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47 };
        const exp_out = [_]u8{ 0xa0, 0x78, 0x4d, 0x7a, 0x47, 0x16, 0xf3, 0xfe, 0xb4, 0xf6, 0x4e, 0x7f, 0x4b, 0x39, 0xbf, 0x4 };

        var out: [exp_out.len]u8 = undefined;
        chacha20poly1305Seal(out[0..], plaintext, data, key, nonce);
        testing.expectEqualSlices(u8, exp_out[0..], out[0..]);
    }
    {
        const plaintext = [_]u8{
            0x4c, 0x61, 0x64, 0x69, 0x65, 0x73, 0x20, 0x61, 0x6e, 0x64, 0x20, 0x47, 0x65, 0x6e, 0x74, 0x6c,
            0x65, 0x6d, 0x65, 0x6e, 0x20, 0x6f, 0x66, 0x20, 0x74, 0x68, 0x65, 0x20, 0x63, 0x6c, 0x61, 0x73,
            0x73, 0x20, 0x6f, 0x66, 0x20, 0x27, 0x39, 0x39, 0x3a, 0x20, 0x49, 0x66, 0x20, 0x49, 0x20, 0x63,
            0x6f, 0x75, 0x6c, 0x64, 0x20, 0x6f, 0x66, 0x66, 0x65, 0x72, 0x20, 0x79, 0x6f, 0x75, 0x20, 0x6f,
            0x6e, 0x6c, 0x79, 0x20, 0x6f, 0x6e, 0x65, 0x20, 0x74, 0x69, 0x70, 0x20, 0x66, 0x6f, 0x72, 0x20,
            0x74, 0x68, 0x65, 0x20, 0x66, 0x75, 0x74, 0x75, 0x72, 0x65, 0x2c, 0x20, 0x73, 0x75, 0x6e, 0x73,
            0x63, 0x72, 0x65, 0x65, 0x6e, 0x20, 0x77, 0x6f, 0x75, 0x6c, 0x64, 0x20, 0x62, 0x65, 0x20, 0x69,
            0x74, 0x2e,
        };
        const data = [_]u8{ 0x50, 0x51, 0x52, 0x53, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7 };
        const key = [_]u8{
            0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f,
            0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
        };
        const nonce = [_]u8{ 0x7, 0x0, 0x0, 0x0, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47 };
        const exp_out = [_]u8{
            0xd3, 0x1a, 0x8d, 0x34, 0x64, 0x8e, 0x60, 0xdb, 0x7b, 0x86, 0xaf, 0xbc, 0x53, 0xef, 0x7e, 0xc2,
            0xa4, 0xad, 0xed, 0x51, 0x29, 0x6e, 0x8,  0xfe, 0xa9, 0xe2, 0xb5, 0xa7, 0x36, 0xee, 0x62, 0xd6,
            0x3d, 0xbe, 0xa4, 0x5e, 0x8c, 0xa9, 0x67, 0x12, 0x82, 0xfa, 0xfb, 0x69, 0xda, 0x92, 0x72, 0x8b,
            0x1a, 0x71, 0xde, 0xa,  0x9e, 0x6,  0xb,  0x29, 0x5,  0xd6, 0xa5, 0xb6, 0x7e, 0xcd, 0x3b, 0x36,
            0x92, 0xdd, 0xbd, 0x7f, 0x2d, 0x77, 0x8b, 0x8c, 0x98, 0x3,  0xae, 0xe3, 0x28, 0x9,  0x1b, 0x58,
            0xfa, 0xb3, 0x24, 0xe4, 0xfa, 0xd6, 0x75, 0x94, 0x55, 0x85, 0x80, 0x8b, 0x48, 0x31, 0xd7, 0xbc,
            0x3f, 0xf4, 0xde, 0xf0, 0x8e, 0x4b, 0x7a, 0x9d, 0xe5, 0x76, 0xd2, 0x65, 0x86, 0xce, 0xc6, 0x4b,
            0x61, 0x16, 0x1a, 0xe1, 0xb,  0x59, 0x4f, 0x9,  0xe2, 0x6a, 0x7e, 0x90, 0x2e, 0xcb, 0xd0, 0x60,
            0x6,  0x91,
        };

        var out: [exp_out.len]u8 = undefined;
        chacha20poly1305Seal(out[0..], plaintext[0..], data[0..], key, nonce);
        testing.expectEqualSlices(u8, exp_out[0..], out[0..]);
    }
}

test "open" {
    {
        const ciphertext = [_]u8{ 0xa0, 0x78, 0x4d, 0x7a, 0x47, 0x16, 0xf3, 0xfe, 0xb4, 0xf6, 0x4e, 0x7f, 0x4b, 0x39, 0xbf, 0x4 };
        const data = "";
        const key = [_]u8{
            0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f,
            0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
        };
        const nonce = [_]u8{ 0x7, 0x0, 0x0, 0x0, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47 };
        const exp_out = "";

        var out: [exp_out.len]u8 = undefined;
        try chacha20poly1305Open(out[0..], ciphertext[0..], data, key, nonce);
        testing.expectEqualSlices(u8, exp_out[0..], out[0..]);
    }
    {
        const ciphertext = [_]u8{
            0xd3, 0x1a, 0x8d, 0x34, 0x64, 0x8e, 0x60, 0xdb, 0x7b, 0x86, 0xaf, 0xbc, 0x53, 0xef, 0x7e, 0xc2,
            0xa4, 0xad, 0xed, 0x51, 0x29, 0x6e, 0x8,  0xfe, 0xa9, 0xe2, 0xb5, 0xa7, 0x36, 0xee, 0x62, 0xd6,
            0x3d, 0xbe, 0xa4, 0x5e, 0x8c, 0xa9, 0x67, 0x12, 0x82, 0xfa, 0xfb, 0x69, 0xda, 0x92, 0x72, 0x8b,
            0x1a, 0x71, 0xde, 0xa,  0x9e, 0x6,  0xb,  0x29, 0x5,  0xd6, 0xa5, 0xb6, 0x7e, 0xcd, 0x3b, 0x36,
            0x92, 0xdd, 0xbd, 0x7f, 0x2d, 0x77, 0x8b, 0x8c, 0x98, 0x3,  0xae, 0xe3, 0x28, 0x9,  0x1b, 0x58,
            0xfa, 0xb3, 0x24, 0xe4, 0xfa, 0xd6, 0x75, 0x94, 0x55, 0x85, 0x80, 0x8b, 0x48, 0x31, 0xd7, 0xbc,
            0x3f, 0xf4, 0xde, 0xf0, 0x8e, 0x4b, 0x7a, 0x9d, 0xe5, 0x76, 0xd2, 0x65, 0x86, 0xce, 0xc6, 0x4b,
            0x61, 0x16, 0x1a, 0xe1, 0xb,  0x59, 0x4f, 0x9,  0xe2, 0x6a, 0x7e, 0x90, 0x2e, 0xcb, 0xd0, 0x60,
            0x6,  0x91,
        };
        const data = [_]u8{ 0x50, 0x51, 0x52, 0x53, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7 };
        const key = [_]u8{
            0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f,
            0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
        };
        const nonce = [_]u8{ 0x7, 0x0, 0x0, 0x0, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47 };
        const exp_out = [_]u8{
            0x4c, 0x61, 0x64, 0x69, 0x65, 0x73, 0x20, 0x61, 0x6e, 0x64, 0x20, 0x47, 0x65, 0x6e, 0x74, 0x6c,
            0x65, 0x6d, 0x65, 0x6e, 0x20, 0x6f, 0x66, 0x20, 0x74, 0x68, 0x65, 0x20, 0x63, 0x6c, 0x61, 0x73,
            0x73, 0x20, 0x6f, 0x66, 0x20, 0x27, 0x39, 0x39, 0x3a, 0x20, 0x49, 0x66, 0x20, 0x49, 0x20, 0x63,
            0x6f, 0x75, 0x6c, 0x64, 0x20, 0x6f, 0x66, 0x66, 0x65, 0x72, 0x20, 0x79, 0x6f, 0x75, 0x20, 0x6f,
            0x6e, 0x6c, 0x79, 0x20, 0x6f, 0x6e, 0x65, 0x20, 0x74, 0x69, 0x70, 0x20, 0x66, 0x6f, 0x72, 0x20,
            0x74, 0x68, 0x65, 0x20, 0x66, 0x75, 0x74, 0x75, 0x72, 0x65, 0x2c, 0x20, 0x73, 0x75, 0x6e, 0x73,
            0x63, 0x72, 0x65, 0x65, 0x6e, 0x20, 0x77, 0x6f, 0x75, 0x6c, 0x64, 0x20, 0x62, 0x65, 0x20, 0x69,
            0x74, 0x2e,
        };

        var out: [exp_out.len]u8 = undefined;
        try chacha20poly1305Open(out[0..], ciphertext[0..], data[0..], key, nonce);
        testing.expectEqualSlices(u8, exp_out[0..], out[0..]);

        // corrupting the ciphertext, data, key, or nonce should cause a failure
        var bad_ciphertext = ciphertext;
        bad_ciphertext[0] ^= 1;
        testing.expectError(error.AuthenticationFailed, chacha20poly1305Open(out[0..], bad_ciphertext[0..], data[0..], key, nonce));
        var bad_data = data;
        bad_data[0] ^= 1;
        testing.expectError(error.AuthenticationFailed, chacha20poly1305Open(out[0..], ciphertext[0..], bad_data[0..], key, nonce));
        var bad_key = key;
        bad_key[0] ^= 1;
        testing.expectError(error.AuthenticationFailed, chacha20poly1305Open(out[0..], ciphertext[0..], data[0..], bad_key, nonce));
        var bad_nonce = nonce;
        bad_nonce[0] ^= 1;
        testing.expectError(error.AuthenticationFailed, chacha20poly1305Open(out[0..], ciphertext[0..], data[0..], key, bad_nonce));

        // a short ciphertext should result in a different error
        testing.expectError(error.InvalidMessage, chacha20poly1305Open(out[0..], "", data[0..], key, bad_nonce));
    }
}

test "crypto.xchacha20" {
    const key = [_]u8{69} ** 32;
    const nonce = [_]u8{42} ** 24;
    const input = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    {
        var ciphertext: [input.len]u8 = undefined;
        xChaCha20IETF(ciphertext[0..], input[0..], 0, key, nonce);
        var buf: [2 * ciphertext.len]u8 = undefined;
        testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "{X}", .{ciphertext}), "E0A1BCF939654AFDBDC1746EC49832647C19D891F0D1A81FC0C1703B4514BDEA584B512F6908C2C5E9DD18D5CBC1805DE5803FE3B9CA5F193FB8359E91FAB0C3BB40309A292EB1CF49685C65C4A3ADF4F11DB0CD2B6B67FBC174BC2E860E8F769FD3565BBFAD1C845E05A0FED9BE167C240D");
    }
    {
        const data = "Additional data";
        var ciphertext: [input.len + xchacha20poly1305_tag_size]u8 = undefined;
        xchacha20poly1305Seal(ciphertext[0..], input, data, key, nonce);
        var out: [input.len]u8 = undefined;
        try xchacha20poly1305Open(out[0..], ciphertext[0..], data, key, nonce);
        var buf: [2 * ciphertext.len]u8 = undefined;
        testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "{X}", .{ciphertext}), "994D2DD32333F48E53650C02C7A2ABB8E018B0836D7175AEC779F52E961780768F815C58F1AA52D211498DB89B9216763F569C9433A6BBFCEFB4D4A49387A4C5207FBB3B5A92B5941294DF30588C6740D39DC16FA1F0E634F7246CF7CDCB978E44347D89381B7A74EB7084F754B90BDE9AAF5A94B8F2A85EFD0B50692AE2D425E234");
        testing.expectEqualSlices(u8, out[0..], input);
        ciphertext[0] += 1;
        testing.expectError(error.AuthenticationFailed, xchacha20poly1305Open(out[0..], ciphertext[0..], data, key, nonce));
    }
}

pub const Chacha20Poly1305 = struct {
    pub const tag_length = 16;
    pub const nonce_length = 12;
    pub const key_length = 32;

    /// c: ciphertext: output buffer should be of size m.len
    /// at: authentication tag: output MAC
    /// m: message
    /// ad: Associated Data
    /// npub: public nonce
    /// k: private key
    pub fn encrypt(c: []u8, at: *[tag_length]u8, m: []const u8, ad: []const u8, npub: [nonce_length]u8, k: [key_length]u8) void {
        assert(c.len == m.len);
        return chacha20poly1305SealDetached(c, at, m, ad, k, npub);
    }

    /// m: message: output buffer should be of size c.len
    /// c: ciphertext
    /// at: authentication tag
    /// ad: Associated Data
    /// npub: public nonce
    /// k: private key
    /// NOTE: the check of the authentication tag is currently not done in constant time
    pub fn decrypt(m: []u8, c: []const u8, at: [tag_length]u8, ad: []const u8, npub: [nonce_length]u8, k: [key_length]u8) !void {
        assert(c.len == m.len);
        return try chacha20poly1305OpenDetached(m, c, at[0..], ad, k, npub);
    }
};

pub const XChacha20Poly1305 = struct {
    pub const tag_length = 16;
    pub const nonce_length = 24;
    pub const key_length = 32;

    /// c: ciphertext: output buffer should be of size m.len
    /// at: authentication tag: output MAC
    /// m: message
    /// ad: Associated Data
    /// npub: public nonce
    /// k: private key
    pub fn encrypt(c: []u8, at: *[tag_length]u8, m: []const u8, ad: []const u8, npub: [nonce_length]u8, k: [key_length]u8) void {
        assert(c.len == m.len);
        return xchacha20poly1305SealDetached(c, at, m, ad, k, npub);
    }

    /// m: message: output buffer should be of size c.len
    /// c: ciphertext
    /// at: authentication tag
    /// ad: Associated Data
    /// npub: public nonce
    /// k: private key
    /// NOTE: the check of the authentication tag is currently not done in constant time
    pub fn decrypt(m: []u8, c: []const u8, at: [tag_length]u8, ad: []const u8, npub: [nonce_length]u8, k: [key_length]u8) !void {
        assert(c.len == m.len);
        return try xchacha20poly1305OpenDetached(m, c, at[0..], ad, k, npub);
    }
};

test "chacha20 AEAD API" {
    const aeads = [_]type{ Chacha20Poly1305, XChacha20Poly1305 };
    const input = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    const data = "Additional data";

    inline for (aeads) |aead| {
        const key = [_]u8{69} ** aead.key_length;
        const nonce = [_]u8{42} ** aead.nonce_length;
        var ciphertext: [input.len]u8 = undefined;
        var tag: [aead.tag_length]u8 = undefined;
        var out: [input.len]u8 = undefined;

        aead.encrypt(ciphertext[0..], tag[0..], input, data, nonce, key);
        try aead.decrypt(out[0..], ciphertext[0..], tag, data[0..], nonce, key);
        testing.expectEqualSlices(u8, out[0..], input);
        ciphertext[0] += 1;
        testing.expectError(error.AuthenticationFailed, aead.decrypt(out[0..], ciphertext[0..], tag, data[0..], nonce, key));
    }
}
