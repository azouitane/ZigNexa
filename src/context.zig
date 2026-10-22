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

    /// Add a response header after copying both slices into httpz's request
    /// response storage. Use when either input does not outlive response writing.
    pub fn HeaderCopy(self: *Context, name: []const u8, value: []const u8) !void {
        const owned_name = try self.response.arena.dupe(u8, name);
        const owned_value = try self.response.arena.dupe(u8, value);
        self.response.header(owned_name, owned_value);
    }

    /// Set the response status and plain-text body. httpz writes after dispatch.
    pub fn String(self: *Context, status: u16, body: []const u8) !void {
        self.response.status = status;
        self.response.content_type = .TEXT;
        self.response.clearWriter();
        self.response.body = body;
    }

    /// Copy a plain-text body into httpz's request response storage.
    pub fn StringCopy(self: *Context, status: u16, body: []const u8) !void {
        const owned_body = try self.response.arena.dupe(u8, body);
        try self.String(status, owned_body);
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
    testing.header("x-test", "request-value");
    testing.req.params.addValue("42");
    var names = [_][]const u8{"id"};
    testing.req.params.addNames(&names);
    var context = Context{ .request = testing.req, .response = testing.res };

    try std.testing.expectEqualStrings("42", context.Param("id"));
    try std.testing.expectEqualStrings("3", (try context.Query("page")).?);
    try std.testing.expect((try context.Query("view")) == null);
    try std.testing.expectEqualStrings("request-value", context.RequestHeader("x-test").?);
    try context.String(201, "created");
    try std.testing.expectEqual(@as(u16, 201), testing.res.status);
    try std.testing.expectEqualStrings("created", testing.res.body);
    try std.testing.expectEqual(httpz.ContentType.TEXT, testing.res.content_type.?);

    try context.JSON(200, .{ .ok = true });
    try std.testing.expectEqual(@as(u16, 200), testing.res.status);
    try std.testing.expectEqual(httpz.ContentType.JSON, testing.res.content_type.?);
    try std.testing.expectEqualStrings("{\"ok\":true}", testing.res.buffer.writer.buffered());

    var temporary_body = [_]u8{ 'o', 'w', 'n', 'e', 'd' };
    try context.StringCopy(200, temporary_body[0..]);
    @memset(&temporary_body, 'x');
    try std.testing.expectEqualStrings("owned", testing.res.body);

    var temporary_name = [_]u8{ 'x', '-', 't', 'e', 's', 't' };
    var temporary_value = [_]u8{ 'c', 'o', 'p', 'i', 'e', 'd' };
    try context.HeaderCopy(temporary_name[0..], temporary_value[0..]);
    @memset(&temporary_name, 'x');
    @memset(&temporary_value, 'x');
    try std.testing.expectEqualStrings("copied", testing.res.headers.get("x-test").?);
}

fn testContinuation(pointer: *anyopaque) anyerror!void {
    const calls: *usize = @ptrCast(@alignCast(pointer));
    calls.* += 1;
}
