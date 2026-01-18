module hoster.main;

import std.compiler : version_major, version_minor;
import std.format;
import std.stdio;
import std.getopt;
import std.string : toLower;
import std.outbuffer;
import motoori, database;
import extra.windows;

import ddhttpd;

static import std.file;
alias readAll = std.file.read;

private:

// temporary until moved to database
import std.algorithm.sorting : sort;
struct ErrorModule
{
    const(char)[] name;
    const(char)[] message;
    const(char)[] symbolic;
}

void prepareHeader(OutBuffer buffer, string title, ActiveTab tab, string search_query = null)
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
    buffer.put(`<input name="q" placeholder="Search"`);
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
void prepareFooter(OutBuffer buffer, string build_date = __DATE__)
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
    buffer.writef(`<span class="right">Built: %s</span>`, build_date);
    buffer.put(`</div>`);
    buffer.put(`</footer>`);
    
    buffer.put(`<script src="/theme.js"></script>`);
    
    buffer.put(`</body>`);
    buffer.put(`</html>`);
}
void pageCrt(OutBuffer buffer, ref DatabaseCrt crt)
{
    buffer.writef(`<p><a href="/crt/">C Runtimes</a> / %s</p>`, crt.name);
    buffer.writef(`<h1>%s</h1>`, crt.full);
    buffer.writef(`<p>Architecture: %s</p>`, crt.arch);
    
    buffer.put(
        `<table class="table">`~
        `<thead>`~
            `<tr><th>Code</th><th style="width:80%">Message</th></tr>`~
        `</thead>`~
        `<tbody>`
    );
    
    foreach (e; crt.messages)
    {
        buffer.writef(
            `<tr><td id="%s">%s</td><td>%s</td></tr>`,
            e.origId, e.code, e.message
        );
    }
    
    buffer.put(`</tbody></table>`);
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
    
    write("Loading database..."); stdout.flush();
    databaseLoadFromFolder(odatafolder);
    writeln(" OK");
    
    /*
    scope URLRouter router = new URLRouter()
        // Windows error by symbolic name
        .get("/windows/error/:symbol", (HTTPServerRequest req, HTTPServerResponse res)
        {
            string symbolname = toLower( req.params["symbol"] );
            
            WindowsHeader winheader = void;
            WindowsSymbolic winsymbol = databaseWindowsSymbolicByName(symbolname, winheader);
            if (winsymbol.name == string.init)
                throw new HTTPStatusException(404);
            
            // Associated facilities
            ushort nstatus_facility_id = ntstatusFacilityIDByCode(winsymbol.id);
            WindowsFacility ntstatus_facility = ntstatusFacilityById(nstatus_facility_id);
            if (ntstatus_facility.name == string.init)
            {
                ntstatus_facility.name = "Unknown";
                ntstatus_facility.id   = nstatus_facility_id;
            }
            ushort hresult_facility_id = hresultFacilityIDByCode(winsymbol.id);
            WindowsFacility hresult_facility  = hresultFacilityById(hresult_facility_id);
            if (hresult_facility.name == string.init)
            {
                hresult_facility.name = "Unknown";
                hresult_facility.id   = hresult_facility_id;
            }
            
            // Associated modules
            SearchWindowsModuleResult[] modules = searchWindowsModulesByCode(winsymbol.id);
            
            PageSettings page = PageSettings(ActiveTab.windows, winsymbol.name~" | OEDB");
            res.render!("windows-symbolic.dt", page,
                winsymbol, winheader,
                ntstatus_facility,
                hresult_facility,
                modules);
        })
        // Windows error by code
        .get("/windows/code/:code", (HTTPServerRequest req, HTTPServerResponse res)
        {
            string codeparam = req.params["code"];
            
            bool succ = void;
            uint code = parseCode(codeparam, succ);
            if (succ == false)
                throw new HTTPStatusException(400);
            
            // Associated facilities
            ushort nstatus_facility_id = ntstatusFacilityIDByCode(code);
            WindowsFacility ntstatus_facility = ntstatusFacilityById(nstatus_facility_id);
            if (ntstatus_facility.name == string.init)
            {
                ntstatus_facility.name = "Unknown";
                ntstatus_facility.id   = nstatus_facility_id;
            }
            ushort hresult_facility_id = hresultFacilityIDByCode(code);
            WindowsFacility hresult_facility  = hresultFacilityById(hresult_facility_id);
            if (hresult_facility.name == string.init)
            {
                hresult_facility.name = "Unknown";
                hresult_facility.id   = hresult_facility_id;
            }
            
            // Associated headers and modules
            SearchWindowsHeaderResult[] results_headers = searchWindowsHeadersByCode(code);
            SearchWindowsModuleResult[] results_modules = searchWindowsModulesByCode(code);
            
            char[32] formalbuf = void;
            string formal = cast(string)sformat(formalbuf[], "0x%08x", code);
            
            PageSettings page = PageSettings(ActiveTab.windows, formal~" | OEDB");
            res.render!("windows-code.dt", page,
                ntstatus_facility, hresult_facility,
                results_modules,   results_headers,
                formal);
        })
    ;
    */
    
    // Reading it once into memory to reduce I/O and load times
    write("Pre-caching public resources..."); stdout.flush();
    ubyte[] buffer_chota_min_css = cast(ubyte[])readAll( "pub/chota.min.css" );
    ubyte[] buffer_favicon_png   = cast(ubyte[])readAll( "pub/favicon.png" );
    ubyte[] buffer_humans_txt    = cast(ubyte[])readAll( "pub/humans.txt" );
    ubyte[] buffer_main_css      = cast(ubyte[])readAll( "pub/main.css" );
    ubyte[] buffer_noscript_css  = cast(ubyte[])readAll( "pub/noscript.css" );
    ubyte[] buffer_robots_txt    = cast(ubyte[])readAll( "pub/robots.txt" );
    ubyte[] buffer_theme_js      = cast(ubyte[])readAll( "pub/theme.js" );
    writeln(" OK");
    
    // vibe-http has:
    // - much longer compile times and memory usage
    // - issues compiling with specific compilers
    HTTPServer http = new HTTPServer()
        .onError((ref HTTPRequest req, Exception ex)
        {
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(4 * 1024);
            
            prepareHeader(buffer, "OEDB", ActiveTab.none);
            
            if (HttpServerException httpex = cast(HttpServerException)ex)
            {
                buffer.writef(`<h1>%s - %s</h1>`, httpex.code, httpex.msg);
            }
            else
            {
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
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/", (ref HTTPRequest req)
        {
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(4 * 1024);
            
            DatabaseStatistics dbstats = databaseStatistics();
            
            prepareHeader(buffer, "OEDB", ActiveTab.none);
            
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
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/about", (ref HTTPRequest req)
        {
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(4 * 1024);
            
            prepareHeader(buffer, "About | OEDB", ActiveTab.about);
            
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
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        //
        // C runtime paths
        //
        .addRoute("GET", "/crt/", (ref HTTPRequest req)
        {
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(4 * 1024);
            
            prepareHeader(buffer, "C Runtimes | OEDB", ActiveTab.crt);
            
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
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/crt/msvc", (ref HTTPRequest req)
        {
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(4 * 1024);
            
            DatabaseCrt crt = databaseCrt("msvc"); // HACK
            
            prepareHeader(buffer, "MSVC | OEDB", ActiveTab.crt);
            
            pageCrt(buffer, crt);
            
            prepareFooter(buffer);
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/crt/gnu", (ref HTTPRequest req)
        {
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(4 * 1024);
            
            DatabaseCrt crt = databaseCrt("glibc"); // HACK
            
            prepareHeader(buffer, "Glibc | OEDB", ActiveTab.crt);
            
            pageCrt(buffer, crt);
            
            prepareFooter(buffer);
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/crt/musl", (ref HTTPRequest req)
        {
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(4 * 1024);
            
            DatabaseCrt crt = databaseCrt("musl"); // HACK
            
            prepareHeader(buffer, "Musl | OEDB", ActiveTab.crt);
            
            pageCrt(buffer, crt);
            
            prepareFooter(buffer);
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        //
        // Windows paths
        //
        .addRoute("GET", "/windows/", (ref HTTPRequest req)
        {
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(4 * 1024);
            
            prepareHeader(buffer, "Windows | OEDB", ActiveTab.windows);
            
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
            
            prepareFooter(buffer);
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/windows/error-types", (ref HTTPRequest req)
        {
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(16 * 1024);
            
            prepareHeader(buffer, "Windows Error Types | OEDB", ActiveTab.windows);
            
            buffer.put(`<p><a href="/windows/">Windows</a> / Error types</p>`);
            buffer.put(`<h1>Windows Error Formats</h1>`);
            buffer.put(`<p>Windows contains a vast number of error codes in various formats. `~
                `This document explains the Win32, HRESULT, NTSTATUS, and LSTATUS error codes.</p>`);
            
            buffer.put(
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
                `</p>`
            );
            buffer.put(
                `<h2 id="hresult">HRESULT</h2>`~
                `<p>`~
                `HRESULT codes are used under the <abbr title="Component Object Model">COM</abbr> `~
                `system`~
                `</p>`~
                `<p>`~
                `The table below denotes the structure of a HRESULT code.`~
                `</p>`
            );
            buffer.put(
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
                `</table>`
            );
            buffer.put(`<p>Legend</p>`);
            buffer.put(
                `<ul>`~
                `<li>S (1 bit): Severity. If set, indicates a failure result. If clear, indicates a success result.</li>`~
                `<li>R (1 bit): Reserved. This bit must be cleared.</li>`~
                `<li>C (1 bit): Customer. Set for customer-defined values. All Microsoft values have this bit cleared.</li>`~
                `<li>N (1 bit): NTSTATUS if set.</li>`~
                `<li>X (1 bit): Reserved. Should be cleared, at the exception of a few codes described further below.</li>`~
                `<li>Facility (11 bits): Error source. A list of facilities are listed further below.</li>`~
                `<li>Code (16 bits): Error code.</li>`~
                `</ul>`
            );
            
            buffer.put(`<h3>HRESULT Facilities</h3>`);
            buffer.put(`<p>The table below lists facilities defined in the MS-ERREF specification.</p>`);
            buffer.put(`<table class="table">`);
            buffer.put(`<thead><tr><th>Name</th><th>Value</th><th>Description</th></tr></thead>`);
            buffer.put(`<tbody>`);
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
            buffer.put(`</tbody>`);
            buffer.put(`</table>`);
            
            buffer.put(`<p>Some HRESULT codes, as exceptions, have the X bit set. They are listed below.</p>`);
            buffer.put(`<table class="table">`);
            buffer.put(`<thead><tr><th>Name</th><th>Value</th></tr></thead>`);
            buffer.put(`<tbody>`);
            buffer.put(`<tr><td>0x0DEAD100</td><td>TRK_S_OUT_OF_SYNC</td></tr>`);
            buffer.put(`<tr><td>0x0DEAD102</td><td>TRK_VOLUME_NOT_FOUND</td></tr>`);
            buffer.put(`<tr><td>0x0DEAD103</td><td>TRK_VOLUME_NOT_OWNED</td></tr>`);
            buffer.put(`<tr><td>0x0DEAD107</td><td>TRK_S_NOTIFICATION_QUOTA_EXCEEDED</td></tr>`);
            buffer.put(`<tr><td>0x8DEAD01B</td><td>TRK_E_NOT_FOUND</td></tr>`);
            buffer.put(`<tr><td>0x8DEAD01C</td><td>TRK_E_VOLUME_QUOTA_EXCEEDED</td></tr>`);
            buffer.put(`<tr><td>0x8DEAD01E</td><td>TRK_SERVER_TOO_BUSY</td></tr>`);
            buffer.put(`</tbody>`);
            buffer.put(`</table>`);
            
            buffer.put(
                `<p>`~
                `Converting Win32 error codes to an HRESULT code is done with the`~
                `following C macro.`~
                `</p>`~
                `<pre>`~
                `#define FACILITY_WIN32 0x0007`~"\n"~
                `#define __HRESULT_FROM_WIN32(x) ((HRESULT)(x) <= 0 ? ((HRESULT)(x)) : ((HRESULT) (((x) & 0x0000FFFF) | (FACILITY_WIN32 << 16) | 0x80000000)))`~
                `</pre>`
            );
            
            buffer.put(`<h2 class="ntstatus">NTSTATUS</h2>`);
            buffer.put(
                `<p>`~
                `NTSTATUS error codes are typically used for low-level operations `~
                `such as machine check exceptions, debugger API, and the `~
                `<abbr title="Windows-on-Windows64">SysWOW64</abbr> 32-bit `~
                `application layer, communicated from the WindowsNT kernel.`~
                `</p>`
            );
            buffer.put(`<p>These codes are defined in <code>Ntdef.h</code> and have the following structure.</p>`);
            
            buffer.put(`<table class="table">`);
            buffer.put(`<tr>`);
            buffer.put(`<th colspan="2"><span style="float: left">31</span> <span style="float: right">30</span></th>`);
            buffer.put(`<th>29</th>`);
            buffer.put(`<th>28</th>`);
            buffer.put(`<th colspan="12"><span style="float: left">27</span> <span style="float: right">16</span></th>`);
            buffer.put(`</tr>`);
            buffer.put(`<tr>`);
            buffer.put(`<td colspan="2">Sev</td>`);
            buffer.put(`<td>C</td>`);
            buffer.put(`<td>N</td>`);
            buffer.put(`<td colspan="12">Facility</td>`);
            buffer.put(`</tr>`);
            buffer.put(`<tr>`);
            buffer.put(`<th colspan="16"><span style="float: left">15</span> <span style="float: right">0</span></th>`);
            buffer.put(`</tr>`);
            buffer.put(`</tr>`);
            buffer.put(`<td colspan="16">Code</td>`);
            buffer.put(`</tr>`);
            buffer.put(`</table>`);
            
            buffer.put(`<p>Legend</p>`);
            buffer.put(`<ul>`);
            buffer.put(`<li>Sev (2 bits): Severity. Severity values are listed further below.</li>`);
            buffer.put(`<li>C (1 bit): Customer. Microsoft codes have this bit cleared.</li>`);
            buffer.put(`<li>N (1 bit): Reserved. Must be cleared so it can correspond to a HRESULT.</li>`);
            buffer.put(`<li>Facility (12 bits): Source facility.</li>`);
            buffer.put(`<li>Code (16 bits): Error code.</li>`);
            buffer.put(`</ul>`);
            
            buffer.put(`<h3>NTSTATUS Severities</h3>`);
            buffer.put(`<table class="table">`);
            buffer.put(`<tr>`);
            buffer.put(`<th>Value</th>`);
            buffer.put(`<th>Name</th>`);
            buffer.put(`<th>Description</th>`);
            buffer.put(`</tr>`);
            buffer.put(`<tr>`);
            buffer.put(`<td>0x0</td>`);
            buffer.put(`<td>STATUS_SEVERITY_SUCCESS</td>`);
            buffer.put(`<td>Success.</td>`);
            buffer.put(`</tr>`);
            buffer.put(`<tr>`);
            buffer.put(`<td>0x0</td>`);
            buffer.put(`<td>STATUS_SEVERITY_SUCCESS</td>`);
            buffer.put(`<td>Success.</td>`);
            buffer.put(`</tr>`);
            buffer.put(`<tr>`);
            buffer.put(`<td>0x1</td>`);
            buffer.put(`<td>STATUS_SEVERITY_INFORMATIONAL</td>`);
            buffer.put(`<td>Informational.</td>`);
            buffer.put(`</tr>`);
            buffer.put(`<tr>`);
            buffer.put(`<td>0x2</td>`);
            buffer.put(`<td>STATUS_SEVERITY_WARNING</td>`);
            buffer.put(`<td>Warning.</td>`);
            buffer.put(`</tr>`);
            buffer.put(`<tr>`);
            buffer.put(`<td>0x3</td>`);
            buffer.put(`<td>STATUS_SEVERITY_ERROR</td>`);
            buffer.put(`<td>Error.</td>`);
            buffer.put(`</tr>`);
            buffer.put(`</table>`);
            
            
            buffer.put(`<h3>NTSTATUS Facilities</h3>`);
            buffer.put(`<p>The table below lists facilities defined in the MS-ERREF specification.</p>`);
            buffer.put(`<table class="table">`);
            buffer.put(`<thead><tr><th>Name</th><th>Value</th><th>Description</th></tr></thead>`);
            buffer.put(`<tbody>`);
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
            buffer.put(`</tbody>`);
            buffer.put(`</table>`);
            
            buffer.put(`<h2 id="lstatus">LSTATUS</h2>`);
            buffer.put(
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
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/windows/modules", (ref HTTPRequest req)
        {
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(32 * 1024);
            
            prepareHeader(buffer, "Windows Modules | OEDB", ActiveTab.windows);
            
            buffer.put(`<p><a href="/windows/">Windows</a> / Modules</p>`);
            buffer.put(`<h1>Windows Modules</h1>`);
            buffer.put(
                `<p>`~
                `Also known as a dynamic library, or in the context of Windows, a DLL, `~
                `a module, that can be dynamically loaded onto memory, that may contain `~
                `code and resources. Resources include images, pieces of texts (strings), `~
                `certificates, and more.`~
                `</p>`
            );
            buffer.put(`<p>Some modules listed below may include executable images (.exe files).</p>`);
            
            WindowsModule[] modulelist = databaseWindowsModules();
            buffer.put(`<table class="table">`);
            buffer.put(`<thead><tr><th>Name</th><th>Description</th></tr></thead>`);
            buffer.put(`<tbody>`);
            size_t count;
            foreach (mod; modulelist)
            {
                ++count;
                buffer.put(`<tr>`);
                buffer.writef(`<td><a href="/windows/module/%s">%s</a></td>`, mod.name, mod.name);
                buffer.writef(`<td>%s</td>`, mod.description);
                buffer.put(`</tr>`);
            }
            buffer.put(`</tbody>`);
            buffer.writef(`<tfoot><tr><td colspan="2">%s %s</td></tr></tfoot>`,
                count,
                plural(count,"entry","entries"));
            buffer.put(`</table>`);
            
            prepareFooter(buffer);
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/windows/headers", (ref HTTPRequest req)
        {
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(32 * 1024);
            
            prepareHeader(buffer, "Windows Headers | OEDB", ActiveTab.windows);
            
            buffer.put(`<p><a href="/windows/">Windows</a> / Headers</p>`);
            buffer.put(`<h1>Windows Headers</h1>`);
            buffer.put(
                `<p>`~
                `In computer software developments, a header file in C and C++ programming `~
                `is a file often containing definitions of types, structures, external `~
                `functions, and constant expressions that can be reused across multiple `~
                `source files.`~
                `</p>`
            );
            buffer.put(
                `<p>`~
                `While official Windows header files can be found in the Windows SDK `~
                `and Visual Studio installations, the current source is from the convenient `~
                `Microsoft Error Lookup tool.`~
                `</p>`
            );
            buffer.put(`<p>A list of headers can be found below.</p>`);
            
            WindowsHeader[] winheaders = databaseWindowsHeaders();
            buffer.put(`<table class="table">`);
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
            
            prepareFooter(buffer);
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/search", (ref HTTPRequest req)
        {
            import std.datetime.stopwatch : StopWatch;
            
            string query = req.param("q");
            if (query == null)
                throw new HttpServerException(400, "Bad Request", req);
            
            string escaped = escapeHtml(query);
            
            StopWatch sw;
            sw.start();
            SearchResult[] results = search(query);
            sw.stop();
            
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(32 * 1024);
            
            prepareHeader(buffer, "Search | OEDB", ActiveTab.none, escaped);
            
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
                    buffer.put(`</div>`);
                    
                    if (result.needle)
                    {
                        buffer.writef(`<p>%s<u>%s</u>%s</p>`, result.pre, result.needle, result.post);
                    }
                    
                    buffer.put(`</article>`);
                } // foreach results
            }
            else
            {
                buffer.put(`<h3>No results found.</h3>`);
            }
            
            prepareFooter(buffer);
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/windows/header/:header", (ref HTTPRequest req)
        {
            string *qheader = "header" in req.params;
            if (qheader == null)
                throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);
            
            WindowsHeader winheader = databaseWindowsHeader( *qheader );
            if (winheader.name == string.init)
                throw new HttpServerException(HTTPStatus.notFound, HTTPMsg.notFound, req);
            
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(8 * 1024);
            
            prepareHeader(buffer, format("%s | OEDB", winheader.name), ActiveTab.windows);
            
            buffer.writef(
                `<p><a href="/windows/">Windows</a> / <a href="/windows/headers">Headers</a> / %s</p>`, winheader.key);
            buffer.writef(`<h1>%s</h1>`, winheader.name);
            buffer.writef(`<p>%s</p>`, winheader.description);
            buffer.put(`<h2>Associated Error Codes</h2>`);
            buffer.put(`<p>Below is a list of error codes found for this header.</p>`);
            buffer.put(`<table>`);
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
            
            prepareFooter(buffer);
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        .addRoute("GET", "/windows/module/:module", (ref HTTPRequest req)
        {
            string *qmodule = "module" in req.params;
            if (qmodule == null)
                throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);
            
            WindowsModule mod = databaseWindowsModule(*qmodule);
            if (mod.name == string.init)
                throw new HttpServerException(HTTPStatus.notFound, HTTPMsg.notFound, req);
            
            scope OutBuffer buffer = new OutBuffer;
            buffer.reserve(8 * 1024);
            
            prepareHeader(buffer, format("%s | OEDB", mod.name), ActiveTab.none);
            
            buffer.writef(`<p><a href="/windows/">Windows</a> / <a href="/windows/modules">Modules</a> / %s</p>`, mod.name);
            buffer.writef(`<h1>%s</h1>`, mod.name);
            buffer.writef(`<p>%s</p>`, mod.description);
            
            buffer.put(`<h2>Associated Error Codes</h2>`);
            buffer.put(`<p>Below lists error codes and symbolic names found for this module.</p>`);
            
            buffer.put(`<table>`);
            buffer.put(`<thead><tr><th>Code</th><th>Description</th></tr></thead>`);
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
                    `<td>%s</td>`~
                    `</tr>`,
                    formal, formal, err.message
                );
            }
            buffer.put(`</tbody>`);
            buffer.put(`<tfoot>`);
            buffer.writef(`<tr><td colspan="2">%s %s</td></tr>`, count, plural(count,"entry","entries"));
            buffer.put(`</tfoot>`);
            buffer.put(`</table>`);
            
            prepareFooter(buffer);
            
            req.reply(200, buffer.toBytes(), "text/html");
            return REQUEST_OK;
        })
        //
        // pub content
        // remember, FS stuff in vibe-d ballooned memory usage in problematic ways
        //
        .addRoute("GET", "/favicon.png", (ref HTTPRequest req)
        {
            req.reply(200, buffer_favicon_png, "image/png");
            return REQUEST_OK;
        })
        .addRoute("GET", "/theme.js", (ref HTTPRequest req)
        {
            req.reply(200, buffer_theme_js, "text/javascript");
            return REQUEST_OK;
        })
        .addRoute("GET", "/main.css", (ref HTTPRequest req)
        {
            req.reply(200, buffer_main_css, "text/css");
            return REQUEST_OK;
        })
        .addRoute("GET", "/chota.min.css", (ref HTTPRequest req)
        {
            req.reply(200, buffer_chota_min_css, "text/css");
            return REQUEST_OK;
        })
        .addRoute("GET", "/humans.txt", (ref HTTPRequest req)
        {
            req.reply(200, buffer_humans_txt, "text/plain");
            return REQUEST_OK;
        })
        .addRoute("GET", "/robots.txt", (ref HTTPRequest req)
        {
            req.reply(200, buffer_robots_txt, "text/plain");
            return REQUEST_OK;
        })
        .addRoute("GET", "/noscript.css", (ref HTTPRequest req)
        {
            req.reply(200, buffer_noscript_css, "text/plain");
            return REQUEST_OK;
        })
    ;
    
    http.start(port);
    
    writeln("Listening on port ", port);
    
    while (true)
    {
        readln;
    }
    
    return 0;
}