//! Adapt ZigNexa handlers to the callback signatures used by httpz.
const httpz = @import("httpz");
const Context = @import("context.zig").Context;

/// Produce the httpz callback for a compile-time ZigNexa handler.
///
///
pub fn adapt(comptime callback: anytype) httpz.Action(void) {
    return struct {
        fn call(req: *httpz.Request, res: *httpz.Response) anyerror!void {
            var context = Context{ .request = req, .response = res };
            try callback(&context);
        }
    }.call;
}

/// Build a state-free httpz middleware wrapper around a Context callback.
/// Request traversal stays inside httpz.Executor, avoiding per-request arrays.
pub fn middlewareAdapter(comptime callback: anytype) type {
    return struct {
        pub const Config = void;

        pub fn init(_: Config) !@This() {
            return .{};
        }

        pub fn execute(
            _: *@This(),
            req: *httpz.Request,
            res: *httpz.Response,
            executor: *httpz.Server(void).Executor,
        ) !void {
            var context = Context.withExecutor(req, res, executor);
            try callback(&context);
        }
    };
}
