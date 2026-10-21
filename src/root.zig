//! Public entry point for the ZigNexa HTTP framework.

/// Application lifecycle, route registration, and middleware setup.
pub const App = @import("app.zig").App;
/// The httpz dependency, exposed for advanced server configuration.
pub const httpz = @import("httpz");
/// Request-scoped handler context and response helpers.
pub const Context = @import("context.zig").Context;
/// Built-in Logger, Recovery, RequestID, and CORS middleware.
pub const middleware = @import("middleware.zig");
/// Type-erased middleware handle for route-local middleware registration.
pub const Middleware = App.Middleware;

/// Create an application using the page allocator and localhost defaults.
pub fn Default() App {
    return App.Default();
}
