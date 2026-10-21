const std = @import("std");
const zignexa = @import("zignexa");

const max_users = 128;
const max_name_bytes = 64;

const User = struct {
    id: u32,
    name: [max_name_bytes]u8,
    name_len: u8,

    fn view(self: *const User) UserView {
        return .{ .id = self.id, .name = self.name[0..self.name_len] };
    }
};

const UserView = struct { id: u32, name: []const u8 };
const UserInput = struct { name: []const u8 };

// This fixed-size store avoids ownership and cleanup complexity in a small demo.
// The mutex protects it because httpz may serve requests concurrently.
var store_mutex: std.Thread.Mutex = .{};
var users: [max_users]User = undefined;
var users_len: usize = 0;
var next_id: u32 = 1;

pub fn main() !void {
    var app = try zignexa.App.init(std.heap.page_allocator, .{ .address = .localhost(8080) });
    defer app.deinit();

    try app.tryGET("/users", listUsers);
    try app.tryGET("/users/:id", getUser);
    try app.tryPOST("/users", createUser);
    try app.tryPUT("/users/:id", updateUser);
    try app.tryDELETE("/users/:id", deleteUser);

    std.log.info("CRUD demo listening at http://localhost:8080", .{});
    try app.listen();
}

fn listUsers(c: *zignexa.Context) !void {
    store_mutex.lock();
    defer store_mutex.unlock();

    var result: [max_users]UserView = undefined;
    for (users[0..users_len], 0..) |*user, index| result[index] = user.view();
    try c.JSON(200, .{ .users = result[0..users_len] });
}

fn getUser(c: *zignexa.Context) !void {
    const id = (try parseId(c)) orelse return;
    store_mutex.lock();
    defer store_mutex.unlock();
    const user = findUser(id) orelse {
        try notFound(c);
        return;
    };
    try c.JSON(200, user.view());
}

fn createUser(c: *zignexa.Context) !void {
    const input = try parseInput(c) orelse return;
    store_mutex.lock();
    defer store_mutex.unlock();
    if (users_len == max_users) return jsonError(c, 507, "user collection is full");
    if (next_id == 0) return jsonError(c, 507, "user ID space is exhausted");

    const user = makeUser(next_id, input.name);
    next_id = if (next_id == std.math.maxInt(u32)) 0 else next_id + 1;
    users[users_len] = user;
    users_len += 1;
    try c.JSON(201, user.view());
}

fn updateUser(c: *zignexa.Context) !void {
    const id = (try parseId(c)) orelse return;
    const input = try parseInput(c) orelse return;
    store_mutex.lock();
    defer store_mutex.unlock();
    const user = findUser(id) orelse {
        try notFound(c);
        return;
    };
    user.* = makeUser(id, input.name);
    try c.JSON(200, user.view());
}

fn deleteUser(c: *zignexa.Context) !void {
    const id = (try parseId(c)) orelse return;
    store_mutex.lock();
    defer store_mutex.unlock();
    const index = findUserIndex(id) orelse {
        try notFound(c);
        return;
    };
    const deleted = users[index].view();
    users_len -= 1;
    if (index != users_len) users[index] = users[users_len];
    try c.JSON(200, .{ .deleted = deleted });
}

fn parseId(c: *zignexa.Context) !?u32 {
    const raw = c.Param("id");
    const id = std.fmt.parseInt(u32, raw, 10) catch {
        try jsonError(c, 400, "id must be a positive integer");
        return null;
    };
    if (id == 0) {
        try jsonError(c, 400, "id must be a positive integer");
        return null;
    }
    return id;
}

fn parseInput(c: *zignexa.Context) !?UserInput {
    const input = (c.request.json(UserInput) catch {
        try jsonError(c, 400, "request body must be valid JSON with a name");
        return null;
    }) orelse {
        try jsonError(c, 400, "request body must be valid JSON with a name");
        return null;
    };
    if (input.name.len == 0 or input.name.len > max_name_bytes or std.mem.trim(u8, input.name, " \t\r\n").len == 0) {
        try jsonError(c, 400, "name must contain 1 to 64 non-whitespace bytes");
        return null;
    }
    return input;
}

fn makeUser(id: u32, name: []const u8) User {
    var user: User = .{ .id = id, .name = undefined, .name_len = @intCast(name.len) };
    @memcpy(user.name[0..name.len], name);
    return user;
}

fn findUser(id: u32) ?*User {
    const index = findUserIndex(id) orelse return null;
    return &users[index];
}

fn findUserIndex(id: u32) ?usize {
    for (users[0..users_len], 0..) |user, index| {
        if (user.id == id) return index;
    }
    return null;
}

fn notFound(c: *zignexa.Context) !void {
    try jsonError(c, 404, "user not found");
}

fn jsonError(c: *zignexa.Context, status: u16, message: []const u8) !void {
    try c.JSON(status, .{ .@"error" = message });
}
