module hoster.main;

import std.compiler : version_major, version_minor;
import std.format;
import std.stdio;
import std.getopt;
import std.string : toLower;
import motoori, database;
import extra.windows;

import vibe.http.common;
import vibe.http.server;
import vibe.http.router;
import vibe.http.fileserver;
import vibe.core.log;
import vibe.core.core;

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

/// Used to modify page settings
struct PageSettings
{
    ActiveTab tab;
    const(char)[] title; // for tab
}

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
    LogLevel loglevel = LogLevel.info;
    try
    {
        optres = getopt(args, config.caseSensitive,
        "from-folder",  "Load data from folder (default='data')", &odatafolder,
        "loglevel",     "Set log level", &loglevel,
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
    
    setLogLevel(loglevel);
    
    databaseLoadFromFolder(odatafolder);
    
    scope HTTPFileServerSettings fileopts = new HTTPFileServerSettings();
    fileopts.options = HTTPFileServerOption.none;
    
    scope HTTPServerSettings settings = new HTTPServerSettings;
    settings.port = port;
    settings.errorPageHandler =
        (HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo error) {
        char[512] buf = void;
        string t = cast(string)sformat(buf[], "%d - %s | OEDB", error.code, error.message);
        PageSettings page = PageSettings(ActiveTab.none, t);
        res.render!("error.dt", page, req, error);
    };
    if (all == false) // default is [ "0.0.0.0", "::" ]
        settings.bindAddresses = [ "127.0.0.1" ];
    
    // Reading it once into memory to reduce I/O and load times
    ubyte[] buffer_chota_min_css = cast(ubyte[])readAll( "pub/chota.min.css" );
    ubyte[] buffer_favicon_png   = cast(ubyte[])readAll( "pub/favicon.png" );
    ubyte[] buffer_humans_txt    = cast(ubyte[])readAll( "pub/humans.txt" );
    debug {} else ubyte[] buffer_main_css      = cast(ubyte[])readAll( "pub/main.css" );
    ubyte[] buffer_noscript_css  = cast(ubyte[])readAll( "pub/noscript.css" );
    ubyte[] buffer_robots_txt    = cast(ubyte[])readAll( "pub/robots.txt" );
    ubyte[] buffer_theme_js      = cast(ubyte[])readAll( "pub/theme.js" );
    
    scope URLRouter router = new URLRouter()
        // Index
        .get("/", (HTTPServerRequest req, HTTPServerResponse res)
        {
            static immutable PageSettings page = PageSettings(ActiveTab.none, "OEDB");
            DatabaseStatistics dbstats = databaseStatistics();
            res.render!("index.dt", page, dbstats);
        })
        // About site
        .get("/about", (HTTPServerRequest req, HTTPServerResponse res)
        {
            static immutable PageSettings page = PageSettings(ActiveTab.about, "About | OEDB");
            res.render!("about.dt", page, PROJECT_VERSION);
        })
        // Windows list of headers
        .get("/windows/headers", (HTTPServerRequest req, HTTPServerResponse res)
        {
            WindowsHeader[] winheaders = databaseWindowsHeaders();
            PageSettings page = PageSettings(ActiveTab.windows, "Headers | OEDB");
            res.render!("windows-headers.dt", page, winheaders);
        })
        // Windows header details
        .get("/windows/header/:header", (HTTPServerRequest req, HTTPServerResponse res)
        {
            WindowsHeader winheader = databaseWindowsHeader( req.params["header"] );
            if (winheader.name == string.init)
                throw new HTTPStatusException(HTTPStatus.notFound);
            
            PageSettings page = PageSettings(ActiveTab.windows, winheader.name~" | OEDB");
            res.render!("windows-header.dt", page, winheader);
        })
        // Windows list of modules
        .get("/windows/modules", (HTTPServerRequest req, HTTPServerResponse res)
        {
            static immutable PageSettings page = PageSettings(ActiveTab.windows, "Modules | OEDB");
            WindowsModule[] modulelist = databaseWindowsModules();
            res.render!("windows-modules.dt", page, modulelist);
        })
        // Windows module details
        .get("/windows/module/:module", (HTTPServerRequest req, HTTPServerResponse res)
        {
            string paramModule = req.params["module"];
            
            WindowsModule mod = databaseWindowsModule(paramModule);
            if (mod.name == string.init)
                throw new HTTPStatusException(404);
            
            PageSettings page = PageSettings(ActiveTab.windows, mod.name~" | OEDB");
            res.render!("windows-module.dt", page, mod);
        })
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
        // Windows error types and formats
        .get("/windows/error-types", (HTTPServerRequest req, HTTPServerResponse res)
        {
            static immutable PageSettings page = PageSettings(ActiveTab.windows, "Windows Error Types | OEDB");
            immutable(WindowsFacility)[] hresult_facility_list = getWindowsHResultFacilities();
            immutable(WindowsFacility)[] ntstatus_facility_list = getWindowsNtstatusFacilities();
            res.render!("windows-error-types.dt", page, hresult_facility_list, ntstatus_facility_list);
        })
        // Windows main page
        .get("/windows/", (HTTPServerRequest req, HTTPServerResponse res)
        {
            static immutable PageSettings page = PageSettings(ActiveTab.windows, "Windows | OEDB");
            res.render!("windows.dt", page);
        })
        // CRT details
        .get("/crt/:key", (HTTPServerRequest req, HTTPServerResponse res)
        {
            string name = req.params["key"];
            
            DatabaseCrt crt = databaseCrt(name);
            if (crt.name == string.init) // Hack to avoid filtering exceptions
                throw new HTTPStatusException(404);
            
            PageSettings page = PageSettings(ActiveTab.crt, crt.full~" | OEDB");
            res.render!("crt.dt", page, crt);
        })
        // CRT main page
        .get("/crt/", (HTTPServerRequest req, HTTPServerResponse res)
        {
            static immutable PageSettings page = PageSettings(ActiveTab.crt, "C Runtimes | OEDB");
            res.render!("crt-list.dt", page);
        })
        // Search
        .get("/search", (HTTPServerRequest req, HTTPServerResponse res)
        {
            enforceHTTP("q" in req.query, HTTPStatus.badRequest);
            
            string query = req.query["q"];
            
            SearchResult[] results = search(query);
            
            static immutable PageSettings page = PageSettings(ActiveTab.none, "Search | OEDB");
            res.render!("search.dt", page, query, results);
        })
        //.get("/*", serveStaticFiles("pub/", fileopts))
        // HACK: This is to work around the weird sendFile behavior.
        //       sendFile is used by serveStaticFile and serveStaticFiles, but as soon as it is
        //       used, the amount of virtual memory increases by 800-1300 MiB which is a little worrying.
        //
        //       Worrying as in, there are chances these get committed, and if they get committed, it
        //       will bust the amount of memory I gave to the container. Tests with readAllMem alias
        //       only bumps up the allocation up to 30-60 MiB of virtual memory once used, which is
        //       more reassuring for now. With a release build using ldc2, it's only 20 MiB up.
        .get("/chota.min.css", (HTTPServerRequest req, HTTPServerResponse res)
        {
            res.writeBody(buffer_chota_min_css, 200, "text/css");
        })
        .get("/favicon.png", (HTTPServerRequest req, HTTPServerResponse res)
        {
            res.writeBody(buffer_favicon_png, 200, "image/png");
        })
        .get("/humans.txt", (HTTPServerRequest req, HTTPServerResponse res)
        {
            res.writeBody(buffer_humans_txt, 200, "text/plain");
        })
        .get("/main.css", (HTTPServerRequest req, HTTPServerResponse res)
        {
            debug res.writeBody(cast(ubyte[])readAll( "pub/main.css" ), 200, "text/css");
            else  res.writeBody(buffer_main_css, 200, "text/css");
        })
        .get("/noscript.css", (HTTPServerRequest req, HTTPServerResponse res)
        {
            res.writeBody(buffer_noscript_css, 200, "text/css");
        })
        .get("/robots.txt", (HTTPServerRequest req, HTTPServerResponse res)
        {
            res.writeBody(buffer_robots_txt, 200, "text/plain");
        })
        .get("/theme.js", (HTTPServerRequest req, HTTPServerResponse res)
        {
            //res.writeBody(buffer_theme_js, 200, "text/javascript");
            debug res.writeBody(cast(ubyte[])readAll( "pub/theme.js" ), 200, "text/css");
            else  res.writeBody(buffer_main_css, 200, "text/javascript");
        })
    ;
    
    listenHTTP(settings, router);
    return runApplication;
}