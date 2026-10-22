const std = @import("std");
const zignexa = @import("zignexa");

// 1. The caller owns this allocator and must keep it alive until app.deinit().
// httpz also uses it for resources that it frees individually.
pub fn main() !void {
    var app = try zignexa.App.init(std.heap.page_allocator, .{
        .address = .localhost(8080),
    });
    defer app.deinit();

    // 2. Middleware runs global → group → route-specific → handler.
    try app.tryUse(zignexa.middleware.Logger);

    // 3. Create a route group.
    var api = try app.tryGroup("/api/v1");

    // 4. Group middleware adds a header to every API response.
    try api.tryUse(apiVersionHeader);

    // 5. Create a server-owned middleware handle for a route.
    const audit = try app.createMiddleware(auditRequest);

    // 6. Register routes.
    try app.tryGET("/", home);
    try api.tryGETWithMiddleware("/items/:id", getItem, &.{audit});
    try api.tryPOST("/items", createItem);

    // 8. listen() blocks and joins its serving threads before it returns. A
    // shutdown controller may call app.stop(); defer then deinitializes app.
    std.log.info("Listening at http://localhost:8080", .{});
    try app.listen();
}

// 7. Handlers receive request-scoped context values.
fn home(c: *zignexa.Context) !void {
    try c.String(200, "ZigNexa is running");
}

fn getItem(c: *zignexa.Context) !void {
    const id = c.Param("id");
    const view = (try c.Query("view")) orelse "summary";
    try c.JSON(200, .{ .id = id, .view = view });
}

fn createItem(c: *zignexa.Context) !void {
    try c.JSON(201, .{ .id = 1, .created = true });
}

fn apiVersionHeader(c: *zignexa.Context) !void {
    c.Header("X-API-Version", "v1");
    try c.Next();
}

fn auditRequest(c: *zignexa.Context) !void {
    std.log.info("auditing {s}", .{c.request.url.path});
    try c.Next();
}
