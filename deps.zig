const std = @import("std");
pub const pkgs = struct {
    pub const hzzp = std.build.Pkg{
        .name = "hzzp",
        .path = .{ .path = "libs/zCord/lib/hzzp/src/main.zig" },
    };

    pub const wz = std.build.Pkg{
        .name = "wz",
        .path = .{ .path = "libs/zCord/lib/wz/src/main.zig" },
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "hzzp",
                .path = .{ .path = "libs/zCord/lib/hzzp/src/main.zig" },
            },
        },
    };

    pub const iguanaTLS = std.build.Pkg{
        .name = "iguanaTLS",
        .path = .{ .path = "libs/zCord/lib/iguanaTLS/src/main.zig" },
    };

    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
        @setEvalBranchQuota(1_000_000);
        inline for (std.meta.declarations(pkgs)) |decl| {
            if (decl.is_pub and decl.data == .Var) {
                artifact.addPackage(@field(pkgs, decl.name));
            }
        }
    }
};

pub const exports = struct {
    pub const zCord = std.build.Pkg{
        .name = "zCord",
        .path = .{ .path = "libs/zCord/src/main.zig" },
        .dependencies = &.{
            pkgs.hzzp,
            pkgs.wz,
            pkgs.iguanaTLS,
        },
    };
};
pub const base_dirs = struct {
    pub const hzzp = "libs/zCord/lib/hzzp";
    pub const wz = "libs/zCord/lib/wz";
    pub const iguanaTLS = "libs/zCord/lib/iguanaTLS";
};
