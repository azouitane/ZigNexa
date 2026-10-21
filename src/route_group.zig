//! Prefix-scoped routes and middleware.
const std = @import("std");
const httpz = @import("httpz");
const App = @import("app.zig").App;
const Middleware = @import("app.zig").Middleware;
const handler = @import("handler.zig");

/// Route registrations under a shared path prefix.
/// Group middleware runs after app middleware and before route middleware.
pub const RouteGroup = struct {
    app: *App,
    prefix: []const u8,
    middleware: std.ArrayListUnmanaged(Middleware) = .empty,

    /// Register group middleware in append order.
    pub fn Use(self: *RouteGroup, comptime callback: anytype) void {
        self.tryUse(callback) catch @panic("failed to register group middleware");
    }

    /// Fallible form of `Use`.
    pub fn tryUse(self: *RouteGroup, comptime callback: anytype) !void {
        const middleware = try self.app.createMiddleware(callback);
        try self.middleware.append(self.app.allocator, middleware);
    }

    /// Register a GET handler beneath the group's prefix.
    pub fn GET(self: *RouteGroup, path: []const u8, comptime callback: anytype) void {
        self.tryGET(path, callback) catch @panic("failed to register grouped GET route");
    }

    /// Fallible grouped GET registration.
    pub fn tryGET(self: *RouteGroup, path: []const u8, comptime callback: anytype) !void {
        try self.tryVerb(.GET, path, callback);
    }

    /// Register a POST route beneath this group.
    pub fn POST(self: *RouteGroup, path: []const u8, comptime callback: anytype) void {
        self.tryPOST(path, callback) catch @panic("failed to register grouped POST route");
    }

    /// Fallible grouped POST registration.
    pub fn tryPOST(self: *RouteGroup, path: []const u8, comptime callback: anytype) !void {
        try self.tryVerb(.POST, path, callback);
    }

    /// Register a PUT route beneath this group.
    pub fn PUT(self: *RouteGroup, path: []const u8, comptime callback: anytype) void {
        self.tryPUT(path, callback) catch @panic("failed to register grouped PUT route");
    }

    /// Fallible grouped PUT registration.
    pub fn tryPUT(self: *RouteGroup, path: []const u8, comptime callback: anytype) !void {
        try self.tryVerb(.PUT, path, callback);
    }

    /// Register a PATCH route beneath this group.
    pub fn PATCH(self: *RouteGroup, path: []const u8, comptime callback: anytype) void {
        self.tryPATCH(path, callback) catch @panic("failed to register grouped PATCH route");
    }

    /// Fallible grouped PATCH registration.
    pub fn tryPATCH(self: *RouteGroup, path: []const u8, comptime callback: anytype) !void {
        try self.tryVerb(.PATCH, path, callback);
    }

    /// Register a DELETE route beneath this group.
    pub fn DELETE(self: *RouteGroup, path: []const u8, comptime callback: anytype) void {
        self.tryDELETE(path, callback) catch @panic("failed to register grouped DELETE route");
    }

    /// Fallible grouped DELETE registration.
    pub fn tryDELETE(self: *RouteGroup, path: []const u8, comptime callback: anytype) !void {
        try self.tryVerb(.DELETE, path, callback);
    }

    /// Register a HEAD route beneath this group.
    pub fn HEAD(self: *RouteGroup, path: []const u8, comptime callback: anytype) void {
        self.tryHEAD(path, callback) catch @panic("failed to register grouped HEAD route");
    }

    /// Fallible grouped HEAD registration.
    pub fn tryHEAD(self: *RouteGroup, path: []const u8, comptime callback: anytype) !void {
        try self.tryVerb(.HEAD, path, callback);
    }

    /// Register an OPTIONS route beneath this group.
    pub fn OPTIONS(self: *RouteGroup, path: []const u8, comptime callback: anytype) void {
        self.tryOPTIONS(path, callback) catch @panic("failed to register grouped OPTIONS route");
    }

    /// Fallible grouped OPTIONS registration.
    pub fn tryOPTIONS(self: *RouteGroup, path: []const u8, comptime callback: anytype) !void {
        try self.tryVerb(.OPTIONS, path, callback);
    }

    /// Fallible GET registration with route-local middleware handles.
    pub fn tryGETWithMiddleware(
        self: *RouteGroup,
        path: []const u8,
        comptime callback: anytype,
        route_middleware: []const Middleware,
    ) !void {
        const route_path = try self.joinPath(path);
        try self.app.registerGrouped(.GET, route_path, handler.adapt(callback), self.middleware.items, route_middleware);
    }

    /// Register a route with additional route-local middleware.
    pub fn GETWithMiddleware(
        self: *RouteGroup,
        path: []const u8,
        comptime callback: anytype,
        route_middleware: []const Middleware,
    ) void {
        const route_path = self.joinPath(path) catch @panic("failed to allocate grouped route path");
        self.app.registerGrouped(.GET, route_path, handler.adapt(callback), self.middleware.items, route_middleware) catch @panic("failed to register grouped GET route");
    }

    /// Register a supported method beneath this group with route middleware.
    pub fn Handle(
        self: *RouteGroup,
        method: httpz.Method,
        path: []const u8,
        comptime callback: anytype,
        route_middleware: []const Middleware,
    ) !void {
        const route_path = try self.joinPath(path);
        try self.app.registerGrouped(method, route_path, handler.adapt(callback), self.middleware.items, route_middleware);
    }

    fn tryVerb(self: *RouteGroup, method: httpz.Method, path: []const u8, comptime callback: anytype) !void {
        const route_path = try self.joinPath(path);
        try self.app.registerGrouped(method, route_path, handler.adapt(callback), self.middleware.items, &.{});
    }

    fn joinPath(self: *RouteGroup, path: []const u8) ![]const u8 {
        if (self.prefix.len == 0) return self.app.allocator.dupe(u8, path);
        if (path.len == 0) return self.app.allocator.dupe(u8, self.prefix);
        const trim_prefix_slash = self.prefix[self.prefix.len - 1] == '/' and path[0] == '/';
        const trim_path_slash = self.prefix[self.prefix.len - 1] != '/' and path[0] != '/';
        const left = if (trim_prefix_slash) self.prefix[0 .. self.prefix.len - 1] else self.prefix;
        const separator: []const u8 = if (trim_path_slash) "/" else "";
        return std.fmt.allocPrint(self.app.allocator, "{s}{s}{s}", .{ left, separator, path });
    }
};
