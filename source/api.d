/// JSON API, served under /api/v1.
///
/// Replies are written straight into the reply buffer instead of going through
/// std.json: the listing endpoints run into the megabytes, and building a
/// JSONValue tree for them would hold a second copy of the database in memory
/// for the duration of the request.
module api;

import std.conv : text;
import std.datetime.systime : SysTime;
import std.functional : toDelegate;
import core.time : Duration;
import database;
import extra.windows;
import motoori : PROJECT_VERSION;
import utils : parseCode, sformatWindowsCodeURL, collectPeriodically;
import ddhttpd;

private:

enum string API_PREFIX = "/api/";

// Data only changes when a scan is loaded, which needs a restart anyway.
enum const(char) *API_CACHE_CONTROL = "public, max-age=3600";

// A reply that outgrows its buffer is realloc'd and copied, and the listings
// run into the megabytes, so they size themselves off the text they will hold.
// This covers what surrounds that text in one entry: the field names, the
// quoting, the code forms, and the release list.
enum ENTRY_OVERHEAD = 192;

//
// JSON writing
//

void putString(ref HTTPReply buffer, const(char)[] text)
{
    buffer.put('"');
    putStringBody(buffer, text);
    buffer.put('"');
}

/// Escaped string contents, without the quotes, for text assembled in pieces.
void putStringBody(ref HTTPReply buffer, const(char)[] text)
{
    foreach (char c; text)
    {
        switch (c) {
        case '"':  buffer.put(`\"`); break;
        case '\\': buffer.put(`\\`); break;
        case '\b': buffer.put(`\b`); break;
        case '\f': buffer.put(`\f`); break;
        case '\n': buffer.put(`\n`); break;
        case '\r': buffer.put(`\r`); break;
        case '\t': buffer.put(`\t`); break;
        default:
            // Module messages carry the odd stray control character
            if (c < 0x20)
                buffer.writef(`\u%04x`, cast(uint)c);
            else
                buffer.put(c);
            break;
        }
    }
}

void putField(ref HTTPReply buffer, string name, const(char)[] value)
{
    buffer.writef(`"%s":`, name);
    putString(buffer, value);
}

/// Emit a string field, or null when there is nothing to say.
void putFieldOrNull(ref HTTPReply buffer, string name, const(char)[] value)
{
    if (value.length)
        putField(buffer, name, value);
    else
        buffer.writef(`"%s":null`, name);
}

// Release keys an entry was found in, as an array of tags
void putReleases(ref HTTPReply buffer, WindowsOSSet os)
{
    buffer.put('[');
    bool comma;
    foreach (ref WindowsRelease release; databaseWindowsReleases())
    {
        if ((os & release.bit) == 0)
            continue;

        if (comma) buffer.put(',');
        putString(buffer, release.key);
        comma = true;
    }
    buffer.put(']');
}

void putFacility(ref HTTPReply buffer, ushort id, ref WindowsFacility facility)
{
    buffer.writef(`{"id":%u,`, id);
    putFieldOrNull(buffer, "name", facility.name);
    buffer.put(',');
    putFieldOrNull(buffer, "description", facility.description);
    buffer.put('}');
}

// Both readings of a code, mirroring what /windows/code/:code shows
void putDecoding(ref HTTPReply buffer, uint code)
{
    HResultLayout hr = hresultLayout(code);
    WindowsFacility hrfacility = hresultFacilityById(hr.facility);

    buffer.writef(
        `"hresult":{"severity":%s,"reserved":%s,"customer":%s,"ntstatus":%s,"reservedX":%s,"facility":`,
        hr.severity, hr.reserved, hr.customer, hr.ntstatus, hr.reservedX);
    putFacility(buffer, hr.facility, hrfacility);
    buffer.writef(`,"code":%u},`, hr.code);

    NtstatusLayout nt = ntstatusLayout(code);
    WindowsFacility ntfacility = ntstatusFacilityById(nt.facility);

    buffer.writef(
        `"ntstatus":{"severity":%u,"severityName":"%s","customer":%s,"reserved":%s,"facility":`,
        nt.severity, ntstatusSeverityName(nt.severity), nt.customer, nt.reserved);
    putFacility(buffer, nt.facility, ntfacility);
    buffer.writef(`,"code":%u}`, nt.code);
}

// Identity of a code: the three forms it gets written in, plus the format it
// most plausibly belongs to
void putCodeIdentity(ref HTTPReply buffer, uint code)
{
    char[32] hexbuf = void;
    buffer.writef(`"code":%u,"hex":"%s","signed":%d,"kind":"%s"`,
        code, sformatWindowsCodeURL(hexbuf, code), cast(int)code, text(windowsCodeKind(code)));
}

void putModuleMatches(ref HTTPReply buffer, SearchWindowsModuleResult[] results)
{
    buffer.put('[');
    foreach (size_t i, ref SearchWindowsModuleResult result; results)
    {
        if (i) buffer.put(',');
        buffer.put('{');
        putField(buffer, "module", result.module_.name);
        buffer.put(',');
        putField(buffer, "message", result.error.message);
        buffer.put(`,"releases":`);
        putReleases(buffer, result.error.os);
        buffer.put('}');
    }
    buffer.put(']');
}

void putHeaderMatches(ref HTTPReply buffer, SearchWindowsHeaderResult[] results)
{
    buffer.put('[');
    foreach (size_t i, ref SearchWindowsHeaderResult result; results)
    {
        if (i) buffer.put(',');
        buffer.put('{');
        putField(buffer, "header", result.header.name);
        buffer.put(',');
        putField(buffer, "headerKey", result.header.key);
        buffer.put(',');
        putField(buffer, "symbolic", result.error.name);
        buffer.put(',');
        putFieldOrNull(buffer, "description", result.error.message);
        buffer.put('}');
    }
    buffer.put(']');
}

// An article of the driver documentation. The body is left out: it runs to
// tens of kilobytes of HTML, which the site is the place for.
void putDoc(ref HTTPReply buffer, ref WindowsDoc doc)
{
    buffer.put('{');
    putField(buffer, "kind", doc.kind);
    buffer.put(',');
    putField(buffer, "symbolic", doc.name);
    buffer.put(',');
    putField(buffer, "title", doc.title);
    buffer.writef(`,"value":%u,`, doc.id);
    putFieldOrNull(buffer, "description", doc.description);
    buffer.put(',');
    putFieldOrNull(buffer, "header", doc.header);
    buffer.put(',');
    putFieldOrNull(buffer, "url", doc.url);
    buffer.put('}');
}

void putDocMatches(ref HTTPReply buffer, WindowsDoc[] docs)
{
    buffer.put('[');
    foreach (size_t i, ref WindowsDoc doc; docs)
    {
        if (i) buffer.put(',');
        putDoc(buffer, doc);
    }
    buffer.put(']');
}

void putWin32Matches(ref HTTPReply buffer, Win32Result[] results)
{
    buffer.put('[');
    foreach (size_t i, ref Win32Result result; results)
    {
        if (i) buffer.put(',');
        buffer.put('{');
        putField(buffer, "listing", result.doc.key);
        buffer.put(',');
        putField(buffer, "title", result.doc.title);
        buffer.put(',');
        putFieldOrNull(buffer, "header", result.doc.header);
        buffer.put(',');
        putField(buffer, "symbolic", result.entry.name);
        buffer.put(',');
        // A return value or hit test result is documented without one
        if (result.entry.origId.length)
            buffer.writef(`"code":%u,`, result.entry.id);
        else
            buffer.put(`"code":null,`);
        putFieldOrNull(buffer, "description", result.entry.description);
        buffer.put(',');
        putFieldOrNull(buffer, "url", result.doc.url);
        buffer.put('}');
    }
    buffer.put(']');
}

int reply(ref HTTPRequest req, ref HTTPReply buffer)
{
    req.addHeader("Cache-Control", API_CACHE_CONTROL);
    // Read-only public data, so browser clients get to use it directly
    req.addHeader("Access-Control-Allow-Origin", "*");
    req.reply(200, buffer, "application/json");
    collectPeriodically();
    return REQUEST_OK;
}

//
// Endpoints
//

int apiIndex(ref HTTPRequest req)
{
    HTTPReply buffer = HTTPReply.create(1024);
    buffer.put(`{`);
    putField(buffer, "service", "Online Error Database");
    buffer.put(',');
    putField(buffer, "version", PROJECT_VERSION);
    buffer.put(`,"api":1,`);
    putField(buffer, "documentation", "/api");
    buffer.put(`,"endpoints":[`);
    buffer.put(`"/api/v1/stats",`);
    buffer.put(`"/api/v1/search?q=",`);
    buffer.put(`"/api/v1/windows/code/{code}",`);
    buffer.put(`"/api/v1/windows/error/{symbolic}",`);
    buffer.put(`"/api/v1/windows/headers",`);
    buffer.put(`"/api/v1/windows/header/{header}",`);
    buffer.put(`"/api/v1/windows/modules",`);
    buffer.put(`"/api/v1/windows/module/{module}",`);
    buffer.put(`"/api/v1/windows/releases",`);
    buffer.put(`"/api/v1/crt",`);
    buffer.put(`"/api/v1/crt/{runtime}"`);
    buffer.put(`]}`);
    return reply(req, buffer);
}

int apiStats(ref HTTPRequest req)
{
    DatabaseStatistics stats = databaseStatistics();

    HTTPReply buffer = HTTPReply.create(512);
    buffer.put('{');
    putField(buffer, "version", PROJECT_VERSION);
    buffer.put(',');
    putFieldOrNull(buffer, "updated", databaseUpdated());
    buffer.writef(
        `,"messages":%u,"windowsHeaders":%u,"windowsSymbolics":%u,`~
        `"windowsModules":%u,"windowsModuleMessages":%u,"windowsDocs":%u,`~
        `"win32Listings":%u,"win32Constants":%u,"crtMessages":%u}`,
        stats.totalMessageCount, stats.windowsHeaderCount, stats.windowsSymbolicCount,
        stats.windowsModuleCount, stats.windowsModuleErrorCount, stats.windowsDocCount,
        stats.win32DocCount, stats.win32EntryCount, stats.crtMessageCount);
    return reply(req, buffer);
}

// W3C datetime at second resolution, same form the sitemap uses
const(char)[] databaseUpdated()
{
    SysTime stamp = databaseTimestamp();
    if (stamp == SysTime.init)
        return null;

    stamp = stamp.toUTC();
    stamp.fracSecs = Duration.zero;
    return stamp.toISOExtString();
}

int apiWindowsCode(ref HTTPRequest req)
{
    string qcode = req.params["code"];
    uint code = void;
    if (parseCode(qcode, code) == false)
        throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);

    SearchWindowsHeaderResult[] headers = searchWindowsHeadersByCode(code);
    SearchWindowsModuleResult[] modules = searchWindowsModulesByCode(code);
    // Both lists hold only what no header defines, as on the code page: the
    // rest is already an entry of "headers", under the header to trust for it.
    WindowsDoc[] docs = databaseWindowsDocsByCode(code);
    Win32Result[] win32 = databaseWin32ByCode(code);

    HTTPReply buffer = HTTPReply.create(16 * 1024);
    buffer.put('{');
    putCodeIdentity(buffer, code);
    buffer.put(',');
    putDecoding(buffer, code);
    buffer.put(`,"modules":`);
    putModuleMatches(buffer, modules);
    buffer.put(`,"headers":`);
    putHeaderMatches(buffer, headers);
    buffer.put(`,"documentation":`);
    putDocMatches(buffer, docs);
    buffer.put(`,"win32":`);
    putWin32Matches(buffer, win32);
    buffer.put('}');

    return reply(req, buffer);
}

int apiWindowsError(ref HTTPRequest req)
{
    string qsymbol = req.params["symbol"];
    if (qsymbol.length == 0)
        throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);

    // The three places a name can live, same as the symbolic page: a header
    // dump, an article of the driver documentation, or a Win32 code listing.
    WindowsHeader winheader = void;
    WindowsSymbolic winsymbol = databaseWindowsSymbolicByName(qsymbol, winheader);
    WindowsDoc windoc = databaseWindowsDocByName(qsymbol);
    Win32Result[] win32 = databaseWin32ByName(qsymbol);

    if (winsymbol.name == string.init && windoc.name == string.init && win32.length == 0)
        throw new HttpServerException(HTTPStatus.notFound, HTTPMsg.notFound, req);

    string name = winsymbol.name;
    string description = winsymbol.message;
    uint code = winsymbol.id;
    // A problem code is an ordinal of the Device Manager, not an error code,
    // and a name the documentation lists without a value has none either
    bool hascode = winsymbol.name != string.init;

    if (windoc.name.length)
    {
        if (name.length == 0)
            name = windoc.name;
        if (description.length == 0)
            description = windoc.description;
        if (hascode == false && windoc.kind == "bugcheck")
        {
            code = windoc.id;
            hascode = true;
        }
    }

    foreach (ref Win32Result result; win32)
    {
        if (name.length == 0)
            name = result.entry.name;
        if (description.length == 0)
            description = result.entry.description;
        if (hascode == false && result.entry.origId.length)
        {
            code = result.entry.id;
            hascode = true;
        }
    }

    SearchWindowsModuleResult[] modules = hascode ?
        searchWindowsModulesByCode(code) : null;

    size_t reserve = 8 * 1024;
    foreach (ref Win32Result result; win32)
        reserve += result.entry.description.length + ENTRY_OVERHEAD;

    HTTPReply buffer = HTTPReply.create(reserve);
    buffer.put('{');
    putField(buffer, "symbolic", name);
    buffer.put(',');
    if (hascode)
        putCodeIdentity(buffer, code);
    else
        buffer.put(`"code":null,"hex":null,"signed":null,"kind":null`);
    buffer.put(',');
    putFieldOrNull(buffer, "description", description);
    if (winsymbol.name != string.init)
    {
        buffer.put(`,"header":{`);
        putField(buffer, "key", winheader.key);
        buffer.put(',');
        putField(buffer, "name", winheader.name);
        buffer.put(`}`);
    }
    else buffer.put(`,"header":null`);
    if (hascode)
    {
        buffer.put(',');
        putDecoding(buffer, code);
    }
    buffer.put(`,"modules":`);
    putModuleMatches(buffer, modules);
    buffer.put(`,"documentation":`);
    if (windoc.name.length)
        putDoc(buffer, windoc);
    else
        buffer.put("null");
    buffer.put(`,"win32":`);
    putWin32Matches(buffer, win32);
    buffer.put('}');

    return reply(req, buffer);
}

int apiWindowsHeaders(ref HTTPRequest req)
{
    WindowsHeader[] headers = databaseWindowsHeaders();

    size_t reserve = 1024;
    foreach (ref WindowsHeader header; headers)
        reserve += header.key.length + header.name.length +
            header.description.length + ENTRY_OVERHEAD;

    HTTPReply buffer = HTTPReply.create(reserve);
    buffer.writef(`{"count":%u,"headers":[`, headers.length);
    foreach (size_t i, ref WindowsHeader header; headers)
    {
        if (i) buffer.put(',');
        buffer.put('{');
        putField(buffer, "key", header.key);
        buffer.put(',');
        putField(buffer, "name", header.name);
        buffer.put(',');
        putFieldOrNull(buffer, "description", header.description);
        buffer.writef(`,"symbolics":%u}`, header.symbolics.length);
    }
    buffer.put(`]}`);
    return reply(req, buffer);
}

int apiWindowsHeader(ref HTTPRequest req)
{
    string name = req.params["header"];
    if (name.length == 0)
        throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);

    WindowsHeader header = databaseWindowsHeader(name);
    if (header.name == string.init)
        throw new HttpServerException(HTTPStatus.notFound, HTTPMsg.notFound, req);

    size_t reserve = 1024 + header.description.length;
    foreach (ref WindowsSymbolic sym; header.symbolics)
        reserve += sym.name.length + sym.message.length + ENTRY_OVERHEAD;

    HTTPReply buffer = HTTPReply.create(reserve);
    buffer.put('{');
    putField(buffer, "key", header.key);
    buffer.put(',');
    putField(buffer, "name", header.name);
    buffer.put(',');
    putFieldOrNull(buffer, "description", header.description);
    buffer.writef(`,"count":%u,"symbolics":[`, header.symbolics.length);
    foreach (size_t i, ref WindowsSymbolic sym; header.symbolics)
    {
        if (i) buffer.put(',');
        buffer.put('{');
        putField(buffer, "symbolic", sym.name);
        buffer.put(',');
        putCodeIdentity(buffer, sym.id);
        buffer.put(',');
        putFieldOrNull(buffer, "description", sym.message);
        buffer.put('}');
    }
    buffer.put(`]}`);

    return reply(req, buffer);
}

int apiWindowsModules(ref HTTPRequest req)
{
    WindowsModule[] modules = databaseWindowsModules();

    size_t reserve = 1024;
    foreach (ref WindowsModule mod; modules)
        reserve += mod.name.length + mod.description.length + ENTRY_OVERHEAD;

    HTTPReply buffer = HTTPReply.create(reserve);
    buffer.writef(`{"count":%u,"modules":[`, modules.length);
    foreach (size_t i, ref WindowsModule mod; modules)
    {
        if (i) buffer.put(',');
        buffer.put('{');
        putField(buffer, "name", mod.name);
        buffer.put(',');
        putFieldOrNull(buffer, "description", mod.description);
        buffer.put(`,"releases":`);
        putReleases(buffer, mod.os);
        buffer.writef(`,"messages":%u}`, mod.messages.length);
    }
    buffer.put(`]}`);

    return reply(req, buffer);
}

int apiWindowsModule(ref HTTPRequest req)
{
    string name = req.params["module"];
    if (name.length == 0)
        throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);

    WindowsModule mod = databaseWindowsModule(name);
    if (mod.name == string.init)
        throw new HttpServerException(HTTPStatus.notFound, HTTPMsg.notFound, req);

    size_t reserve = 1024 + mod.name.length + mod.description.length;
    foreach (ref WindowsModuleError err; mod.messages)
        reserve += err.message.length + ENTRY_OVERHEAD;

    HTTPReply buffer = HTTPReply.create(reserve);
    buffer.put('{');
    putField(buffer, "name", mod.name);
    buffer.put(',');
    putFieldOrNull(buffer, "description", mod.description);
    buffer.put(`,"releases":`);
    putReleases(buffer, mod.os);
    buffer.writef(`,"count":%u,"messages":[`, mod.messages.length);
    foreach (size_t i, ref WindowsModuleError err; mod.messages)
    {
        if (i) buffer.put(',');
        buffer.put('{');
        putCodeIdentity(buffer, err.id);
        buffer.put(',');
        putField(buffer, "message", err.message);
        buffer.put(`,"releases":`);
        putReleases(buffer, err.os);
        buffer.put('}');
    }
    buffer.put(`]}`);

    return reply(req, buffer);
}

int apiWindowsReleases(ref HTTPRequest req)
{
    WindowsRelease[] releases = databaseWindowsReleases();

    HTTPReply buffer = HTTPReply.create(2048);
    buffer.writef(`{"count":%u,"releases":[`, releases.length);
    foreach (size_t i, ref WindowsRelease release; releases)
    {
        if (i) buffer.put(',');
        buffer.put('{');
        putField(buffer, "key", release.key);
        buffer.put(',');
        putField(buffer, "name", release.name);
        buffer.put(',');
        putFieldOrNull(buffer, "build", release.build);
        buffer.writef(`,"modules":%u,"messages":%u}`, release.moduleCount, release.messageCount);
    }
    buffer.put(`]}`);
    return reply(req, buffer);
}

int apiCrtList(ref HTTPRequest req)
{
    DatabaseCrt[] runtimes = databaseListCrt();

    HTTPReply buffer = HTTPReply.create(1024);
    buffer.writef(`{"count":%u,"runtimes":[`, runtimes.length);
    foreach (size_t i, ref DatabaseCrt crt; runtimes)
    {
        if (i) buffer.put(',');
        buffer.put('{');
        putField(buffer, "key", crt.name);
        buffer.put(',');
        putField(buffer, "name", crt.full);
        buffer.put(',');
        putField(buffer, "arch", crt.arch);
        buffer.writef(`,"messages":%u}`, crt.messages.length);
    }
    buffer.put(`]}`);
    return reply(req, buffer);
}

int apiCrt(ref HTTPRequest req)
{
    string key = req.params["runtime"];
    if (key.length == 0)
        throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);

    DatabaseCrt crt = databaseCrt(key);
    if (crt.name == string.init)
        throw new HttpServerException(HTTPStatus.notFound, HTTPMsg.notFound, req);

    size_t reserve = 1024;
    foreach (ref DatabaseCrtMessage msg; crt.messages)
        reserve += msg.message.length + ENTRY_OVERHEAD;

    HTTPReply buffer = HTTPReply.create(reserve);
    buffer.put('{');
    putField(buffer, "key", crt.name);
    buffer.put(',');
    putField(buffer, "name", crt.full);
    buffer.put(',');
    putField(buffer, "arch", crt.arch);
    buffer.writef(`,"count":%u,"messages":[`, crt.messages.length);
    foreach (size_t i, ref DatabaseCrtMessage msg; crt.messages)
    {
        if (i) buffer.put(',');
        buffer.writef(`{"code":%d,`, msg.code);
        putField(buffer, "message", msg.message);
        buffer.put('}');
    }
    buffer.put(`]}`);

    return reply(req, buffer);
}

// Page a result points at, so a client can link back to the site
void putResultURL(ref HTTPReply buffer, ref SearchResult result)
{
    import std.format : sformat;

    char[256] urlbuf = void;
    const(char)[] url = void;
    final switch (result.type) {
    case "windows-module":
        url = sformat(urlbuf, "/windows/code/%s", result.origId);
        break;
    case "windows-symbol", "windows-win32", "windows-doc":
        url = sformat(urlbuf, "/windows/error/%s", result.origId);
        break;
    case "crt":
        url = sformat(urlbuf, "/crt/%s#%s", result.name, result.origId);
        break;
    }
    putField(buffer, "url", url);
}

int apiSearch(ref HTTPRequest req)
{
    string query = req.param("q");
    if (query == null)
        throw new HttpServerException(HTTPStatus.badRequest, HTTPMsg.badRequest, req);

    SearchResult[] results = search(query);

    HTTPReply buffer = HTTPReply.create(16 * 1024);
    buffer.put('{');
    putField(buffer, "query", query);
    buffer.writef(`,"count":%u,"results":[`, results.length);
    foreach (size_t i, ref SearchResult result; results)
    {
        if (i) buffer.put(',');
        buffer.put('{');
        putField(buffer, "type", result.type);
        buffer.put(',');
        putField(buffer, "id", result.origId);
        buffer.put(',');
        putField(buffer, "source", result.name);
        buffer.put(',');
        putResultURL(buffer, result);
        if (result.os)
        {
            buffer.put(`,"releases":`);
            putReleases(buffer, result.os);
        }
        // Code queries match on the code alone and carry no snippet
        if (result.needle.length)
        {
            buffer.put(`,"excerpt":`);
            buffer.put('"');
            if (result.preTruncated) buffer.put(`…`);
            putStringBody(buffer, result.pre);
            putStringBody(buffer, result.needle);
            putStringBody(buffer, result.post);
            if (result.postTruncated) buffer.put(`…`);
            buffer.put('"');
            buffer.put(',');
            putField(buffer, "match", result.needle);
        }
        buffer.put('}');
    }
    buffer.put(`]}`);

    return reply(req, buffer);
}

public:

/// Whether a path belongs to the API, and so must not get an HTML error page.
bool isAPIPath(const(char)[] path)
{
    return path.length >= API_PREFIX.length && path[0..API_PREFIX.length] == API_PREFIX;
}
unittest
{
    assert(isAPIPath("/api/v1/stats"));
    assert(isAPIPath("/api/"));
    assert(isAPIPath("/api") == false); // the documentation page
    assert(isAPIPath("/about") == false);
    assert(isAPIPath("/") == false);
}

/// Reply to a failed API request with the same error shape every endpoint uses.
void replyAPIError(ref HTTPRequest req, int status, const(char)[] message)
{
    HTTPReply buffer = HTTPReply.create(256);
    buffer.writef(`{"error":{"status":%d,`, status);
    putField(buffer, "message", message);
    buffer.put(`}}`);

    req.addHeader("Access-Control-Allow-Origin", "*");
    req.reply(status, buffer, "application/json");
}

/// Add the API routes. Must run after the database is loaded.
HTTPServer addAPIRoutes(HTTPServer http)
{
    return http
        .addRoute("GET", "/api/v1",  toDelegate(&apiIndex))
        .addRoute("GET", "/api/v1/", toDelegate(&apiIndex))
        .addRoute("GET", "/api/v1/stats", toDelegate(&apiStats))
        .addRoute("GET", "/api/v1/search", toDelegate(&apiSearch))
        .addRoute("GET", "/api/v1/windows/releases", toDelegate(&apiWindowsReleases))
        .addRoute("GET", "/api/v1/windows/headers", toDelegate(&apiWindowsHeaders))
        .addRoute("GET", "/api/v1/windows/modules", toDelegate(&apiWindowsModules))
        .addRoute("GET", "/api/v1/windows/header/:header", toDelegate(&apiWindowsHeader))
        .addRoute("GET", "/api/v1/windows/module/:module", toDelegate(&apiWindowsModule))
        .addRoute("GET", "/api/v1/windows/code/:code", toDelegate(&apiWindowsCode))
        .addRoute("GET", "/api/v1/windows/error/:symbol", toDelegate(&apiWindowsError))
        .addRoute("GET", "/api/v1/crt", toDelegate(&apiCrtList))
        .addRoute("GET", "/api/v1/crt/:runtime", toDelegate(&apiCrt))
    ;
}
