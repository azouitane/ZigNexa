//! Request-scoped helpers. Request and response storage belongs to httpz and is
//! valid only for the duration of the active request callback.
const httpz = @import("httpz");
const std = @import("std");

/// Framework view over the active httpz request and response.
pub const Context = struct {
    request: *httpz.Request,
    response: *httpz.Response,
    next_context: ?*anyopaque = null,
    next_callback: ?*const fn (*anyopaque) anyerror!void = null,

    /// Return a path parameter, or an empty slice when the route has no such key.
    pub fn Param(self: *Context, name: []const u8) []const u8 {
        return self.request.param(name) orelse "";
    }

    /// Read a query parameter. The returned bytes live with this request.
    pub fn Query(self: *Context, name: []const u8) !?[]const u8 {
        const query = try self.request.query();
        return query.get(name);
    }

    /// Read a request header by lowercase name, as required by httpz.
    pub fn RequestHeader(self: *Context, name: []const u8) ?[]const u8 {
        return self.request.header(name);
    }

    /// Add a response header. Header names and values must remain valid through response writing.
    pub fn Header(self: *Context, name: []const u8, value: []const u8) void {
        self.response.header(name, value);
    }

    /// Set the response status and plain-text body. httpz writes after dispatch.
    pub fn String(self: *Context, status: u16, body: []const u8) !void {
        self.response.status = status;
        self.response.content_type = .TEXT;
        self.response.clearWriter();
        self.response.body = body;
    }

    /// Serialize a JSON value into the response buffer and set its status.
    pub fn JSON(self: *Context, status: u16, value: anytype) !void {
        self.response.status = status;
        self.response.body = "";
        self.response.clearWriter();
        try self.response.json(value, .{});
    }

    /// Continue to the next middleware or route handler.
    /// Middleware short-circuits by returning without calling this method.
    pub fn Next(self: *Context) !void {
        const callback = self.next_callback orelse return error.NextUnavailable;
        const next_context = self.next_context orelse return error.NextUnavailable;
        try callback(next_context);
    }

    /// Internal constructor used by the httpz middleware adapter.
    pub fn withExecutor(req: *httpz.Request, res: *httpz.Response, executor: *httpz.Server(void).Executor) Context {
        return .{
            .request = req,
            .response = res,
            .next_context = executor,
            .next_callback = executeNext,
        };
    }

    fn executeNext(pointer: *anyopaque) anyerror!void {
        const executor: *httpz.Server(void).Executor = @ptrCast(@alignCast(pointer));
        try executor.next();
    }
};

test "Next invokes the installed continuation" {
    var calls: usize = 0;
    var context = Context{
        .request = undefined,
        .response = undefined,
        .next_context = &calls,
        .next_callback = testContinuation,
    };
    try context.Next();
    try @import("std").testing.expectEqual(@as(usize, 1), calls);
}

test "Context reads query values and prepares text and JSON responses" {
    var testing = httpz.testing.init(.{});
    defer testing.deinit();
    testing.query("page", "3");
    var context = Context{ .request = testing.req, .response = testing.res };

    try std.testing.expectEqualStrings("3", (try context.Query("page")).?);
    try context.String(201, "created");
    try std.testing.expectEqual(@as(u16, 201), testing.res.status);
    try std.testing.expectEqualStrings("created", testing.res.body);
    try std.testing.expectEqual(httpz.ContentType.TEXT, testing.res.content_type.?);

    try context.JSON(200, .{ .ok = true });
    try std.testing.expectEqual(@as(u16, 200), testing.res.status);
    try std.testing.expectEqual(httpz.ContentType.JSON, testing.res.content_type.?);
    try std.testing.expectEqualStrings("{\"ok\":true}", testing.res.buffer.writer.buffered());
}

fn testContinuation(pointer: *anyopaque) anyerror!void {
    const calls: *usize = @ptrCast(@alignCast(pointer));
    calls.* += 1;
}
