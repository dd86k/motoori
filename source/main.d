module hoster.main;

import std.compiler : version_major, version_minor;
import std.format;
import std.stdio;
import std.getopt;
import std.string : toLower, stripRight;
import motoori, database;
import extra.windows;

import ddhttpd;
import core.memory : GC;

static import std.file;
alias readAll = std.file.read;

private:

// Public resources are served from fixed URLs without a cache-busting suffix,
// so the window has to stay short enough for an update to be picked up.
enum const(char) *PUB_CACHE_CONTROL = "public, max-age=3600";

// Origin used to make canonical and og:url absolute. Null means: derive it from
// the request, which is all a local run or a single-host deployment needs.
__gshared string base_url;

/// Serve a pre-cached public resource, under GET and HEAD.
HTTPServer addPubRoute(HTTPServer http, string path, ubyte[] buffer, const(char) *contentType)
{
    int delegate(ref HTTPRequest) handler = (ref HTTPRequest req)
    {
        req.addHeader("Cache-Control", PUB_CACHE_CONTROL);
        req.reply(200, HTTPReply.staticBuffer(buffer), contentType);
        return REQUEST_OK;
    };

    return http
        .addRoute("GET", path, handler)
        .addRoute("HEAD", path, handler);
}

// temporary until moved to database
import std.algorithm.sorting : sort;
struct ErrorModule
{
    const(char)[] name;
    const(char)[] message;
    const(char)[] symbolic;
}

/// Absolute origin for this request, or null when it can't be established.
const(char)[] requestOrigin(ref HTTPRequest req, char[] buffer)
{
    if (base_url.length)
        return base_url;

    string host = req.header("Host");
    if (validHost(host) == false)
        return null;

    // Behind a TLS-terminating proxy the connection itself is plain HTTP, so
    // only the proxy can say what scheme the client actually used.
    string scheme = req.header("X-Forwarded-Proto");
    if (scheme != "https")
        scheme = "http";

    return sformat(buffer, "%s://%s", scheme, host);
}

void prepareHeader(ref HTTPReply buffer, ref HTTPRequest req, string title,
    const(char)[] description, string canonical, ActiveTab tab, string search_query = null)
{
    // NOTE: Could have done a Pug/Diet template converter (by line) but lazy
    buffer.put(`<!DOCTYPE html>`);
    buffer.put(`<html lang="en">`);
    buffer.put(`<head>`);
    buffer.put(`<meta charset="utf-8">`);
    buffer.put(`<meta name="viewport" content="width=device-width, initial-scale=1">`);
    buffer.put(`<meta property="og:site_name" content="OEDB">`);
    buffer.put(`<meta property="og:type" content="website">`);
    buffer.writef(`<meta property="og:title" content="%s">`, title);
    if (description.length)
    {
        buffer.put(`<meta name="description" content="`);
        putSummary(buffer, description);
        buffer.put(`">`);
        buffer.put(`<meta property="og:description" content="`);
        putSummary(buffer, description);
        buffer.put(`">`);
    }
    // Error pages pass no canonical: they have no one URL worth pointing at.
    if (canonical.length)
    {
        char[300] originbuf = void;
        const(char)[] origin = requestOrigin(req, originbuf);
        if (origin.length)
        {
            buffer.writef(`<link rel="canonical" href="%s%s">`, origin, canonical);
            buffer.writef(`<meta property="og:url" content="%s%s">`, origin, canonical);
        }
    }
    buffer.put(`<link rel="stylesheet" href="/chota.min.css">`);
    buffer.put(`<link rel="stylesheet" href="/main.css">`);
    buffer.put(`<link rel="icon" href="/favicon.png">`);
    buffer.put(`<noscript><link rel="stylesheet" href="/noscript.css" /></noscript>`);
    buffer.writef(`<title>%s</title>`, title);
    buffer.put(`</head>`);
    
    buffer.put(`<body>`);
    
    // navigation stuff (class.nav for Chota)
    buffer.put(`<nav class="nav">`);
    buffer.put(`<ul class="nav-left">`); // left nav
    buffer.put(`<li class="brand"><a href="/">OEDB</a></li>`);
    if (tab == ActiveTab.windows)
        buffer.put(`<li class="tabs"><a href="/windows/" class="active">Windows</a></li>`);
    else
        buffer.put(`<li class="tabs"><a href="/windows/">Windows</a></li>`);
    if (tab == ActiveTab.crt)
        buffer.put(`<li class="tabs"><a href="/crt/" class="active">C Runtimes</a></li>`);
    else
        buffer.put(`<li class="tabs"><a href="/crt/">C Runtimes</a></li>`);
    if (tab == ActiveTab.about)
        buffer.put(`<li class="tabs"><a href="/about" class="active">About</a></li>`);
    else
        buffer.put(`<li class="tabs"><a href="/about">About</a></li>`);
    buffer.put(`</ul>`); // left nav
    buffer.put(`<ul class="nav-right">`); // right nav
    buffer.put(`<li>`);
    buffer.put(`<button onclick="toggleThemeMenu()" class="button secondary hidden icon-only i i-sun" id="theme-button"></button>`);
    buffer.put(`<ul class="hidden" id="theme-menu">`); // theme menu
    buffer.put(`<li><button onclick="applyThemeLight()" class="button">Light</button></li>`);
    buffer.put(`<li><button onclick="applyThemeDark()" class="button">Dark</button></li>`);
    buffer.put(`<li><button onclick="applyThemeHighConstrast()" class="button">High contrast</button></li>`);
    buffer.put(`</li>`);
    buffer.put(`</ul>`); // theme menu
    buffer.put(`<li>`);
    buffer.put(`<form action="/search">`); // search
    buffer.put(`<input name="q" id="search-input" placeholder="Search"`);
    if (search_query) buffer.writef(` value="%s"`, search_query);
    buffer.put(` />`);
    buffer.put(`<input type="submit" value=" " class="button icon-only i i-search" style="margin:0;" />`);
    buffer.put(`</form>`); // search
    buffer.put(`</li>`);
    buffer.put(`</ul>`); // right nav
    buffer.put(`</nav>`);
    
    buffer.put(`<p class="warning">This is work in progress.</p>`);
    
    buffer.put(`<div class="content">`);
}
// Row count past which a table stops being scannable by eye.
enum FILTER_MIN_ROWS = 25;

// Filter box for tables too long to scan by eye. Hidden until table.js reveals
// it, since it does nothing without scripting.
void putTableFilter(ref HTTPReply buffer, string table_id, string placeholder)
{
    buffer.writef(`<input type="text" class="table-filter hidden" data-table="%s" placeholder="%s" />`,
        table_id, placeholder);
}
void prepareFooter(ref HTTPReply buffer, bool tablejs = false)
{
    buffer.put(`</div>`); // class="content"
    
    // footer
    buffer.put(`<footer>`);
    buffer.put(`<div>`);
    buffer.put(`<span>Made by <a href="https://github.com/dd86k" target="_blank">dd86k</a></span>`);
    buffer.put(`<span class="right">Written in <a href="https://dlang.org">D (Dlang)</a></span>`);
    buffer.put(`</div>`);
    buffer.put(`<div>`);
    buffer.put(`<span>No rights reserved</span>`);
    buffer.put(`<span class="right">Built: Motoori `~PROJECT_VERSION~` (`~__TIMESTAMP__~`)</span>`);
    buffer.put(`</div>`);
    buffer.put(`</footer>`);
    
    buffer.put(`<script src="/theme.js"></script>`);
    buffer.put(`<script src="/search.js"></script>`);
    if (tablejs)
        buffer.put(`<script src="/table.js"></script>`);
    
    buffer.put(`</body>`);
    buffer.put(`</html>`);
}
// Write the OS releases an entry was found in, as tags
void putWindowsOS(ref HTTPReply buffer, WindowsOSSet os)
{
    foreach (ref WindowsRelease release; databaseWindowsReleases())
    {
        if ((os & release.bit) == 0)
            continue;

        buffer.writef(`<span class="tag is-small" title="%s">%s</span>`, release.name, release.key);
    }
}
// Read a code under both layouts. The bit tables mirror the ones on
// /windows/error-types, so a reader can compare the documented layout with a
// value filled into it.
void putWindowsCodeDecoding(ref HTTPReply buffer, uint code)
{
    buffer.put(`<strong>As HRESULT:</strong>`);
    putHResultDecoding(buffer, code);

    buffer.put(`<strong>As NTSTATUS:</strong>`);
    putNtstatusDecoding(buffer, code);
}
void putHResultDecoding(ref HTTPReply buffer, uint code)
{
    HResultLayout layout = hresultLayout(code);
    WindowsFacility facility = hresultFacilityById(layout.facility);

    buffer.put(`<ul>`);
    buffer.writef(`<li>S: %d (%s)</li>`,
        layout.severity, layout.severity ? "Failure" : "Success");
    if (layout.reserved)
        buffer.writef(`<li>R: 1 (%s)</li>`, layout.ntstatus ?
            "Part of the wrapped NTSTATUS severity, since N is set" :
            "Reserved, must be clear in a well-formed HRESULT");
    buffer.writef(`<li>C: %d (%s)</li>`,
        layout.customer, layout.customer ? "Customer-defined" : "Microsoft-defined");
    buffer.writef(`<li>N: %d (%s)</li>`,
        layout.ntstatus, layout.ntstatus ? "Wraps an NTSTATUS value" : "Not an NTSTATUS value");
    if (layout.reservedX)
        buffer.put(`<li>X: 1 (Reserved, only expected on the TRK exceptions)</li>`);
    putFacilityItem(buffer, layout.facility, facility);
    buffer.writef(`<li>Code: 0x%04x (%d)</li>`, layout.code, layout.code);
    buffer.put(`</ul>`);
}
void putFacilityItem(ref HTTPReply buffer, ushort id, ref WindowsFacility facility)
{
    buffer.writef(`<li>Facility: 0x%03x (`, id);
    if (facility.name)
        buffer.writef(`%s: %s`, facility.name, facility.description);
    else if (id == 0) // NTSTATUS has no name for it, unlike FACILITY_NULL
        buffer.put(`Default`);
    else
        buffer.put(`Unknown facility`);
    buffer.put(`)</li>`);
}
void putNtstatusDecoding(ref HTTPReply buffer, uint code)
{
    NtstatusLayout layout = ntstatusLayout(code);
    WindowsFacility facility = ntstatusFacilityById(layout.facility);

    buffer.put(`<ul>`);
    buffer.writef(`<li>Sev: %d (%s)</li>`,
        layout.severity, ntstatusSeverityName(layout.severity));
    buffer.writef(`<li>C: %d (%s)</li>`,
        layout.customer, layout.customer ? "Customer-defined" : "Microsoft-defined");
    if (layout.reserved)
        buffer.put(`<li>N: 1 (Reserved, must be clear in a well-formed NTSTATUS)</li>`);
    putFacilityItem(buffer, layout.facility, facility);
    buffer.writef(`<li>Code: 0x%04x (%d)</li>`, layout.code, layout.code);
    buffer.put(`</ul>`);
}
const(char)[] crtDescription(char[] buffer, ref DatabaseCrt crt)
{
    return sformat(buffer, "Error codes and messages from the %s C runtime (%s).", crt.full, crt.arch);
}
void pageCrt(ref HTTPReply buffer, ref DatabaseCrt crt)
{
    buffer.writef(`<p><a href="/crt/">C Runtimes</a> / %s</p>`, crt.name);
    buffer.writef(`<h1>%s</h1>`, crt.full);
    buffer.writef(`<p>Architecture: %s</p>`, crt.arch);
    
    putTableFilter(buffer, "messages", "Filter messages");
    buffer.put(
        `<table class="table" id="messages">`~
        `<thead>`~
            `<tr><th>Code</th><th style="width:80%">Message</th></tr>`~
        `</thead>`~
        `<tbody>`
    );

    size_t count;
    foreach (e; crt.messages)
    {
        ++count;
        buffer.writef(
            `<tr><td id="%s">%s</td><td>%s</td></tr>`,
            e.origId, e.code, e.message
        );
    }

    buffer.put(`</tbody>`);
    buffer.writef(`<tfoot><tr><td colspan="2">%s %s</td></tr></tfoot>`,
        count,
        plural(count,"entry","entries"));
    buffer.put(`</table>`);
}

/// Canonical page for a search query that can only mean one thing, null otherwise.
///
/// A code query never matches message text anyway, and its page decodes the
/// value even when nothing in the database carries it, so it always wins over
/// a result list. Symbolic names are not searched at all, only listed here.
string searchExactURL(char[] buffer, string query)
{
    uint code = void;
    if (parseCode(query, code))
        return cast(string)sformat(buffer, "/windows/code/0x%08x", code);

    WindowsHeader winheader = void;
    WindowsSymbolic winsymbol = databaseWindowsSymbolicByName(query, winheader);
    if (winsymbol.key == string.init)
        return null;

    return cast(string)sformat(buffer, "/windows/error/%s", winsymbol.key);
}

//
// CLI
//

static immutable string PAGE_VERSION =
`motoori `~PROJECT_VERSION~` (built: `~__TIMESTAMP__~`)
No rights resersved
License : CC0-1.0
Homepage: https://github.com/dd86k/motoori
Compiler: `~__VENDOR__~` v`~format(`%u.%03u`, version_major, version_minor);

static immutable string PAGE_HELP =
`Usage: motoori [options...]

Options`;

void clipage(string arg)
{
    import core.stdc.stdlib : exit;
    final switch (arg) {
    case "version": arg = PAGE_VERSION; break;
    case "license": arg = PAGE_LICENSE; break;
    }
    writeln(arg);
    exit(0);
}

int main(string[] args)
{
    string odatafolder = "data";
    ushort port = 8999;
    bool all;
    GetoptResult optres = void;
    try
    {
        optres = getopt(args, config.caseSensitive,
        "from-folder",  "Load data from folder (default='data')", &odatafolder,
        "all",          "Listen to all addresses", &all,
        "base-url",     "Origin for canonical URLs (default: request Host)", &base_url,
        "port",         "Listen to port (default=8999)", &port,
        "version",      "Show the version screen and exit.", &clipage,
        "license",      "Show the license screen and exit.", &clipage,
        );
    }
    catch (Exception ex)
    {
        stderr.writeln("error: ", ex.msg);
        return 1;
    }
    
    if (optres.helpWanted)
    {
        optres.options[$-1].help = "Show this help screen and exit.";
        writeln(PAGE_HELP);
        foreach (Option opt; optres.options) {
            with (opt) if (optShort)
                writefln("%s, %-12s  %s", optShort, optLong, help);
            else
                writefln("    %-12s  %s", optLong, help);
        }
        return 0;
    }
    
    // Paths are appended verbatim, so the origin must not end in one
    base_url = base_url.stripRight("/");

    write("Loading database..."); stdout.flush();
    databaseLoadFromFolder(odatafolder);
    writeln(" OK");
    
    // Reading it once into memory to reduce I/O and load times
    write("Pre-caching public resources..."); stdout.flush();
    ubyte[] buffer_chota_min_css = cast(ubyte[])readAll( "pub/chota.min.css" );
    ubyte[] buffer_favicon_png   = cast(ubyte[])readAll( "pub/favicon.png" );
    ubyte[] buffer_humans_txt    = cast(ubyte[])readAll( "pub/humans.txt" );
    ubyte[] buffer_main_css      = cast(ubyte[])readAll( "pub/main.css" );
    ubyte[] buffer_noscript_css  = cast(ubyte[])readAll( "pub/noscript.css" );
    ubyte[] buffer_robots_txt    = cast(ubyte[])readAll( "pub/robots.txt" );
    ubyte[] buffer_search_js     = cast(ubyte[])readAll( "pub/search.js" );
    ubyte[] buffer_table_js      = cast(ubyte[])readAll( "pub/table.js" );
    ubyte[] buffer_theme_js      = cast(ubyte[])readAll( "pub/theme.js" );
    writeln(" OK");
    
    // vibe-http has:
    // - much longer compile times and memory usage
    // - issues compiling with specific compilers
    HTTPServer http = new HTTPServer()
        .onError((ref HTTPRequest req, Exception ex)
        {
            HTTPReply buffer = HTTPReply.create(4 * 1024);

            prepareHeader(buffer, req, "OEDB", null, null, ActiveTab.none);

            int status = void;
            if (HttpServerException httpex = cast(HttpServerException)ex)
            {
                status = httpex.code;
                buffer.writef(`<h1>%s - %s</h1>`, httpex.code, httpex.msg);
            }
            else
            {
                status = 500;
                buffer.put(`<h1>500 - Internal Error</h1>`);
            }
            
            buffer.put(`<p class="center">Something broken? You can <a href="/about#contact">contact me</a>.</p>`);
            buffer.put(`<p class="center"><a href="/">Take me home</a></p>`);
            
            debug // Exception data
            {
                buffer.put(`<pre>`);
                buffer.put(ex.toString());
                buffer.put(`</pre>`);
            }
            
            prepareFooter(buffer);

            req.reply(status, buffer, "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/", (ref HTTPRequest req)
        {
            HTTPReply buffer = HTTPReply.create(4 * 1024);
            
            DatabaseStatistics dbstats = databaseStatistics();
            
            prepareHeader(buffer, req, "OEDB",
                "Online database of error codes and messages from Microsoft Windows "~
                "and C runtimes, searchable by code, symbolic name, or message text.",
                "/", ActiveTab.none);

            buffer.put(`<h1 class="title">Online Error Database</h1>`);
            buffer.put(`<div class="row" style="text-align:center;margin:2em;">`); // class="row"
            buffer.put(`<div class="col card">`); // windows header count
            buffer.writef(`<h3>%d</h3>`, dbstats.windowsHeaderCount);
            buffer.put(`<div><a href="/windows/headers">Windows headers</a></div>`);
            buffer.put(`</div>`); // windows header count
            buffer.put(`<div class="col card">`); // windows module count
            buffer.writef(`<h3>%d</h3>`, dbstats.windowsModuleCount);
            buffer.put(`<div><a href="/windows/modules">Windows modules</a></div>`);
            buffer.put(`</div>`); // windows module count
            buffer.put(`<div class="col card">`); // total messages
            buffer.writef(`<h3>%d</h3>`, dbstats.totalMessageCount);
            buffer.put(`<div>Error messages</div>`);
            buffer.put(`</div>`); // total messages
            buffer.put(`<div class="col card">`); // Windows Symbolic count
            buffer.writef(`<h3>%d</h3>`, dbstats.windowsSymbolicCount);
            buffer.put(`<div>Symbolic names</div>`);
            buffer.put(`</div>`); // Windows Symbolic count
            buffer.put(`</div>`); // class="row"
            
            buffer.put(
                `<p class="center tight">`~
                `Documenting error codes and messages found on various platforms, `~
                `such as Microsoft&reg; Windows&reg; `~
                `and C runtimes at the same, convenient place.`~
                `</p>`
            );
            
            prepareFooter(buffer);
            
            req.reply(200, buffer, "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/about", (ref HTTPRequest req)
        {
            HTTPReply buffer = HTTPReply.create(4 * 1024);
            
            prepareHeader(buffer, req, "About | OEDB",
                "About OEDB: where the error entries come from, the libraries in use, "~
                "and how to get in touch.",
                "/about", ActiveTab.about);
            
            buffer.put(`<h1>About</h1>`);
            buffer.put(
                `<p>`~
                `Inspired by <a href="https://github.com/henrypp">henry++</a>'s `~
                `<a href="https://github.com/henrypp/errorlookup/">errorlookup</a> `~
                `tool, this website contains a list of error messages mechanically `~
                `separated from the Windows operating system and C runtimes to be `~
                `accessible anywhere online.`~
                `</p>`);
            buffer.put(`<p>This website was created by <a href="https://github.com/dd86k/">dd86k</a>.</p>`);
            buffer.writef(`<p>Running Motoori %s, compiled %s.</p>`, PROJECT_VERSION, __TIMESTAMP__);
            buffer.put(`<h2>Sources</h2>`);
            buffer.put(
                `<ul>`~
                `<li><a href="https://www.microsoft.com/en-us/download/details.aspx?id=100432">`~
                    `Microsoft Error Lookup Tool version 6.4.5</a> for Windows header entries.</li>`~
                `<li>Microsoft Windows 10 x64 for Windows module entries.</li>`~
                `<li>Microsoft Windows 11 x64 for MSVC entries.</li>`~
                `<li>Ubuntu 24.04 AMD64 for Glibc entries.</li>`~
                `<li>Alpine 3.18 AMD64 for Musl entries.</li>`~
                `</ul>`
            );
            buffer.put(`<p>And Microsoft [MS-ERREF]: Windows Error Codes v20211116 for HRESULT facilities.</p>`);
            buffer.put(`<h2>Libraries</h2>`);
            buffer.put(`<ul>`);
            buffer.put(`<li><a href="https://jenil.github.io/chota/">Chota CSS Framework 0.8.0</a></li>`);
            buffer.put(`<li><a href="https://feathericons.com/">Feather Icons 4.29</a></li>`);
            buffer.put(`<li><a href="https://www.gnu.org/software/libmicrohttpd/">libmicrohttpd</a></li>`);
            buffer.put(`</ul>`);
            
            prepareFooter(buffer);
            
            req.reply(200, buffer, "text/html");
            return REQUEST_OK;
        })
        //
        // C runtime paths
        //
        .addRoute("GET", "/crt/", (ref HTTPRequest req)
        {
            HTTPReply buffer = HTTPReply.create(4 * 1024);
            
            prepareHeader(buffer, req, "C Runtimes | OEDB",
                "Error codes and messages from the MSVC, Glibc, and Musl C runtimes.",
                "/crt/", ActiveTab.crt);
            
            buffer.put(`<h1>C Runtimes</h1>`);
            buffer.put(`<p>Pages:</p>`);
            buffer.put(`<ul>`);
            buffer.put(`<li><a href="/crt/msvc">Microsoft Visual C Runtime</a></li>`);
            buffer.put(`<li><a href="/crt/gnu">GNU Library for C Runtime</a></li>`);
            buffer.put(`<li><a href="/crt/musl">Musl C Runtime</a></li>`);
            buffer.put(`</ul>`);
            buffer.put(
                `<p>`~
                `Runtimes are frameworks that provide an environment for user `~
                `code to use various utility functions. The C programming language `~
                `environment comes with what's know as the C Runtime ("CRT" for short).`~
                `</p>`
            );
            
            prepareFooter(buffer);
            
            req.reply(200, buffer, "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/crt/msvc", (ref HTTPRequest req)
        {
            HTTPReply buffer = HTTPReply.create(4 * 1024);
            
            DatabaseCrt crt = databaseCrt("msvc"); // HACK
            
            char[256] descbuf = void;
            prepareHeader(buffer, req, "MSVC | OEDB", crtDescription(descbuf, crt), "/crt/msvc", ActiveTab.crt);

            pageCrt(buffer, crt);

            prepareFooter(buffer, true);
            
            req.reply(200, buffer, "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/crt/gnu", (ref HTTPRequest req)
        {
            HTTPReply buffer = HTTPReply.create(4 * 1024);
            
            DatabaseCrt crt = databaseCrt("glibc"); // HACK
            
            char[256] descbuf = void;
            prepareHeader(buffer, req, "Glibc | OEDB", crtDescription(descbuf, crt), "/crt/gnu", ActiveTab.crt);

            pageCrt(buffer, crt);

            prepareFooter(buffer, true);
            
            req.reply(200, buffer, "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/crt/musl", (ref HTTPRequest req)
        {
            HTTPReply buffer = HTTPReply.create(4 * 1024);
            
            DatabaseCrt crt = databaseCrt("musl"); // HACK
            
            char[256] descbuf = void;
            prepareHeader(buffer, req, "Musl | OEDB", crtDescription(descbuf, crt), "/crt/musl", ActiveTab.crt);

            pageCrt(buffer, crt);

            prepareFooter(buffer, true);
            
            req.reply(200, buffer, "text/html");
            return REQUEST_OK;
        })
        //
        // Windows paths
        //
        .addRoute("GET", "/windows/", (ref HTTPRequest req)
        {
            HTTPReply buffer = HTTPReply.create(4 * 1024);
            
            prepareHeader(buffer, req, "Windows | OEDB",
                "The Windows error system: code formats, the modules and headers "~
                "defining them, and the releases they were scanned from.",
                "/windows/", ActiveTab.windows);
            
            buffer.put(`<h1>Windows Error System</h1>`);
            buffer.put(`<p>Pages:</p>`);
            buffer.put(`<ul>`);
            buffer.put(`<li><a href="/windows/error-types">Error code formats</a></li>`);
            buffer.put(`<li><a href="/windows/modules">List by module</a></li>`);
            buffer.put(`<li><a href="/windows/headers">List by header</a></li>`);
            buffer.put(`</ul>`);
            buffer.put(
                `<p>`~
                `The Microsoft Windows operating system uses a variety of `~
                `<abbr title="Application Program Interface">API</abbr>s from various `~
                `subsystems with different error code formats.`~
                `</p>`~
                `<p>`~
                `The online database contains error codes, symbolic names, `~
                `descriptions, and messages from various official Microsoft `~
                `sources, including the modules availble on the operating system.`~
                `</p>`~
                `<p>`~
                `All error code values and structure tables described in the Windows pages `~
                `use the little-endian memory ordering for multi-bit and multi-byte `~
                `definitions.`~
                `</p>`~
                `<p>`~
                `The different error code types are listed below. The `~
                `following links details each type of error codes seen across the `~
                `Windows ecosystem.`~
                `</p>`
            );
            
            // Legend for the "Found in" tags used on module pages
            buffer.put(`<h2>Scanned Releases</h2>`);
            buffer.put(`<p>Module messages are tagged with the releases they were found on.</p>`);
            buffer.put(`<table>`);
            buffer.put(`<thead><tr><th>Tag</th><th>Release</th><th>Build</th></tr></thead>`);
            buffer.put(`<tbody>`);
            foreach (ref WindowsRelease release; databaseWindowsReleases())
            {
                buffer.writef(
                    `<tr><td><span class="tag is-small">%s</span></td><td>%s</td><td>%s</td></tr>`,
                    release.key, release.name, release.build);
            }
            buffer.put(`</tbody></table>`);

            prepareFooter(buffer);
            
            req.reply(200, buffer, "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/windows/error-types", (ref HTTPRequest req)
        {
            HTTPReply buffer = HTTPReply.create(16 * 1024);
            
            prepareHeader(buffer, req, "Windows Error Types | OEDB",
                "The Win32, HRESULT, NTSTATUS, and LSTATUS error code formats "~
                "explained, with their bit layouts and facility codes.",
                "/windows/error-types", ActiveTab.windows);
            
            buffer.put(
                `<p><a href="/windows/">Windows</a> / Error types</p>`~
                `<h1>Windows Error Formats</h1>`~
                `<p>Windows contains a vast number of error codes in various formats. `~
                `This document explains the Win32, HRESULT, NTSTATUS, and LSTATUS error codes.</p>`~
                `<h2 id="win32">Win32</h2>`~
                `<p>`~
                `Win32 <abbr tittle="Application Programming Interface">API</abbr> error `~
                `codes are possibly the most known code structure in Windows. These codes `~
                `are used for various modules including the user-mode kernel modules (<code>ntdll.dll</code>).`~
                `</p>`~
                `<p>`~
                `All Windows error code should fit under 16-bit numbers between 0x0 (0) to `~
                `0xffff (65,535). However, some error codes may use a 32-bit number space `~
                `with extended fields (ie, <a href="#hresult">HRESULT</a>).`~
                `</p>`~
                `<h2 id="hresult">HRESULT</h2>`~
                `<p>`~
                `HRESULT codes are used under the <abbr title="Component Object Model">COM</abbr> `~
                `system`~
                `</p>`~
                `<p>`~
                `The table below denotes the structure of a HRESULT code.`~
                `</p>`~
                `<table class=table>`~
                `<tr>`~
                    `<th>31</th><th>30</th><th>29</th><th>28</th><th>27</th><th colspan="11">`~
                    `<span style="float:left">26</span><span style="float: right">16</span>`~
                    `</th>`~
                `</tr>`~
                `<tr>`~
                    `<td>S</td><td>R</td><td>C</td><td>N</td><td>X</td><td colspan="11">Facility</td>`~
                `</tr>`~
                `<tr>`~
                    `<th colspan="16"><span style="float: left">15</span><span style="float: right">0</span></th>`~
                `</tr>`~
                `<tr>`~
                    `<td colspan="16">Code</td>`~
                `</tr>`~
                `</table>`~
                `<p>Legend</p>`~
                `<ul>`~
                `<li>S (1 bit): Severity. If set, indicates a failure result. If clear, indicates a success result.</li>`~
                `<li>R (1 bit): Reserved. This bit must be cleared.</li>`~
                `<li>C (1 bit): Customer. Set for customer-defined values. All Microsoft values have this bit cleared.</li>`~
                `<li>N (1 bit): NTSTATUS if set.</li>`~
                `<li>X (1 bit): Reserved. Should be cleared, at the exception of a few codes described further below.</li>`~
                `<li>Facility (11 bits): Error source. A list of facilities are listed further below.</li>`~
                `<li>Code (16 bits): Error code.</li>`~
                `</ul>`~
                `<h3>HRESULT Facilities</h3>`~
                `<p>The table below lists facilities defined in the MS-ERREF specification.</p>`~
                `<table class="table">`~
                `<thead><tr><th>Name</th><th>Value</th><th>Description</th></tr></thead>`~
                `<tbody>`
            );
            immutable(WindowsFacility)[] hresult_facility_list = getWindowsHResultFacilities();
            foreach (facility; hresult_facility_list)
            {
                buffer.writef(
                    `<tr>`~
                    `<td>%s</td><td>%s</td><td>%s</td>`~
                    `</tr>`,
                    facility.id, facility.name, facility.description
                );
            }
            buffer.put(`</tbody></table>`);
            
            buffer.put(
                `<p>Some HRESULT codes, as exceptions, have the X bit set. They are listed below.</p>`~
                `<table class="table">`~
                `<thead><tr><th>Name</th><th>Value</th></tr></thead>`~
                `<tbody>`~
                `<tr><td>0x0DEAD100</td><td>TRK_S_OUT_OF_SYNC</td></tr>`~
                `<tr><td>0x0DEAD102</td><td>TRK_VOLUME_NOT_FOUND</td></tr>`~
                `<tr><td>0x0DEAD103</td><td>TRK_VOLUME_NOT_OWNED</td></tr>`~
                `<tr><td>0x0DEAD107</td><td>TRK_S_NOTIFICATION_QUOTA_EXCEEDED</td></tr>`~
                `<tr><td>0x8DEAD01B</td><td>TRK_E_NOT_FOUND</td></tr>`~
                `<tr><td>0x8DEAD01C</td><td>TRK_E_VOLUME_QUOTA_EXCEEDED</td></tr>`~
                `<tr><td>0x8DEAD01E</td><td>TRK_SERVER_TOO_BUSY</td></tr>`~
                `</tbody>`~
                `</table>`~
                `<p>`~
                `Converting Win32 error codes to an HRESULT code is done with the`~
                `following C macro.`~
                `</p>`~
                `<pre>`~
                `#define FACILITY_WIN32 0x0007`~"\n"~
                `#define __HRESULT_FROM_WIN32(x) ((HRESULT)(x) <= 0 ? ((HRESULT)(x)) : ((HRESULT) (((x) & 0x0000FFFF) | (FACILITY_WIN32 << 16) | 0x80000000)))`~
                `</pre>`~
                `<h2 id="ntstatus">NTSTATUS</h2>`~
                `<p>`~
                `NTSTATUS error codes are typically used for low-level operations `~
                `such as machine check exceptions, debugger API, and the `~
                `<abbr title="Windows-on-Windows64">SysWOW64</abbr> 32-bit `~
                `application layer, communicated from the WindowsNT kernel.`~
                `</p>`~
                `<p>These codes are defined in <code>Ntdef.h</code> and have the following structure.</p>`~
                `<table class="table">`~
                `<tr>`~
                `<th colspan="2"><span style="float: left">31</span> <span style="float: right">30</span></th>`~
                `<th>29</th>`~
                `<th>28</th>`~
                `<th colspan="12"><span style="float: left">27</span> <span style="float: right">16</span></th>`~
                `</tr>`~
                `<tr>`~
                `<td colspan="2">Sev</td>`~
                `<td>C</td>`~
                `<td>N</td>`~
                `<td colspan="12">Facility</td>`~
                `</tr>`~
                `<tr>`~
                `<th colspan="16"><span style="float: left">15</span> <span style="float: right">0</span></th>`~
                `</tr>`~
                `</tr>`~
                `<td colspan="16">Code</td>`~
                `</tr>`~
                `</table>`~
                `<p>Legend</p>`~
                `<ul>`~
                `<li>Sev (2 bits): Severity. Severity values are listed further below.</li>`~
                `<li>C (1 bit): Customer. Microsoft codes have this bit cleared.</li>`~
                `<li>N (1 bit): Reserved. Must be cleared so it can correspond to a HRESULT.</li>`~
                `<li>Facility (12 bits): Source facility.</li>`~
                `<li>Code (16 bits): Error code.</li>`~
                `</ul>`~
                `<h3>NTSTATUS Severities</h3>`~
                `<table class="table">`~
                `<tr>`~
                `<th>Value</th>`~
                `<th>Name</th>`~
                `<th>Description</th>`~
                `</tr>`~
                `<tr>`~
                `<td>0x0</td>`~
                `<td>STATUS_SEVERITY_SUCCESS</td>`~
                `<td>Success.</td>`~
                `</tr>`~
                `<tr>`~
                `<td>0x0</td>`~
                `<td>STATUS_SEVERITY_SUCCESS</td>`~
                `<td>Success.</td>`~
                `</tr>`~
                `<tr>`~
                `<td>0x1</td>`~
                `<td>STATUS_SEVERITY_INFORMATIONAL</td>`~
                `<td>Informational.</td>`~
                `</tr>`~
                `<tr>`~
                `<td>0x2</td>`~
                `<td>STATUS_SEVERITY_WARNING</td>`~
                `<td>Warning.</td>`~
                `</tr>`~
                `<tr>`~
                `<td>0x3</td>`~
                `<td>STATUS_SEVERITY_ERROR</td>`~
                `<td>Error.</td>`~
                `</tr>`~
                `</table>`
            );
            
            buffer.put(
                `<h3>NTSTATUS Facilities</h3>`~
                `<p>The table below lists facilities defined in the MS-ERREF specification.</p>`~
                `<table class="table">`~
                `<thead><tr><th>Name</th><th>Value</th><th>Description</th></tr></thead>`~
                `<tbody>`
            );
            immutable(WindowsFacility)[] ntstatus_facility_list = getWindowsNtstatusFacilities();
            foreach (facility; ntstatus_facility_list)
            {
                buffer.writef(
                    `<tr>`~
                    `<td>%s</td><td>%s</td><td>%s</td>`~
                    `</tr>`,
                    facility.id, facility.name, facility.description
                );
            }
            buffer.put(`</tbody></table>`);
            
            buffer.put(
                `<h2 id="lstatus">LSTATUS</h2>`~
                `<p>`~
                `The LSTATUS codes are legacy error codes used in some Windows functions. `~
                `The 'L' in LSTATUS connotates the Windows <code>LONG</code> data type, `~
                `defined in winreg.h as <code>LONG</code> under WinNT.h. `~
                `The <code>LONG</code> data type is defined as the C <code>long</code> data type.`~
                `</p>`~
                `<p>`~
                `Functions returning LSTATUS codes, such as the low-level Windows Registry API `~
                `(winreg.h), intially introduced in Window 3.1 (1992), and the `~
                `Windows Shell API (Shlwapi.h), do not seem to set the thread's last error code `~
                `(for example, using <code>SetLastError</code>), resulting in confusing `~
                `<code>GetLastError</code> results.`~
                `</p>`~
                `<p>`~
                `These error codes can also be used directly for <code>FormatMessage</code> `~
                `with <code>FORMAT_MESSAGE_FROM_SYSTEM</code>.`~
                `</p>`
            );
            
            prepareFooter(buffer);
            
            req.reply(200, buffer, "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/windows/modules", (ref HTTPRequest req)
        {
            HTTPReply buffer = HTTPReply.create(32 * 1024);
            
            prepareHeader(buffer, req, "Windows Modules | OEDB",
                "Windows modules (DLLs and executables) carrying error messages, "~
                "with the releases each one was found in.",
                "/windows/modules", ActiveTab.windows);
            
            buffer.put(
                `<p><a href="/windows/">Windows</a> / Modules</p>`~
                `<h1>Windows Modules</h1>`~
                `<p>`~
                `Also known as a dynamic library, or in the context of Windows, a DLL, `~
                `a module, that can be dynamically loaded onto memory, that may contain `~
                `code and resources. Resources include images, pieces of texts (strings), `~
                `certificates, and more.`~
                `</p>`~
                `<p>Some modules listed below may include executable images (.exe files).</p>`
            );
            
            WindowsModule[] modulelist = databaseWindowsModules();
            putTableFilter(buffer, "modules", "Filter modules");
            buffer.put(
                `<table class="table" id="modules">`~
                `<thead><tr><th>Name</th><th>Found in</th><th>Description</th></tr></thead>`~
                `<tbody>`
            );
            size_t count;
            foreach (mod; modulelist)
            {
                ++count;
                buffer.put(`<tr>`);
                buffer.writef(`<td><a href="/windows/module/%s">%s</a></td>`, mod.name, mod.name);
                buffer.put(`<td>`);
                putWindowsOS(buffer, mod.os);
                buffer.put(`</td>`);
                buffer.writef(`<td>%s</td>`, mod.description);
                buffer.put(`</tr>`);
            }
            buffer.put(`</tbody>`);
            buffer.writef(`<tfoot><tr><td colspan="3">%s %s</td></tr></tfoot>`,
                count,
                plural(count,"entry","entries"));
            buffer.put(`</table>`);
            
            prepareFooter(buffer, true);

            req.reply(200, buffer, "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/windows/headers", (ref HTTPRequest req)
        {
            HTTPReply buffer = HTTPReply.create(32 * 1024);
            
            prepareHeader(buffer, req, "Windows Headers | OEDB",
                "Windows header files defining error codes and their symbolic names.",
                "/windows/headers", ActiveTab.windows);
            
            buffer.put(
                `<p><a href="/windows/">Windows</a> / Headers</p>`~
                `<h1>Windows Headers</h1>`~
                `<p>`~
                `In computer software developments, a header file in C and C++ programming `~
                `is a file often containing definitions of types, structures, external `~
                `functions, and constant expressions that can be reused across multiple `~
                `source files.`~
                `</p>`~
                `<p>`~
                `While official Windows header files can be found in the Windows SDK `~
                `and Visual Studio installations, the current source is from the convenient `~
                `Microsoft Error Lookup tool.`~
                `</p>`
            );
            buffer.put(`<p>A list of headers can be found below.</p>`);
            
            WindowsHeader[] winheaders = databaseWindowsHeaders();
            putTableFilter(buffer, "headers", "Filter headers");
            buffer.put(`<table class="table" id="headers">`);
            buffer.put(`<thead><tr><th>Name</th><th>Abstract</th></tr></thead>`);
            buffer.put(`<tbody>`);
            size_t count;
            foreach (hdr; winheaders)
            {
                ++count;
                buffer.put(`<tr>`);
                buffer.writef(`<td><a href="/windows/header/%s">%s</a></td>`, hdr.key, hdr.name);
                buffer.writef(`<td>%s</td>`, hdr.description);
                buffer.put(`</tr>`);
            }
            buffer.put(`</tbody>`);
            buffer.writef(`<tfoot><tr><td colspan="2">%s %s</td></tr></tfoot>`,
                count,
                plural(count,"entry","entries"));
            buffer.put(`</table>`);
            
            prepareFooter(buffer, true);

            req.reply(200, buffer, "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/search", (ref HTTPRequest req)
        {
            import std.datetime.stopwatch : StopWatch;
            
            string query = req.param("q");
            if (query == null)
                throw new HttpServerException(400, "Bad Request", req);
            
            char[256] urlbuf = void;
            string exact = searchExactURL(urlbuf, query);
            if (exact)
            {
                req.redirect(302, exact);
                return REQUEST_OK;
            }
            
            string escaped = escapeHtml(query);
            
            StopWatch sw;
            sw.start();
            SearchResult[] results = search(query);
            sw.stop();
            
            HTTPReply buffer = HTTPReply.create(32 * 1024);
            
            // No canonical: every query is its own URL and robots.txt keeps
            // crawlers out of here anyway.
            prepareHeader(buffer, req, "Search | OEDB",
                "Search Windows and C runtime error codes, symbolic names, and messages.",
                null, ActiveTab.none, escaped);
            
            buffer.writef(`<h3>Results for "%s"</h3>`, escaped);
            
            if (results.length)
            {
                import std.format : sformat;
                char[200] urlcodebuf = void;
                string url_code = void;
                string url_title = void;
                string title_type = void;

                buffer.writef(`<p>%s results - %s</p>`, results.length, sw.peek());

                foreach (result; results)
                {
                    buffer.put(`<article class="result">`);
                    
                    final switch (result.type) {
                    case "windows-module":
                        title_type = "Windows modules";
                        url_title = cast(string)result.origId;
                        url_code = cast(string)sformat(urlcodebuf, "/windows/code/%s", result.origId);
                        break;
                    case "windows-symbol":
                        title_type = "Windows headers";
                        url_title = cast(string)result.origId;
                        url_code = cast(string)sformat(urlcodebuf, "/windows/error/%s", result.origId);
                        break;
                    case "crt":
                        title_type = "C runtime";
                        url_title = cast(string)result.name;
                        url_code = cast(string)sformat(urlcodebuf, "/crt/%s#%s", result.name, result.origId);
                        break;
                    }
                    
                    buffer.put(`<div class="searchtitle">`);
                    buffer.writef(`<a href="%s">%s</a>`, url_code, result.origId);
                    buffer.put(`</div>`);
                    
                    buffer.put(`<div>`);
                    buffer.put(title_type);
                    buffer.put(" - ");
                    buffer.put(result.name);
                    if (result.os)
                    {
                        buffer.put(" ");
                        putWindowsOS(buffer, result.os);
                    }
                    buffer.put(`</div>`);
                    
                    if (result.needle)
                    {
                        buffer.put(`<p>`);
                        if (result.preTruncated) buffer.put(`...`);
                        buffer.put(result.pre);
                        buffer.put(`<u>`);
                        buffer.put(result.needle);
                        buffer.put(`</u>`);
                        buffer.put(result.post);
                        if (result.postTruncated) buffer.put(`...`);
                        buffer.put(`</p>`);
                    }
                    
                    buffer.put(`</article>`);
                } // foreach results
            }
            else
            {
                buffer.put(`<h3>No results found.</h3>`);
            }
            
            prepareFooter(buffer);

            req.reply(200, buffer, "text/html");
            GC.collect();
            return REQUEST_OK;
        })
        .addRoute("GET", "/windows/header/:header", (ref HTTPRequest req)
        {
            string header = req.params["header"];
            if (header.length == 0)
                throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);
            
            WindowsHeader winheader = databaseWindowsHeader( header );
            if (winheader.name == string.init)
                throw new HttpServerException(HTTPStatus.notFound, HTTPMsg.notFound, req);
            
            HTTPReply buffer = HTTPReply.create(8 * 1024);
            
            char[256] descbuf = void;
            const(char)[] description = winheader.description.length ?
                winheader.description :
                sformat(descbuf, "Error codes and symbolic names defined in the Windows header %s.",
                    winheader.name);

            char[256] titlebuf = void;
            char[256] canonbuf = void;
            prepareHeader(buffer, req,
                cast(string)sformat(titlebuf, "%s | OEDB", winheader.name),
                description,
                cast(string)sformat(canonbuf, "/windows/header/%s", winheader.key),
                ActiveTab.windows);

            buffer.writef(
                `<p><a href="/windows/">Windows</a> / <a href="/windows/headers">Headers</a> / %s</p>`, winheader.key);
            buffer.writef(`<h1>%s</h1>`, winheader.name);
            buffer.writef(`<p>%s</p>`, winheader.description);
            buffer.put(`<h2>Associated Error Codes</h2>`);
            buffer.put(`<p>Below is a list of error codes found for this header.</p>`);
            putTableFilter(buffer, "codes", "Filter error codes");
            buffer.put(`<table id="codes">`);
            buffer.put(`<thead>`);
            buffer.put(`<tr><th>Symbolic</th><th>Value</th><th>Description</th></tr>`);
            buffer.put(`</thead>`);
            buffer.put(`<tbody>`);
            size_t count;
            foreach (sym; winheader.symbolics)
            {
                ++count;
                buffer.put(`<tr>`);
                buffer.writef(
                    `<td><a href="/windows/error/%s">%s</a></td>`, sym.key, sym.name);
                buffer.writef(
                    `<td><a href="/windows/code/%s">%s</a></td>`, sym.origId, sym.origId);
                buffer.writef(`<td>%s</td>`, sym.message);
                buffer.put(`</tr>`);
            }
            buffer.put(`</tbody>`);
            buffer.put(`<tfoot>`);
            buffer.writef(`<tr><td colspan="3">%s %s</td></tr>`, count, plural(count,"entry","entries"));
            buffer.put(`</tfoot>`);
            buffer.put(`</table>`);
            
            prepareFooter(buffer, true);

            req.reply(200, buffer, "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/windows/module/:module", (ref HTTPRequest req)
        {
            string module_ = req.params["module"];
            if (module_ == null)
                throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);
            
            WindowsModule mod = databaseWindowsModule(module_);
            if (mod.name == string.init)
                throw new HttpServerException(HTTPStatus.notFound, HTTPMsg.notFound, req);
            
            HTTPReply buffer = HTTPReply.create(8 * 1024);
            
            char[256] descbuf = void;
            const(char)[] description = mod.description.length ?
                mod.description :
                sformat(descbuf, "Error codes and messages found in the Windows module %s.",
                    mod.name);

            char[256] titlebuf = void;
            char[256] canonbuf = void;
            prepareHeader(buffer, req,
                cast(string)sformat(titlebuf, "%s | OEDB", mod.name),
                description,
                cast(string)sformat(canonbuf, "/windows/module/%s", mod.name),
                ActiveTab.windows);
            
            buffer.writef(`<p><a href="/windows/">Windows</a> / <a href="/windows/modules">Modules</a> / %s</p>`, mod.name);
            buffer.writef(`<h1>%s</h1>`, mod.name);
            buffer.writef(`<p>%s</p>`, mod.description);
            
            buffer.put(`<h2>Associated Error Codes</h2>`);
            buffer.put(`<p>Below lists error codes and symbolic names found for this module.</p>`);

            putTableFilter(buffer, "codes", "Filter error codes");
            buffer.put(`<table id="codes">`);
            buffer.put(`<thead><tr><th>Code</th><th>Found in</th><th>Description</th></tr></thead>`);
            buffer.put(`<tbody>`);
            size_t count;
            foreach (err; mod.messages)
            {
                ++count;

                import utils : sformatWindowsCode;
                char[32] buf = void;
                // "shorten" the error code for URL and readability
                string formal = sformatWindowsCode(buf, err.id);
                buffer.writef(
                    `<tr>`~
                    `<td><a href="/windows/code/%s">%s</a></td>`~
                    `<td>`,
                    formal, formal
                );
                putWindowsOS(buffer, err.os);
                buffer.writef(`</td><td>%s</td></tr>`, err.message);
            }
            buffer.put(`</tbody>`);
            buffer.put(`<tfoot>`);
            buffer.writef(`<tr><td colspan="3">%s %s</td></tr>`, count, plural(count,"entry","entries"));
            buffer.put(`</tfoot>`);
            buffer.put(`</table>`);
            
            prepareFooter(buffer, true);

            req.reply(200, buffer, "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/windows/code/:code", (ref HTTPRequest req)
        {
            string qcode = req.params["code"];
            if (qcode.length == 0)
                throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);
            
            uint code = void;
            if (parseCode(qcode, code) == false)
                throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);
            
            // Associated headers and modules
            SearchWindowsHeaderResult[] results_headers = searchWindowsHeadersByCode(code);
            SearchWindowsModuleResult[] results_modules = searchWindowsModulesByCode(code);
            
            // "Proper" code as if MS would print it I guess
            char[32] formalbuf = void;
            string formal = cast(string)sformat(formalbuf[], "0x%08x", code);
            
            HTTPReply buffer = HTTPReply.create(16 * 1024);
            
            // Counts rather than one of the messages: a bare code means different
            // things in every subsystem that returns it, so quoting the first
            // match would assert a meaning the page itself does not.
            char[256] descbuf = void;
            const(char)[] description = results_modules.length || results_headers.length ?
                sformat(descbuf,
                    "Windows error code %s (%u) decoded as HRESULT and NTSTATUS, "~
                    "with the %u %s and %u %s defining it.",
                    formal, code,
                    results_modules.length, plural(results_modules.length, "module", "modules"),
                    results_headers.length, plural(results_headers.length, "header", "headers")) :
                sformat(descbuf,
                    "Windows error code %s (%u) decoded as HRESULT and NTSTATUS. "~
                    "No module or header in the database carries it.",
                    formal, code);

            char[64] titlebuf = void;
            char[64] canonbuf = void;
            prepareHeader(buffer, req,
                cast(string)sformat(titlebuf, "%s | OEDB", formal),
                description,
                // Padded form: the same code is reachable as 5, 0x5 and 0x00000005
                cast(string)sformat(canonbuf, "/windows/code/%s", formal),
                ActiveTab.windows);
            
            buffer.writef(`<p><a href="/windows/">Windows</a> / Code / %s</p>`, formal);
            buffer.writef(`<h1>%s</h1>`, formal);
            buffer.writef(`<p>Decimal: %u &middot; Signed: %d</p>`, code, cast(int)code);
            
            putWindowsCodeDecoding(buffer, code);
            
            // Most codes match a handful of entries, but the low numeric ones
            // collide across nearly every subsystem, so only offer the filter there.
            bool filter_mods = results_modules.length >= FILTER_MIN_ROWS;
            bool filter_headers = results_headers.length >= FILTER_MIN_ROWS;

            buffer.put(`<h2>Associated Modules</h2>`);
            if (filter_mods)
                putTableFilter(buffer, "modules", "Filter modules");
            buffer.put(`<table id="modules">`);
            buffer.put(`<thead><tr><th>Module</th><th>Found in</th><th>Description</th></tr></thead>`);
            buffer.put(`<tbody>`);
            size_t count_mods;
            foreach (ref result; results_modules)
            {
                ++count_mods;

                buffer.writef(
                    `<tr>`~
                    `<td><a href="/windows/module/%s">%s</a></td>`~
                    `<td>`,
                    result.module_.name, result.module_.name
                );
                putWindowsOS(buffer, result.error.os);
                buffer.writef(`</td><td>%s</td></tr>`, result.error.message);
            }
            buffer.put(`</tbody><tfoot>`);
            buffer.writef(`<tr><td colspan="3">%s %s</td></tr>`, count_mods, plural(count_mods,"entry","entries"));
            buffer.put(`</tfoot></table>`);

            buffer.put(`<h2>Associated Headers</h2>`);
            if (filter_headers)
                putTableFilter(buffer, "headers", "Filter headers");
            buffer.put(`<table id="headers">`);
            buffer.put(`<thead><tr><th>Header</th><th>Symbolic</th><th>Description</th></tr></thead>`);
            buffer.put(`<tbody>`);
            size_t count_headers;
            foreach (ref result; results_headers)
            {
                ++count_headers;
                
                with (result)
                buffer.writef(
                    `<tr>`~
                    `<td><a href="/windows/header/%s">%s</a></td>`~
                    `<td id="%s"><a href="/windows/error/%s">%s</a></td>`~
                    `<td>%s</td>`~
                    `</tr>`,
                    header.key, header.name,
                    error.name, error.key, error.name,
                    error.message
                );
            }
            buffer.put(`</tbody><tfoot>`);
            buffer.writef(`<tr><td colspan="3">%s %s</td></tr>`,
                count_headers, plural(count_headers,"entry","entries"));
            buffer.put(`</tfoot></table>`);

            prepareFooter(buffer, filter_mods || filter_headers);

            req.reply(200, buffer, "text/html");
            GC.collect();
            return REQUEST_OK;
        })
        .addRoute("GET", "/windows/error/:symbol", (ref HTTPRequest req)
        {
            string qsymbol = req.params["symbol"];
            if (qsymbol.length == 0)
                throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);
            
            char[256] symbolbuf = void;
            string symbolname = cast(string)toLowerBuf(symbolbuf, qsymbol);
            if (symbolname is null)
                throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);

            WindowsHeader winheader = void;
            WindowsSymbolic winsymbol = databaseWindowsSymbolicByName(symbolname, winheader);
            if (winsymbol.name == string.init)
                throw new HttpServerException(HTTPStatus.notFound, HTTPMsg.notFound, req);
            
            // Associated modules
            SearchWindowsModuleResult[] modules = searchWindowsModulesByCode(winsymbol.id);
            
            HTTPReply buffer = HTTPReply.create(16 * 1024);
            
            char[512] descbuf = void;
            const(char)[] description = winsymbol.message.length ?
                sformat(descbuf, "%s (%s): %s",
                    winsymbol.name, winsymbol.origId, limit(winsymbol.message, 300)) :
                sformat(descbuf, "%s is Windows error code %s (%s).",
                    winsymbol.name, winsymbol.origId, winsymbol.decId);

            char[256] titlebuf = void;
            char[256] canonbuf = void;
            prepareHeader(buffer, req,
                cast(string)sformat(titlebuf, "%s | OEDB", winsymbol.name),
                description,
                cast(string)sformat(canonbuf, "/windows/error/%s", winsymbol.key),
                ActiveTab.windows);
            
            buffer.writef(
                `<p>`~
                `<a href="/windows/">Windows</a> / `~
                `<a href="/windows/headers">Headers</a> / `~
                `<a href="/windows/header/%s">%s</a> / `~
                `%s`~
                `</p>`,
                winheader.name, winheader.name, winsymbol.name
            );
            buffer.writef(`<h1>%s</h1>`, winsymbol.name);
            buffer.writef(`<p>Code: <a href="/windows/code/%s">%s</a> (%s)</p>`,
                winsymbol.origId, winsymbol.origId, winsymbol.decId);
            
            putWindowsCodeDecoding(buffer, winsymbol.id);
            
            if (winsymbol.message.length)
            {
                buffer.writef(
                    `<h2>Abstract</h2>`~
                    `<p>%s</p>`,
                    winsymbol.message
                );
            }
            
            if (modules.length)
            {
                buffer.put(`<h2>Associated Modules</h2>`);
                buffer.put(`<table>`);
                buffer.put(`<thead><tr><th>Module</th><th>Code</th><th>Found in</th><th>Description</th></tr></thead>`);
                buffer.put(`<tbody>`);
                size_t count_mods;
                foreach (mod; modules)
                {
                    ++count_mods;

                    with (mod)
                    {
                        buffer.writef(
                            `<tr>`~
                            `<td><a href="/windows/module/%s">%s</a></td>`~
                            `<td><a href="/windows/code/%s">%s</a></td>`~
                            `<td>`,
                            module_.name, module_.name,
                            error.origId, error.origId
                        );
                        putWindowsOS(buffer, error.os);
                        buffer.writef(`</td><td>%s</td></tr>`, error.message);
                    }
                }
                buffer.put(`</tbody><tfoot>`);
                buffer.writef(`<tr><td colspan="4">%s %s</td></tr>`, count_mods, plural(count_mods,"entry","entries"));
                buffer.put(`</tfoot></table>`);
            }
            
            prepareFooter(buffer);

            req.reply(200, buffer, "text/html");
            GC.collect();
            return REQUEST_OK;
        })
        //
        // pub content
        // remember, FS stuff in vibe-d ballooned memory usage in problematic ways
        //
        .addPubRoute("/favicon.png",    buffer_favicon_png,   "image/png")
        .addPubRoute("/theme.js",       buffer_theme_js,      "text/javascript")
        .addPubRoute("/table.js",       buffer_table_js,      "text/javascript")
        .addPubRoute("/search.js",      buffer_search_js,     "text/javascript")
        .addPubRoute("/main.css",       buffer_main_css,      "text/css")
        .addPubRoute("/chota.min.css",  buffer_chota_min_css, "text/css")
        .addPubRoute("/noscript.css",   buffer_noscript_css,  "text/css")
        .addPubRoute("/humans.txt",     buffer_humans_txt,    "text/plain")
        .addPubRoute("/robots.txt",     buffer_robots_txt,    "text/plain")
    ;
    
    http.start(port);
    
    writeln("Listening on port ", port);
    
    // NOTE: looping readln
    //       This caused a significant issue with OpenRC's start-stop-daemon.1
    //       when using command_background=true.
    //       This doesn't support "background" stuff. Instead, emulate being busy.
    import core.thread : Thread;
    import core.time : dur;
    while (true)
        Thread.sleep(dur!"seconds"(60));
}