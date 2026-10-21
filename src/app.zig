//! Application setup and route registration.
const std = @import("std");
const httpz = @import("httpz");
const Context = @import("context.zig").Context;
const handler = @import("handler.zig");

/// Type-erased httpz middleware handle owned by the creating app's server.
pub const Middleware = httpz.Middleware(void);
const MiddlewareList = std.ArrayListUnmanaged(Middleware);
const Router = httpz.Router(void, httpz.Action(void));

/// Owns the httpz server, middleware registrations, and framework arena.
/// Register routes and middleware before calling `Run` or `listen`.
pub const App = struct {
    server: httpz.Server(void),
    arena: *std.heap.ArenaAllocator,
    parent_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    global_middleware: MiddlewareList = .empty,

    const Self = @This();

    /// Construct an app using the page allocator and the default local address.
    /// Use `init` when the application owns a different allocator.
    pub fn Default() Self {
        return Self.init(std.heap.page_allocator, .{ .address = .localhost(8080) }) catch @panic("failed to initialize ZigNexa");
    }

    /// Initialize server and framework-owned storage from `allocator`.
    pub fn init(allocator: std.mem.Allocator, config: httpz.Config) !Self {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        const server = try httpz.Server(void).init(arena.allocator(), config, {});
        return .{
            .server = server,
            .arena = arena,
            .parent_allocator = allocator,
            .allocator = arena.allocator(),
        };
    }

    /// Register a ZigNexa Context handler with fallible route allocation.
    pub fn get(self: *Self, path: []const u8, comptime callback: anytype) !void {
        try self.tryGET(path, callback);
    }

    /// Register a GET route using a ZigNexa Context handler.
    pub fn GET(self: *Self, path: []const u8, comptime callback: anytype) void {
        self.tryGET(path, callback) catch @panic("failed to register GET route");
    }

    /// Fallible form of `GET` for applications that avoid registration panics.
    pub fn tryGET(self: *Self, path: []const u8, comptime callback: anytype) !void {
        try self.registerGrouped(.GET, path, handler.adapt(callback), &.{}, &.{});
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
        const middleware = try self.server.middleware(handler.middlewareAdapter(callback), {});
        try self.global_middleware.append(self.allocator, middleware);
        _ = try self.currentRouter();
    }

    /// Create a reusable httpz middleware value for route-specific composition.
    /// The server owns its implementation and releases it during deinit.
    pub fn createMiddleware(self: *Self, comptime callback: anytype) !Middleware {
        return self.server.middleware(handler.middlewareAdapter(callback), {});
    }

    /// Start on localhost:`port`, then release app resources when serving ends.
    pub fn Run(self: *Self, port: u16) !void {
        self.server.config.address = .localhost(port);
        defer self.deinit();
        defer self.server.stop();
        try self.server.listen();
    }

    /// Block serving with the address configured at initialization.
    pub fn listen(self: *Self) !void {
        try self.server.listen();
    }

    /// Stop accepting requests. Call before `deinit` when another thread is listening.
    pub fn stop(self: *Self) void {
        self.server.stop();
    }

    /// Release httpz resources and the framework arena. Do not use the app afterwards.
    pub fn deinit(self: *Self) void {
        self.server.deinit();
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
    }

    /// Create a route group. Prefix and middleware storage live in the app arena.
    pub fn Group(self: *Self, prefix: []const u8) @import("route_group.zig").RouteGroup {
        return .{
            .app = self,
            .prefix = self.allocator.dupe(u8, prefix) catch @panic("failed to allocate route prefix"),
        };
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
        const router = try self.currentRouter();
        const local_count = group_middleware.len + route_middleware.len;
        const local = try self.allocator.alloc(Middleware, local_count);
        @memcpy(local[0..group_middleware.len], group_middleware);
        @memcpy(local[group_middleware.len..], route_middleware);
        switch (method) {
            .GET => try router.tryGet(path, callback, .{ .middlewares = local }),
            .POST => try router.tryPost(path, callback, .{ .middlewares = local }),
            .PUT => try router.tryPut(path, callback, .{ .middlewares = local }),
            .PATCH => try router.tryPatch(path, callback, .{ .middlewares = local }),
            .DELETE => try router.tryDelete(path, callback, .{ .middlewares = local }),
            .HEAD => try router.tryHead(path, callback, .{ .middlewares = local }),
            .OPTIONS => try router.tryOptions(path, callback, .{ .middlewares = local }),
            else => return error.UnsupportedMethod,
        }
    }

    fn currentRouter(self: *Self) !*Router {
        return self.server.router(.{ .middlewares = self.global_middleware.items });
    }
};

test "global, group, and route middleware preserve append order" {
    var app = try App.init(std.testing.allocator, .{});
    defer app.deinit();

    try app.tryUse(testMiddlewareA);
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
        .middlewares = app.server._middlewares,
        .dispatchable_action = null,
    };
    try executor.next();
    try std.testing.expectEqual(@as(u16, 401), testing.res.status);
    try std.testing.expectEqualStrings("stopped", testing.res.body);
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

fn testShortCircuit(context: *Context) !void {
    try context.String(401, "stopped");
}
