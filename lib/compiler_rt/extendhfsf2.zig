const common = @import("./common.zig");
const extendf = @import("./extendf.zig").extendf;

pub const panic = common.panic;

comptime {
    if (common.want_gnu_abi) {
        @export(__gnu_h2f_ieee, .{ .name = "__gnu_h2f_ieee", .linkage = common.linkage });
    } else if (common.want_aeabi) {
        @export(__aeabi_h2f, .{ .name = "__aeabi_h2f", .linkage = common.linkage });
    } else {
        @export(__extendhfsf2, .{ .name = "__extendhfsf2", .linkage = common.linkage });
    }
}

pub fn __extendhfsf2(a: common.F16T) callconv(.C) f32 {
    return extendf(f32, f16, @bitCast(u16, a));
}

fn __gnu_h2f_ieee(a: common.F16T) callconv(.C) f32 {
    return extendf(f32, f16, @bitCast(u16, a));
}

fn __aeabi_h2f(a: u16) callconv(.AAPCS) f32 {
    return extendf(f32, f16, @bitCast(u16, a));
}
