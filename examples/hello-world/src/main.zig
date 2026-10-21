const ZigNexa = @import("zignexa");
const std = @import("std");

const User = struct {
    ID: u32,
    Name: []const u8,
    Age: u8,
};

pub fn main() !void {
    var app = ZigNexa.Default();
    app.Use(ZigNexa.middleware.Logger);
    app.Use(ZigNexa.middleware.Recovery);
    app.Use(ZigNexa.middleware.RequestID);

    app.GET("/", home);
    app.GET("/users", getusers);
    app.GET("/users/:id", getUser);

    var api = app.Group("/api/v1");
    api.GET("/health", health);

    std.log.info("Server is running : http://localhost:8080", .{});
    try app.Run(8080);
}

fn home(c: *ZigNexa.Context) !void {
    try c.String(200, "Hello from ZigNexa!");
}

fn getUser(c: *ZigNexa.Context) !void {
    const id = c.Param("id");
    try c.JSON(200, .{
        .id = id,
        .name = "Ahmed",
    });
}

fn getusers(c: *ZigNexa.Context) !void {
    const users = [_]User{
        .{ .ID = 1, .Name = "Ahmed", .Age = 25 },
        .{ .ID = 2, .Name = "Sara", .Age = 22 },
        .{ .ID = 3, .Name = "Youssef", .Age = 30 },
    };
    try c.JSON(200, .{
        .all = users,
    });
}

fn health(c: *ZigNexa.Context) !void {
    try c.JSON(200, .{
        .status = "ok",
    });
}
