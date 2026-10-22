//! Application setup and route registration.
const std = @import("std");
const httpz = @import("httpz");
const Context = @import("context.zig").Context;
const handler = @import("handler.zig");

/// Type-erased httpz middleware handle owned by the creating app's server.
pub const Middleware = httpz.Middleware(void);
const MiddlewareList = std.ArrayListUnmanaged(Middleware);
const Router = httpz.Router(void, httpz.Action(void));

/// Owns the httpz server, its startup arena, route metadata, and middleware.
/// Register routes and middleware before calling `Run` or `listen`. The caller
/// owns this value and must call `deinit` exactly once after serving has ended.
/// `App` can be moved between calls because it does not retain an interior
/// pointer to the httpz server. Treat a move as an ownership transfer: after
/// copying into the new location, never use or deinitialize the old value.
/// Simultaneous copies are not safe. Do not move it while serving or while a
/// `RouteGroup` referring to it is in use.
pub const App = struct {
    server: httpz.Server(void),
    allocator: std.mem.Allocator,
    global_middleware: MiddlewareList = .empty,
    routes_registered: bool = false,

    const Self = @This();

    /// Construct an app using the page allocator and the default local address.
    /// Use `init` when the application owns a different allocator.
    pub fn Default() Self {
        return Self.init(std.heap.page_allocator, .{ .address = .localhost(8080) }) catch @panic("failed to initialize ZigNexa");
    }

    /// Initialize server and framework-owned storage from `allocator`.
    pub fn init(allocator: std.mem.Allocator, config: httpz.Config) !Self {
        const server = try httpz.Server(void).init(allocator, config, {});
        return .{
            .server = server,
            // httpz exposes its startup arena as an allocator. Registration
            // data has the same lifetime and is released by server.deinit().
            .allocator = server.arena,
        };
    }

    /// Register a GET route using a ZigNexa Context handler.
    pub fn GET(self: *Self, path: []const u8, comptime callback: anytype) void {
        self.tryGET(path, callback) catch @panic("failed to register GET route");
    }

    /// Fallible form of `GET` for applications that avoid registration panics.
    pub fn tryGET(self: *Self, path: []const u8, comptime callback: anytype) !void {
        try self.registerGrouped(.GET, path, handler.adapt(callback), &.{}, &.{});
    }

    /// Compatibility alias for `tryGET`.
    pub fn get(self: *Self, path: []const u8, comptime callback: anytype) !void {
        try self.tryGET(path, callback);
    }

    /// Register a POST route.
    pub fn POST(self: *Self, path: []const u8, comptime callback: anytype) void {
        self.tryPOST(path, callback) catch @panic("failed to register POST route");
    }

    /// Fallible POST registration.
    pub fn tryPOST(self: *Self, path: []const u8, comptime callback: anytype) !void {
        try self.registerGrouped(.POST, path, handler.adapt(callback), &.{}, &.{});
    }
    /// Register a PUT route.
    pub fn PUT(self: *Self, path: []const u8, comptime callback: anytype) void {
        self.tryPUT(path, callback) catch @panic("failed to register PUT route");
    }

    /// Fallible PUT registration.
    pub fn tryPUT(self: *Self, path: []const u8, comptime callback: anytype) !void {
        try self.registerGrouped(.PUT, path, handler.adapt(callback), &.{}, &.{});
    }

    /// Register a PATCH route.
    pub fn PATCH(self: *Self, path: []const u8, comptime callback: anytype) void {
        self.tryPATCH(path, callback) catch @panic("failed to register PATCH route");
    }

    /// Fallible PATCH registration.
    pub fn tryPATCH(self: *Self, path: []const u8, comptime callback: anytype) !void {
        try self.registerGrouped(.PATCH, path, handler.adapt(callback), &.{}, &.{});
    }

    /// Register a DELETE route.
    pub fn DELETE(self: *Self, path: []const u8, comptime callback: anytype) void {
        self.tryDELETE(path, callback) catch @panic("failed to register DELETE route");
    }

    /// Fallible DELETE registration.
    pub fn tryDELETE(self: *Self, path: []const u8, comptime callback: anytype) !void {
        try self.registerGrouped(.DELETE, path, handler.adapt(callback), &.{}, &.{});
    }

    /// Register a HEAD route.
    pub fn HEAD(self: *Self, path: []const u8, comptime callback: anytype) void {
        self.tryHEAD(path, callback) catch @panic("failed to register HEAD route");
    }

    /// Fallible HEAD registration.
    pub fn tryHEAD(self: *Self, path: []const u8, comptime callback: anytype) !void {
        try self.registerGrouped(.HEAD, path, handler.adapt(callback), &.{}, &.{});
    }

    /// Register an OPTIONS route.
    pub fn OPTIONS(self: *Self, path: []const u8, comptime callback: anytype) void {
        self.tryOPTIONS(path, callback) catch @panic("failed to register OPTIONS route");
    }

    /// Fallible OPTIONS registration.
    pub fn tryOPTIONS(self: *Self, path: []const u8, comptime callback: anytype) !void {
        try self.registerGrouped(.OPTIONS, path, handler.adapt(callback), &.{}, &.{});
    }

    /// Register any facade-supported method with route-local middleware.
    /// Returns an error for unsupported httpz methods or allocation failures.
    pub fn Handle(
        self: *Self,
        method: httpz.Method,
        path: []const u8,
        comptime callback: anytype,
        route_middleware: []const Middleware,
    ) !void {
        try self.registerGrouped(method, path, handler.adapt(callback), &.{}, route_middleware);
    }

    /// Register a GET route with route-local middleware handles.
    pub fn GETWithMiddleware(
        self: *Self,
        path: []const u8,
        comptime callback: anytype,
        route_middleware: []const Middleware,
    ) void {
        self.registerGrouped(.GET, path, handler.adapt(callback), &.{}, route_middleware) catch @panic("failed to register GET route");
    }

    /// Fallible form of `GETWithMiddleware`.
    pub fn tryGETWithMiddleware(
        self: *Self,
        path: []const u8,
        comptime callback: anytype,
        route_middleware: []const Middleware,
    ) !void {
        try self.registerGrouped(.GET, path, handler.adapt(callback), &.{}, route_middleware);
    }

    /// Register global middleware. Middleware runs in registration order and
    /// continues by calling `Context.Next`; omitting it short-circuits dispatch.
    pub fn Use(self: *Self, comptime callback: anytype) void {
        self.tryUse(callback) catch @panic("failed to register middleware");
    }

    /// Fallible form of `Use`.
    pub fn tryUse(self: *Self, comptime callback: anytype) !void {
        if (self.routes_registered) return error.MiddlewareAfterRoutes;
        try self.global_middleware.ensureUnusedCapacity(self.allocator, 1);
        const middleware = try self.server.middleware(handler.middlewareAdapter(callback), {});
        self.global_middleware.appendAssumeCapacity(middleware);
        self.server._middlewares = self.global_middleware.items;
        self.server._router.middlewares = self.global_middleware.items;
    }

    /// Create a reusable httpz middleware value for route-specific composition.
    /// The server owns its implementation and releases it during deinit.
    pub fn createMiddleware(self: *Self, comptime callback: anytype) !Middleware {
        return self.server.middleware(handler.middlewareAdapter(callback), {});
    }

    /// Start on localhost:`port`. The caller retains ownership and must call
    /// `deinit` after serving stops and all serving threads have finished.
    pub fn Run(self: *Self, port: u16) !void {
        self.server.config.address = .localhost(port);
        try self.server.listen();
    }

    /// Block serving with the address configured at initialization.
    pub fn listen(self: *Self) !void {
        try self.server.listen();
    }

    /// Stop serving. If `listen` runs on another thread, join that thread before
    /// calling `deinit` so no request can still use app-owned data.
    pub fn stop(self: *Self) void {
        self.server.stop();
    }

    /// Release httpz resources before route metadata. Do not use the app afterwards.
    pub fn deinit(self: *Self) void {
        self.server.deinit();
    }

    /// Create a route group. Prefix and middleware storage live in the app arena.
    /// Prefer `tryGroup` when allocation failure should be returned.
    pub fn Group(self: *Self, prefix: []const u8) @import("route_group.zig").RouteGroup {
        return self.tryGroup(prefix) catch @panic("failed to allocate route prefix");
    }

    /// Create a route group, returning prefix allocation errors to the caller.
    pub fn tryGroup(self: *Self, prefix: []const u8) !@import("route_group.zig").RouteGroup {
        return .{ .app = self, .prefix = try self.allocator.dupe(u8, prefix) };
    }

    /// Internal registration path shared with route groups and route options.
    pub fn registerGrouped(
        self: *Self,
        method: httpz.Method,
        path: []const u8,
        callback: httpz.Action(void),
        group_middleware: []const Middleware,
        route_middleware: []const Middleware,
    ) !void {
        try validateMethod(method);
        const retained_path = try self.allocator.dupe(u8, path);
        return self.registerGroupedOwned(method, retained_path, callback, group_middleware, route_middleware);
    }

    /// Internal route-group entry point. `path` must already be allocated from
    /// this app's arena and remain valid until `deinit`; group registration
    /// satisfies this by joining into that arena. Middleware slices are
    /// borrowed only for this call and copied into app-owned storage as needed.
    /// This remains public because `RouteGroup` is implemented in another
    /// source file; prefer public route methods unless you satisfy the contract.
    pub fn registerGroupedOwned(
        self: *Self,
        method: httpz.Method,
        path: []const u8,
        callback: httpz.Action(void),
        group_middleware: []const Middleware,
        route_middleware: []const Middleware,
    ) !void {
        try validateMethod(method);
        const local_count = try std.math.add(usize, group_middleware.len, route_middleware.len);
        const combined_count = try std.math.add(usize, self.global_middleware.items.len, local_count);
        const router: *Router = &self.server._router;
        const RouteConfig = @TypeOf(router.routeConfig(.{}));
        var local: []Middleware = &.{};
        var route_config: RouteConfig = .{};
        if (local_count != 0) {
            local = try self.allocator.alloc(Middleware, combined_count);
            @memcpy(local[0..self.global_middleware.items.len], self.global_middleware.items);
            @memcpy(local[self.global_middleware.items.len..][0..group_middleware.len], group_middleware);
            @memcpy(local[self.global_middleware.items.len + group_middleware.len ..], route_middleware);
            route_config = .{ .middlewares = local, .middleware_strategy = .replace };
        }
        // httpz may have partially added routing nodes before returning an
        // allocation error, so conservatively close global middleware setup.
        self.routes_registered = true;
        switch (method) {
            .GET => try router.tryGet(path, callback, route_config),
            .POST => try router.tryPost(path, callback, route_config),
            .PUT => try router.tryPut(path, callback, route_config),
            .PATCH => try router.tryPatch(path, callback, route_config),
            .DELETE => try router.tryDelete(path, callback, route_config),
            .HEAD => try router.tryHead(path, callback, route_config),
            .OPTIONS => try router.tryOptions(path, callback, route_config),
            else => unreachable,
        }
    }
};

fn validateMethod(method: httpz.Method) !void {
    switch (method) {
        .GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS => {},
        else => return error.UnsupportedMethod,
    }
}

test "global, group, and route middleware preserve append order" {
    var app = try App.init(std.testing.allocator, .{});
    defer app.deinit();

    try app.tryUse(testMiddlewareA);
    try std.testing.expectEqual(@as(usize, 1), app.server._middlewares.len);
    try std.testing.expectEqual(@as(usize, 1), app.server._router.middlewares.len);
    var group = app.Group("/v1");
    try group.tryUse(testMiddlewareB);
    const route_middleware = try app.createMiddleware(testMiddlewareC);
    try group.tryGETWithMiddleware("/items/:id", testHandler, &.{route_middleware});
    try group.tryPOST("/items", testHandler);

    const Params = @TypeOf(@as(httpz.Request, undefined).params);
    var params = try Params.init(app.allocator, 4);
    const route = app.server._router.route(.GET, "", "/v1/items/42", &params) orelse return error.RouteNotFound;

    try std.testing.expectEqual(@as(usize, 3), route.middlewares.len);
    try std.testing.expectEqual(@intFromPtr(app.global_middleware.items[0].ptr), @intFromPtr(route.middlewares[0].ptr));
    try std.testing.expectEqual(@intFromPtr(group.middleware.items[0].ptr), @intFromPtr(route.middlewares[1].ptr));
    try std.testing.expectEqual(@intFromPtr(route_middleware.ptr), @intFromPtr(route.middlewares[2].ptr));
    try std.testing.expectEqualStrings("42", params.get("id").?);
    params.reset();
    try std.testing.expect(app.server._router.route(.POST, "", "/v1/items", &params) != null);
}

test "global middleware can short-circuit a request" {
    var app = try App.init(std.testing.allocator, .{});
    defer app.deinit();
    try app.tryUse(testShortCircuit);

    var testing = httpz.testing.init(.{});
    defer testing.deinit();
    var executor = httpz.Server(void).Executor{
        .index = 0,
        .req = testing.req,
        .res = testing.res,
        .handler = {},
        .middlewares = app.global_middleware.items,
        .dispatchable_action = null,
    };
    try executor.next();
    try std.testing.expectEqual(@as(u16, 401), testing.res.status);
    try std.testing.expectEqualStrings("stopped", testing.res.body);
}

test "global, group, and route middleware execute in order and reach the handler" {
    var app = try App.init(std.testing.allocator, .{});
    defer app.deinit();

    try app.tryUse(traceGlobal);
    var api = try app.tryGroup("/api/v1");
    try api.tryUse(traceGroup);
    const route_middleware = try app.createMiddleware(traceRoute);
    try api.tryGETWithMiddleware("/items/:id", traceExampleHandler, &.{route_middleware});
    try api.tryPOST("/items", testHandler);

    var testing = httpz.testing.init(.{});
    defer testing.deinit();
    testing.query("view", "full");
    var trace: MiddlewareTrace = .{};
    try testing.req.middlewares.put("zignexa-test-trace", @ptrCast(&trace));

    const action = app.server._router.route(.GET, "", "/api/v1/items/42", testing.req.params) orelse return error.RouteNotFound;
    var executor = httpz.Server(void).Executor{
        .index = 0,
        .req = testing.req,
        .res = testing.res,
        .handler = {},
        .middlewares = action.middlewares,
        .dispatchable_action = action,
    };
    try executor.next();

    try std.testing.expectEqualStrings("GTRH", trace.slice());
    try std.testing.expectEqualStrings("{\"id\":\"42\",\"view\":\"full\"}", testing.res.buffer.writer.buffered());
}

test "example handler uses its default view when the query is absent" {
    var testing = httpz.testing.init(.{});
    defer testing.deinit();
    var trace: MiddlewareTrace = .{};
    try testing.req.middlewares.put("zignexa-test-trace", @ptrCast(&trace));
    var context = Context{ .request = testing.req, .response = testing.res };

    try traceExampleHandler(&context);

    try std.testing.expectEqualStrings("{\"id\":\"\",\"view\":\"summary\"}", testing.res.buffer.writer.buffered());
}

test "global middleware runs before the 404 for unmatched routes" {
    var app = try App.init(std.testing.allocator, .{});
    defer app.deinit();
    try app.tryUse(traceGlobal);

    var testing = httpz.testing.init(.{});
    defer testing.deinit();
    var trace: MiddlewareTrace = .{};
    try testing.req.middlewares.put("zignexa-test-trace", @ptrCast(&trace));
    var executor = httpz.Server(void).Executor{
        .index = 0,
        .req = testing.req,
        .res = testing.res,
        .handler = {},
        .middlewares = app.server._middlewares,
        .dispatchable_action = null,
    };

    try executor.next();
    try std.testing.expectEqualStrings("G", trace.slice());
    try std.testing.expectEqual(@as(u16, 404), testing.res.status);
    try std.testing.expectEqualStrings("Not Found", testing.res.body);
}

test "httpz executor returns 404 when no route matches" {
    var app = try App.init(std.testing.allocator, .{});
    defer app.deinit();
    var testing = httpz.testing.init(.{});
    defer testing.deinit();
    var executor = httpz.Server(void).Executor{
        .index = 0,
        .req = testing.req,
        .res = testing.res,
        .handler = {},
        .middlewares = &.{},
        .dispatchable_action = null,
    };
    try executor.next();
    try std.testing.expectEqual(@as(u16, 404), testing.res.status);
    try std.testing.expectEqualStrings("Not Found", testing.res.body);
}

test "app init and deinit release all app-owned allocations" {
    var app = try App.init(std.testing.allocator, .{});
    try app.tryUse(testMiddlewareA);
    try app.tryGET("/", testHandler);
    var group = app.Group("/v1/");
    try group.tryGET("items", testHandler);
    app.deinit();
}

test "init cleans up when any parent allocation fails" {
    for (0..24) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (App.init(failing.allocator(), .{})) |app_value| {
            var app = app_value;
            app.deinit();
        } else |_| {}
    }
}

test "route and middleware registration failures remain deinitializable" {
    for (0..48) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const app_value = App.init(failing.allocator(), .{}) catch continue;
        var app = app_value;
        app.tryUse(testMiddlewareA) catch {
            app.deinit();
            continue;
        };
        var group = app.Group("/v1");
        group.tryUse(testMiddlewareB) catch {
            app.deinit();
            continue;
        };
        app.tryGET("/items/:id", testHandler) catch {};
        app.deinit();
    }
}

test "unsupported method is rejected before route registration" {
    var app = try App.init(std.testing.allocator, .{});
    defer app.deinit();
    try std.testing.expectError(error.UnsupportedMethod, app.Handle(.CONNECT, "/", testHandler, &.{}));
    const Params = @TypeOf(@as(httpz.Request, undefined).params);
    var params = try Params.init(app.allocator, 1);
    defer params.deinit(app.allocator);
    try std.testing.expect(app.server._router.route(.CONNECT, "", "/", &params) == null);
}

test "groups retain independent prefixes and empty local middleware" {
    var app = try App.init(std.testing.allocator, .{});
    defer app.deinit();
    var first = app.Group("/one");
    var second = app.Group("/two/");
    try first.tryGET("/items", testHandler);
    try second.tryGET("items", testHandler);

    const Params = @TypeOf(@as(httpz.Request, undefined).params);
    var params = try Params.init(app.allocator, 1);
    defer params.deinit(app.allocator);
    try std.testing.expect(app.server._router.route(.GET, "", "/one/items", &params) != null);
    try std.testing.expect(app.server._router.route(.GET, "", "/two/items", &params) != null);
    const first_route = app.server._router.route(.GET, "", "/one/items", &params).?;
    try std.testing.expectEqual(@as(usize, 0), first_route.middlewares.len);
}

test "registered path and parameter names outlive the caller buffer" {
    var app = try App.init(std.testing.allocator, .{});
    defer app.deinit();
    var path = [_]u8{ '/', 'o', 'w', 'n', 'e', 'd', '/', ':', 'i', 'd' };
    try app.tryGET(path[0..], testHandler);
    @memset(&path, 'x');

    const Params = @TypeOf(@as(httpz.Request, undefined).params);
    var params = try Params.init(app.allocator, 1);
    defer params.deinit(app.allocator);
    try std.testing.expect(app.server._router.route(.GET, "", "/owned/42", &params) != null);
    try std.testing.expectEqualStrings("42", params.get("id").?);
}

test "app can move after route registration and register again" {
    var original = try App.init(std.testing.allocator, .{});
    try original.tryGET("/first", testHandler);
    // This is a single-owner transfer; the source value is abandoned and is
    // neither used nor deinitialized after the copy.
    var moved = original;
    original = undefined;
    try moved.tryGET("/second", testHandler);

    const Params = @TypeOf(@as(httpz.Request, undefined).params);
    var params = try Params.init(moved.allocator, 1);
    defer params.deinit(moved.allocator);
    try std.testing.expect(moved.server._router.route(.GET, "", "/first", &params) != null);
    try std.testing.expect(moved.server._router.route(.GET, "", "/second", &params) != null);
    moved.deinit();
}

test "legacy lowercase get alias registers a route" {
    var app = try App.init(std.testing.allocator, .{});
    defer app.deinit();
    try app.get("/legacy", testHandler);

    const Params = @TypeOf(@as(httpz.Request, undefined).params);
    var params = try Params.init(app.allocator, 1);
    defer params.deinit(app.allocator);
    try std.testing.expect(app.server._router.route(.GET, "", "/legacy", &params) != null);
}

test "tryGroup returns prefix allocation failure" {
    var saw_group_failure = false;
    for (0..40) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const app_value = App.init(failing.allocator(), .{}) catch continue;
        var app = app_value;
        if (app.tryGroup("/prefix")) |group| {
            _ = group;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_group_failure = true;
        }
        app.deinit();
        if (saw_group_failure) break;
    }
    try std.testing.expect(saw_group_failure);
}

test "global middleware registration after routes is rejected" {
    var app = try App.init(std.testing.allocator, .{});
    defer app.deinit();
    try app.tryGET("/", testHandler);
    try std.testing.expectError(error.MiddlewareAfterRoutes, app.tryUse(testMiddlewareA));
    try std.testing.expectEqual(@as(usize, 0), app.server._middlewares.len);
    try std.testing.expectEqual(@as(usize, 0), app.server._router.middlewares.len);
}

test "live HTTP requests exercise routes middleware and shutdown" {
    var app = try App.init(std.testing.allocator, .{
        .address = .localhost(0),
    });
    defer app.deinit();

    try app.tryUse(liveGlobalMiddleware);
    var api = try app.tryGroup("/api/v1");
    try api.tryUse(liveGroupMiddleware);
    const audit = try app.createMiddleware(liveRouteMiddleware);
    try app.tryGET("/", liveHome);
    try api.tryGETWithMiddleware("/items/:id", liveGetItem, &.{audit});
    try api.tryPOST("/items", liveCreateItem);

    const listener_thread = try app.server.listenInNewThread();
    var thread_running = true;
    defer if (thread_running) {
        app.stop();
        listener_thread.join();
    };

    const listener = app.server._listener orelse return error.ListenerFailedToStart;
    var address: std.net.Address = undefined;
    var address_len: std.posix.socklen_t = @sizeOf(std.net.Address);
    try std.posix.getsockname(listener, &address.any, &address_len);
    const port = address.getPort();

    const root = try liveHttpGet(std.testing.allocator, port, "/");
    defer std.testing.allocator.free(root);
    try expectHttpResponse(root, 200, "ZigNexa is running");
    try std.testing.expect(std.mem.indexOf(u8, root, "X-Middleware-Step: G") != null);

    const details = try liveHttpGet(std.testing.allocator, port, "/api/v1/items/42?view=details");
    defer std.testing.allocator.free(details);
    try expectHttpStatus(details, 200);
    try std.testing.expect(std.mem.indexOf(u8, details, "\"id\":\"42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, details, "\"view\":\"details\"") != null);
    try expectOrderedMiddlewareHeaders(details, "GTRH");
    try std.testing.expect(std.mem.indexOf(u8, details, "X-API-Version: v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, details, "X-Route-Audit: yes") != null);

    const summary = try liveHttpGet(std.testing.allocator, port, "/api/v1/items/42");
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"view\":\"summary\"") != null);
    try expectOrderedMiddlewareHeaders(summary, "GTRH");

    const created = try liveHttpRequest(std.testing.allocator, port, "POST", "/api/v1/items");
    defer std.testing.allocator.free(created);
    try expectHttpStatus(created, 201);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"created\":true") != null);

    const missing = try liveHttpGet(std.testing.allocator, port, "/does-not-exist");
    defer std.testing.allocator.free(missing);
    try expectHttpStatus(missing, 404);
    try std.testing.expect(std.mem.indexOf(u8, missing, "X-Middleware-Step: G") != null);

    app.stop();
    listener_thread.join();
    thread_running = false;
    try expectListenerCanBind(port);
}

fn liveHttpGet(allocator: std.mem.Allocator, port: u16, path: []const u8) ![]u8 {
    return liveHttpRequest(allocator, port, "GET", path);
}

fn liveHttpRequest(allocator: std.mem.Allocator, port: u16, method: []const u8, path: []const u8) ![]u8 {
    var stream = try std.net.tcpConnectToAddress(.initIp4(.{ 127, 0, 0, 1 }, port));
    defer stream.close();

    const request = try std.fmt.allocPrint(allocator, "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", .{ method, path });
    defer allocator.free(request);
    try stream.writeAll(request);

    var response: [4096]u8 = undefined;
    var response_len: usize = 0;
    var timer = try std.time.Timer.start();
    while (true) {
        if (timer.read() > 5 * std.time.ns_per_s) return error.HttpResponseTimeout;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&poll_fds, 250);
        if (ready == 0) continue;
        if (response_len == response.len) return error.HttpResponseTooLarge;
        const count = try stream.read(response[response_len..]);
        if (count == 0) break;
        response_len += count;
    }
    return try allocator.dupe(u8, response[0..response_len]);
}

fn expectHttpStatus(response: []const u8, status: u16) !void {
    var status_line: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&status_line, "HTTP/1.1 {d}", .{status});
    try std.testing.expect(std.mem.startsWith(u8, response, expected));
}

fn expectHttpResponse(response: []const u8, status: u16, body: []const u8) !void {
    try expectHttpStatus(response, status);
    const separator = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.InvalidHttpResponse;
    try std.testing.expectEqualStrings(body, response[separator + 4 ..]);
}

fn expectOrderedMiddlewareHeaders(response: []const u8, order: []const u8) !void {
    var position: usize = 0;
    for (order) |step| {
        const expected = [_]u8{ 'X', '-', 'M', 'i', 'd', 'd', 'l', 'e', 'w', 'a', 'r', 'e', '-', 'S', 't', 'e', 'p', ':', ' ', step };
        const found = std.mem.indexOfPos(u8, response, position, &expected) orelse return error.MiddlewareOrderMismatch;
        position = found + expected.len;
    }
}

fn expectListenerCanBind(port: u16) !void {
    var rebound = try std.net.Address.listen(.initIp4(.{ 127, 0, 0, 1 }, port), .{});
    defer rebound.deinit();
}

fn liveGlobalMiddleware(context: *Context) !void {
    context.Header("X-Middleware-Step", "G");
    try context.Next();
}

fn liveGroupMiddleware(context: *Context) !void {
    context.Header("X-Middleware-Step", "T");
    context.Header("X-API-Version", "v1");
    try context.Next();
}

fn liveRouteMiddleware(context: *Context) !void {
    context.Header("X-Middleware-Step", "R");
    context.Header("X-Route-Audit", "yes");
    try context.Next();
}

fn liveHome(context: *Context) !void {
    try context.String(200, "ZigNexa is running");
}

fn liveGetItem(context: *Context) !void {
    context.Header("X-Middleware-Step", "H");
    const id = context.Param("id");
    const view = (try context.Query("view")) orelse "summary";
    try context.JSON(200, .{ .id = id, .view = view });
}

fn liveCreateItem(context: *Context) !void {
    try context.JSON(201, .{ .id = 1, .created = true });
}

fn testMiddlewareA(context: *Context) !void {
    try context.Next();
}

fn testMiddlewareB(context: *Context) !void {
    try context.Next();
}

fn testMiddlewareC(context: *Context) !void {
    try context.Next();
}

fn testHandler(_: *Context) !void {}

const MiddlewareTrace = struct {
    bytes: [4]u8 = undefined,
    len: usize = 0,

    fn append(self: *MiddlewareTrace, byte: u8) !void {
        if (self.len == self.bytes.len) return error.TraceFull;
        self.bytes[self.len] = byte;
        self.len += 1;
    }

    fn slice(self: *const MiddlewareTrace) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn recordTrace(context: *Context, byte: u8) !void {
    const opaque_trace = context.request.middlewares.get("zignexa-test-trace") orelse return error.TraceUnavailable;
    const trace: *MiddlewareTrace = @ptrCast(@alignCast(opaque_trace));
    try trace.append(byte);
    try context.Next();
}

fn traceGlobal(context: *Context) !void {
    try recordTrace(context, 'G');
}

fn traceGroup(context: *Context) !void {
    try recordTrace(context, 'T');
}

fn traceRoute(context: *Context) !void {
    try recordTrace(context, 'R');
}

fn traceExampleHandler(context: *Context) !void {
    const id = context.Param("id");
    const view = (try context.Query("view")) orelse "summary";
    const opaque_trace = context.request.middlewares.get("zignexa-test-trace") orelse return error.TraceUnavailable;
    const trace: *MiddlewareTrace = @ptrCast(@alignCast(opaque_trace));
    try trace.append('H');
    try context.JSON(200, .{ .id = id, .view = view });
}

fn testShortCircuit(context: *Context) !void {
    try context.String(401, "stopped");
}
