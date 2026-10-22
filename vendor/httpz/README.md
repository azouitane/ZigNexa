# Vendored httpz

This is the exact `httpz` package revision pinned by the former ZigNexa
dependency entry: upstream commit
`1a4d53b95bc4ac6c84cbc081727428de40c8c635` from
`https://github.com/karlseguin/http.zig` (package hash
`httpz-0.0.0-PNVzrNVOBwDlxyffzwONpI9j9dYqKWXxopU1ZCLt4C09`). The vendored
build file exposes only the library module and focused listener regression
test. Its source contains local startup cleanup changes in `src/httpz.zig` and
`src/worker.zig`; keep those changes here so they are reproducible when Zig
resolves ZigNexa's local dependency.

The upstream `LICENSE`, package metadata, and transitive dependency pins are
preserved.
