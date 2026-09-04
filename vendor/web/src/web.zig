//! Umbrella module: one dependency edge for consumers.
//!
//! Each namespace below IS the standalone module of the same name, so code
//! importing `web_html` directly and code importing `web.html` see identical
//! types during migration.

pub const html = @import("web_html");
pub const request = @import("web_request");
pub const response = @import("web_response");
pub const router = @import("web_router");
pub const assets = @import("web_assets");
pub const cache = @import("web_cache");
pub const security_headers = @import("web_security_headers");
pub const server = @import("web_server");
pub const htmx = @import("web_htmx");
pub const testing = @import("web_testing");
pub const digest = @import("web_digest");
pub const app = @import("web_app");

test {
    _ = html;
    _ = request;
    _ = response;
    _ = router;
    _ = assets;
    _ = cache;
    _ = security_headers;
    _ = server;
    _ = htmx;
    _ = testing;
    _ = digest;
    _ = app;
}
