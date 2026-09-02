/// XML sitemap generation.
///
/// Only hub pages are listed: the front page, the section and listing pages,
/// and one entry per Windows header and module. The ~75,000 symbolic-name and
/// code pages are left out on purpose. Every one of them is reachable within
/// three clicks of the front page, so a sitemap buys no discovery there, and
/// submitting them would bury the pages that do deserve indexing under far more
/// URLs than a site this size will ever get crawled.
///
/// That keeps the whole thing to one file, well under the 50,000 URL limit that
/// would otherwise force a sitemap index.
module sitemap;

import std.datetime.systime : SysTime;
import core.time : Duration;
import database;
import utils : requestOrigin;
import ddhttpd;

private:

// Pages that are neither a header nor a module. /search is left out, as
// robots.txt disallows it.
static immutable string[] SITEMAP_PAGES = [
    "/",
    "/about",
    "/api",
    "/windows/",
    "/windows/error-types",
    "/windows/modules",
    "/windows/headers",
    "/crt/",
    "/crt/msvc",
    "/crt/gnu",
    "/crt/musl",
];

// Every listed page renders from the data files, so one scan really does change
// all of them at once. /windows/error-types, being prose, is the odd one out.
__gshared string lastmod;

void putURL(ref HTTPReply buffer, const(char)[] origin, const(char)[] path, const(char)[] leaf = null)
{
    buffer.writef(`<url><loc>%s%s%s</loc>`, origin, path, leaf);
    if (lastmod.length)
        buffer.writef(`<lastmod>%s</lastmod>`, lastmod);
    buffer.put(`</url>`);
}

void putSitemap(ref HTTPReply buffer, const(char)[] origin)
{
    buffer.put(`<?xml version="1.0" encoding="UTF-8"?>`);
    buffer.put(`<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">`);

    foreach (string path; SITEMAP_PAGES)
        putURL(buffer, origin, path);
    foreach (ref WindowsHeader header; databaseWindowsHeaders())
        putURL(buffer, origin, "/windows/header/", header.key);
    foreach (ref WindowsModule mod; databaseWindowsModules())
        putURL(buffer, origin, "/windows/module/", mod.name);

    buffer.put(`</urlset>`);
}

// W3C datetime, which the protocol wants, at second resolution
string sitemapLastmod()
{
    SysTime stamp = databaseTimestamp();
    if (stamp == SysTime.init)
        return null;

    stamp = stamp.toUTC();
    stamp.fracSecs = Duration.zero;
    return stamp.toISOExtString();
}

public:

/// Add the sitemap route. Must run after the database is loaded.
HTTPServer addSitemapRoutes(HTTPServer http)
{
    lastmod = sitemapLastmod();

    // Rendered per request rather than cached: the absolute origin it embeds
    // comes from the request while --base-url is unset.
    size_t estimate = SITEMAP_PAGES.length
        + databaseWindowsHeaders().length
        + databaseWindowsModules().length;

    return http.addRoute("GET", "/sitemap.xml", (ref HTTPRequest req)
    {
        char[300] originbuf = void;
        const(char)[] origin = requestOrigin(req, originbuf);
        if (origin.length == 0)
            throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);

        HTTPReply buffer = HTTPReply.create(1024 + estimate * 128);
        putSitemap(buffer, origin);

        req.reply(200, buffer, "application/xml");
        return REQUEST_OK;
    });
}
