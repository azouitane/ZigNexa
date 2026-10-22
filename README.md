# ZigNexa

ZigNexa is a small HTTP framework for Zig 0.15.2, built on [httpz](https://github.com/karlseguin/http.zig). It provides a `Context` handler API, route groups, and ordered middleware while relying on httpz for sockets, routing, and request processing.

## Status and requirements

ZigNexa is an early `v0.1.x` project. It requires Zig 0.15.2. The implemented API includes GET, POST, PUT, PATCH, DELETE, HEAD, and OPTIONS routes; path parameters; query and request-header access; text and JSON responses; middleware; and route groups.

The framework currently does not distinguish HTTP 405 from 404, provide TLS, async handlers, per-request cancellation, or custom not-found handlers. Unmatched routes and unsupported methods receive httpz's 404 response.

## Installation

Add the tagged package revision to a Zig 0.15.2 project:

```sh
zig fetch --save "git+https://github.com/azouitane/ZigNexa#v0.1.1"
```

Import the dependency in `build.zig` (after creating the executable):

```zig
const zignexa = b.dependency("zignexa", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zignexa", zignexa.module("zignexa"));
```

The package exports the module name `zignexa` and wires its httpz dependency into that module. ZigNexa vendors the exact pinned upstream httpz revision in `vendor/httpz` and carries local listener lifecycle fixes there, so downstream users get the maintained source with the package.

## Basic server

[`examples/basic.zig`](examples/basic.zig) is the main usage example. It initializes the app with an explicit allocator, registers middleware and routes, then blocks in `listen()`:

```zig
const std = @import("std");
const zignexa = @import("zignexa");

pub fn main() !void {
    var app = try zignexa.App.init(std.heap.page_allocator, .{
        .address = .localhost(8080),
    });
    defer app.deinit();

    try app.tryUse(zignexa.middleware.Logger);
    try app.tryGET("/", home);
    try app.listen();
}

fn home(c: *zignexa.Context) !void {
    try c.String(200, "Hello from ZigNexa");
}
```

Build and run the example from the repository root:

```sh
zig build example
zig build run-example
```

`zig build run` is an alias for `zig build run-example`. The server listens at
`http://localhost:8080`. `listen()` blocks. An embedding program can call
`app.stop()`, wait for `listen()` and all serving threads to finish, then call
`app.deinit()`. The basic executable intentionally leaves signal handling to
the host program.

## Routes and context

Each method has a capitalized convenience form that panics on registration failure and a fallible `try` form. Prefer the fallible forms when initialization errors should be returned:

This handler example is illustrative; put the route registrations inside your
application setup function after initializing `app`.

```zig
try app.tryGET("/items/:id", getItem);
try app.tryPOST("/items", createItem);

fn getItem(c: *zignexa.Context) !void {
    const id = c.Param("id");
    const page = (try c.Query("page")) orelse "1";
    const agent = c.RequestHeader("user-agent") orelse "unknown";
    c.Header("Cache-Control", "no-store");
    try c.JSON(200, .{ .id = id, .page = page, .agent = agent });
}

fn createItem(c: *zignexa.Context) !void {
    try c.String(201, "created");
}
```

The supported methods are GET, POST, PUT, PATCH, DELETE, HEAD, and OPTIONS (`tryGET`, `tryPOST`, etc., with matching capitalized convenience methods). The former fallible lowercase `get(path, handler)` remains as a compatibility alias for `tryGET`; other lowercase verb aliases are not provided. `Param` returns an empty slice when a parameter is absent. `Query` returns an optional request-lifetime slice and can return an error. Request-header lookup follows httpz's lowercase-name convention. `Header` adds a response header; `String` sets a text response; `JSON` serializes a Zig value.

## Middleware

Middleware has the signature `fn (*Context) !void`. Call `try c.Next()` to continue. Returning without calling `Next()` short-circuits the chain. The order is global middleware, group middleware, route middleware, then the handler. Register global middleware before adding routes.

This middleware example is illustrative: `app`, `api`, and the named callback
functions refer to values declared by the containing application.

```zig
try app.tryUse(zignexa.middleware.Logger);

var api = try app.tryGroup("/api/v1");
try api.tryUse(apiHeader);

const audit = try app.createMiddleware(auditRequest);
try api.tryGETWithMiddleware("/items/:id", getItem, &.{audit});
```

`RouteGroup` supports group middleware and `tryGETWithMiddleware`/`GETWithMiddleware` for GET-specific middleware. `Handle` accepts any supported method with route middleware. Middleware values created by `createMiddleware` are owned and released by the app's httpz server.

Built-in middleware exports are `Logger`, `Recovery`, `RequestID`, and `cors(config)`. `Recovery` handles returned errors, not panics. `RequestID` generates or validates a correlation ID; it is not authentication. CORS is not access control.

Without `Recovery`, an unhandled executor or handler error reaches httpz's
request error-handling path. httpz logs the error and writes a generic HTTP 500
response with the body `Internal Server Error`; it does not return the original
error to the client. `Recovery` catches a returned downstream error and writes
its own generic 500 response. These paths do not catch panics. Unmatched routes
and unsupported methods use httpz's 404 behavior.

## Memory Management

ZigNexa is built on httpz and does not replace its internal allocation mechanisms. The allocator passed to `App.init(allocator, config)` is passed to httpz for its server and individually managed resources. Keep that allocator alive until `app.deinit()` has completed; use an allocator that supports individual freeing, such as `std.heap.page_allocator` or a general-purpose allocator.

ZigNexa stores framework registration data, including owned route paths, group prefixes, and route middleware lists, in the public startup arena allocator exposed by the httpz server. The httpz server owns this arena, the router, and middleware implementations. `App.deinit()` calls `httpz.Server.deinit()`, which deinitializes middleware and then releases the arena containing router and ZigNexa route metadata. This avoids a redundant second arena. The allocator passed to httpz must support individually freed worker and connection resources; the server arena is reserved for startup-lifetime data. Route groups are lightweight values referencing their app; do not use a group after its app has been deinitialized.

Initialize the app, register middleware and routes, call `listen()` or `Run(port)`, stop serving, wait until the listener and all serving threads have finished, and then call `deinit()` exactly once. `Run(port)` listens on localhost at the supplied port; it does not deinitialize the app. The caller must call `app.deinit()` after serving stops and all serving threads finish. `stop()` is intended to be called once while the server is serving; the caller must ensure no listener thread or handler can still access the app before deinitializing it. The app may be moved between setup calls because ZigNexa does not retain the pointer returned by `httpz.Server.router()`. Treat a move as an ownership transfer: after copying to the new location, never use or deinitialize the original value; simultaneous copies are not safe. Do not move it while serving or while a `RouteGroup` that stores its address is still in use. Prefer `tryGroup(prefix)` to handle prefix allocation failure; `Group(prefix)` remains a panic-on-allocation-failure compatibility wrapper.

`Context`, its request and response pointers, and values returned by `Param`, `Query`, and `RequestHeader` are request-scoped. They are valid only while handling that request. Copy values into application-owned storage before retaining them after the handler returns. `String` and `Header` use borrowed slices which must stay valid until httpz writes the response; literals and request data are safe for that duration. Use `StringCopy` or `HeaderCopy` when those inputs otherwise come from short-lived storage. `JSON` writes serialized data into httpz's response buffer, which httpz retains through response writing.

An arena suits data with one clear lifetime, such as route metadata or temporary request work. It is not suitable for high-churn resources that must be individually freed. httpz manages request and response storage and ZigNexa's handler adapters add no per-request allocation. An arena is an allocator strategy, not a hard operating-system RAM limit; use process or container resource controls for a hard cap.

Run the tests with:

```sh
zig build test
```

Tests use `std.testing.allocator` to catch leaks in app and request-scoped helpers. When diagnosing allocations, run the test command without suppressing allocator diagnostics and reduce the failing behavior to a focused test.

## Project structure

```text
src/app.zig          Application lifecycle and route registration
src/context.zig      Request-scoped context and response helpers
src/handler.zig      httpz callback adapters
src/middleware.zig   Built-in middleware
src/route_group.zig  Prefix-scoped routing
examples/basic.zig   Main runnable example
```

## Development

Format and build with Zig 0.15.2:

```sh
zig fmt build.zig src/ examples/
zig build
zig build test
zig build example
```

The example uses the `page_allocator` and serves on port 8080. Change the configured address in `examples/basic.zig` if that port is already in use.

## License

ZigNexa is distributed under the MIT License. See [LICENSE](LICENSE).

## Security notes

Validate untrusted path, query, and body values before using them. Restrict CORS
origins to the clients that need access; CORS does not authorize requests.
Request IDs are correlation values, not trusted identity. This framework does
not provide TLS, so production deployments need a trusted TLS boundary.
