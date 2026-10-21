//! Built-in middleware for ZigNexa. Middleware follows httpz's ordered
//! executor: call `Context.Next` to continue, or return to short-circuit.
const std = @import("std");
const httpz = @import("httpz");
const Context = @import("context.zig").Context;

/// Log method, path, final status, and elapsed monotonic time.
/// Put Recovery after Logger if error responses should be logged as status 500.
pub fn Logger(c: *Context) !void {
    var timer = std.time.Timer.start() catch return c.Next();
    defer {
        const elapsed = timer.read();
        std.log.info("{s} {s} {d} {d}ns", .{
            c.request.method_string,
            c.request.url.path,
            c.response.status,
            elapsed,
        });
    }
    try c.Next();
}

/// Convert returned handler/middleware errors into a plain-text 500 response.
/// Zig panics are not caught: Zig has no supported general-purpose panic recovery.
pub fn Recovery(c: *Context) !void {
    c.Next() catch {
        c.response.status = 500;
        c.response.content_type = .TEXT;
        c.response.clearWriter();
        c.response.body = "Internal Server Error";
    };
}

/// CORS policy. Origins are exact-match values; `*` allows any origin.
pub const CorsConfig = struct {
    origins: []const []const u8,
    methods: []const u8 = "GET, POST, PUT, PATCH, DELETE, OPTIONS",
    headers: []const u8 = "Content-Type, Authorization, X-Request-ID",
    max_age_seconds: ?u32 = 600,
    allow_credentials: bool = false,
};

/// Create a configured CORS callback, usable with `app.Use(cors(config))`.
/// OPTIONS requests with Access-Control-Request-Method are answered with 204.
pub fn cors(comptime config: CorsConfig) *const fn (*Context) anyerror!void {
    return struct {
        fn run(c: *Context) anyerror!void {
            const origin = c.RequestHeader("origin") orelse return c.Next();
            const wildcard = config.origins.len == 1 and std.mem.eql(u8, config.origins[0], "*");
            var allowed = wildcard;
            if (!wildcard) {
                for (config.origins) |candidate| {
                    if (std.mem.eql(u8, candidate, origin)) {
                        allowed = true;
                        break;
                    }
                }
            }
            if (!allowed) return c.Next();

            c.Header("Vary", "Origin");
            c.Header("Access-Control-Allow-Origin", if (wildcard) "*" else origin);
            if (config.allow_credentials and !wildcard) {
                c.Header("Access-Control-Allow-Credentials", "true");
            }

            if (c.request.method == .OPTIONS and c.RequestHeader("access-control-request-method") != null) {
                c.Header("Access-Control-Allow-Methods", config.methods);
                c.Header("Access-Control-Allow-Headers", config.headers);
                if (config.max_age_seconds) |seconds| {
                    const value = try std.fmt.allocPrint(c.request.arena, "{d}", .{seconds});
                    c.Header("Access-Control-Max-Age", value);
                }
                c.response.status = 204;
                c.response.body = "";
                return;
            }
            try c.Next();
        }
    }.run;
}

/// Add or validate `X-Request-ID`. Valid client values use 1-128 ASCII
/// alphanumeric, dash, underscore, dot, or colon characters; other values are
/// replaced with 128-bit cryptographically random lowercase hex.
pub fn RequestID(c: *Context) !void {
    const provided = c.RequestHeader("x-request-id");
    const id = if (provided) |value|
        if (validRequestID(value)) value else try generateRequestID(c)
    else
        try generateRequestID(c);
    c.Header("X-Request-ID", id);
    try c.Next();
}

fn validRequestID(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_' and char != '.' and char != ':') {
            return false;
        }
    }
    return true;
}

fn generateRequestID(c: *Context) ![]const u8 {
    const digits = "0123456789abcdef";
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const output = try c.request.arena.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        output[index * 2] = digits[byte >> 4];
        output[index * 2 + 1] = digits[byte & 0x0f];
    }
    return output;
}

test "request id validation policy" {
    try std.testing.expect(validRequestID("api-01:abc_def.2"));
    try std.testing.expect(!validRequestID(""));
    try std.testing.expect(!validRequestID("bad value"));
    try std.testing.expect(!validRequestID("a" ** 129));
}

test "CORS preflight short-circuits with configured headers" {
    var testing = httpz.testing.init(.{});
    defer testing.deinit();
    testing.req.method = .OPTIONS;
    testing.header("origin", "https://example.test");
    testing.header("access-control-request-method", "POST");
    var context = Context{ .request = testing.req, .response = testing.res };

    try cors(.{
        .origins = &.{"https://example.test"},
        .methods = "GET, POST, OPTIONS",
        .headers = "Content-Type",
    })(&context);

    try std.testing.expectEqual(@as(u16, 204), testing.res.status);
    try std.testing.expectEqualStrings("https://example.test", testing.res.headers.get("Access-Control-Allow-Origin").?);
    try std.testing.expectEqualStrings("GET, POST, OPTIONS", testing.res.headers.get("Access-Control-Allow-Methods").?);
}

test "Recovery converts returned downstream errors to a generic 500" {
    var testing = httpz.testing.init(.{});
    defer testing.deinit();
    var unused: u8 = 0;
    var context = Context{
        .request = testing.req,
        .response = testing.res,
        .next_context = &unused,
        .next_callback = returnTestError,
    };
    try Recovery(&context);
    try std.testing.expectEqual(@as(u16, 500), testing.res.status);
    try std.testing.expectEqualStrings("Internal Server Error", testing.res.body);
}

test "RequestID preserves safe values and replaces malformed ones" {
    var valid_test = httpz.testing.init(.{});
    defer valid_test.deinit();
    valid_test.header("x-request-id", "client-42");
    var valid_context = Context{
        .request = valid_test.req,
        .response = valid_test.res,
        .next_context = &valid_test,
        .next_callback = ignoreNext,
    };
    try RequestID(&valid_context);
    try std.testing.expectEqualStrings("client-42", valid_test.res.headers.get("X-Request-ID").?);

    var invalid_test = httpz.testing.init(.{});
    defer invalid_test.deinit();
    invalid_test.header("x-request-id", "bad value");
    var invalid_context = Context{
        .request = invalid_test.req,
        .response = invalid_test.res,
        .next_context = &invalid_test,
        .next_callback = ignoreNext,
    };
    try RequestID(&invalid_context);
    const generated = invalid_test.res.headers.get("X-Request-ID").?;
    try std.testing.expectEqual(@as(usize, 32), generated.len);
    try std.testing.expect(validRequestID(generated));
}

fn returnTestError(_: *anyopaque) anyerror!void {
    return error.TestFailure;
}

fn ignoreNext(_: *anyopaque) anyerror!void {}
