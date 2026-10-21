//! Public entry point for the ZigNexa HTTP framework.

pub const App = @import("app.zig").App;
pub const httpz = @import("httpz");
pub const Context = @import("context.zig").Context;
pub const middleware = @import("middleware.zig");
pub const Middleware = App.Middleware;

/// Create an application using the page allocator and localhost defaults.
pub fn Default() App {
    return App.Default();
}
