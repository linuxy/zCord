const std = @import("std");
const hzzp = @import("hzzp");
const iguanaTLS = @import("iguanaTLS");

const bot_agent = "zCord/0.0.1";

pub const root_ca = struct {
    const pem = @embedFile("../cacert.pem");
    var trust_anchor_chain: ?iguanaTLS.x509.TrustAnchorChain = null;

    /// Initializes the bundled root certificates
    /// This is a shared chain that's used whenever an PEM is not passed in
    pub fn preload(allocator: *std.mem.Allocator) !void {
        std.debug.assert(trust_anchor_chain == null);
        var fbs = std.io.fixedBufferStream(pem);
        trust_anchor_chain = try iguanaTLS.x509.TrustAnchorChain.from_pem(allocator, fbs.reader());
    }

    pub fn deinit() void {
        trust_anchor_chain.?.deinit();
        trust_anchor_chain = null;
    }
};

pub const SslTunnel = struct {
    allocator: *std.mem.Allocator,

    client: Client,
    tcp_conn: std.net.Stream,

    pub const Client = iguanaTLS.Client(std.net.Stream.Reader, std.net.Stream.Writer, iguanaTLS.ciphersuites.all, false);

    pub fn init(args: struct {
        allocator: *std.mem.Allocator,
        host: [:0]const u8,
        port: u16 = 443,
        pem: ?[]const u8 = null,
    }) !*SslTunnel {
        const result = try args.allocator.create(SslTunnel);
        errdefer args.allocator.destroy(result);

        result.allocator = args.allocator;

        const trusted_chain = if (args.pem) |pem| blk: {
            var fbs = std.io.fixedBufferStream(pem);
            break :blk try iguanaTLS.x509.TrustAnchorChain.from_pem(args.allocator, fbs.reader());
        } else
            root_ca.trust_anchor_chain.?;
        defer if (args.pem) |_| trusted_chain.deinit();

        result.tcp_conn = try std.net.tcpConnectToHost(args.allocator, args.host, args.port);
        errdefer result.tcp_conn.close();

        result.client = try iguanaTLS.client_connect(.{
            .reader = result.tcp_conn.reader(),
            .writer = result.tcp_conn.writer(),
            .cert_verifier = .default,
            .trusted_certificates = trusted_chain.data.items,
            .temp_allocator = args.allocator,
        }, args.host);
        errdefer client.close_notify() catch {};

        return result;
    }

    pub fn deinit(self: *SslTunnel) void {
        self.client.close_notify() catch {};
        self.tcp_conn.close();
        self.allocator.destroy(self);
    }
};

pub const Https = struct {
    allocator: *std.mem.Allocator,
    ssl_tunnel: *SslTunnel,
    buffer: []u8,
    client: HzzpClient,

    const HzzpClient = hzzp.base.client.BaseClient(SslTunnel.Stream.DstReader, SslTunnel.Stream.DstWriter);

    pub fn init(args: struct {
        allocator: *std.mem.Allocator,
        host: [:0]const u8,
        port: u16 = 443,
        method: []const u8,
        path: []const u8,
        pem: ?[]const u8,
    }) !Https {
        var ssl_tunnel = try SslTunnel.init(.{
            .allocator = args.allocator,
            .host = args.host,
            .port = args.port,
            .pem = args.pem,
        });
        errdefer ssl_tunnel.deinit();

        const buffer = try args.allocator.alloc(u8, 0x1000);
        errdefer args.allocator.free(buffer);

        var client = hzzp.base.client.create(buffer, ssl_tunnel.conn.reader(), ssl_tunnel.conn.writer());

        try client.writeStatusLine(args.method, args.path);

        try client.writeHeaderValue("Host", args.host);
        try client.writeHeaderValue("User-Agent", bot_agent);

        return Https{
            .allocator = args.allocator,
            .ssl_tunnel = ssl_tunnel,
            .buffer = buffer,
            .client = client,
        };
    }

    pub fn deinit(self: *Https) void {
        self.ssl_tunnel.deinit();
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    // TODO: fix this name
    pub fn printSend(self: *Https, comptime fmt: []const u8, args: anytype) !void {
        try self.client.writeHeaderFormat("Content-Length", "{d}", .{std.fmt.count(fmt, args)});
        try self.client.finishHeaders();

        try self.client.writer.print(fmt, args);
        try self.ssl_tunnel.conn.flush();
    }

    pub fn expectSuccessStatus(self: *Https) !u16 {
        if (try self.client.next()) |event| {
            if (event != .status) {
                return error.MissingStatus;
            }
            switch (event.status.code) {
                200...299 => return event.status.code,

                100...199 => return error.MiscInformation,

                300...399 => return error.MiscRedirect,

                400 => return error.BadRequest,
                401 => return error.Unauthorized,
                402 => return error.PaymentRequired,
                403 => return error.Forbidden,
                404 => return error.NotFound,
                429 => return error.TooManyRequests,
                405...428, 430...499 => return error.MiscClientError,

                500 => return error.InternalServerError,
                501...599 => return error.MiscServerError,
                else => unreachable,
            }
        } else {
            return error.NoResponse;
        }
    }

    pub fn completeHeaders(self: *Https) !void {
        while (try self.client.next()) |event| {
            if (event == .head_done) {
                return;
            }
        }
    }
};
