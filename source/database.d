module database;

import core.memory : GC;
import std.stdio;
import std.conv;
import std.file;
import std.json;
import std.path;
import std.string : toLower, indexOf;
import std.algorithm.sorting : sort;
import utils : parseCode;

private alias readFile = std.file.read;

// NOTE: All data structures SHOULD NOT have dictionaries
//
//       For purely listing purposes, do not use dictionaries. Dictionary
//       usage is strongly for searching purposes, and these can be found in
//       the caches found later.

// NOTE: Duplicate strings when loading from JSON
//
//       Duplicating strings puts it as its own root reference, to let the GC
//       clean the JSONValue references afterwards.

// For database loader only
private JSONValue readJSON(string path)
{
    // parseJSON already does text encoding enforcement
    return parseJSON(cast(string)readFile(path));
}

/// Load data from base folder
///
/// Params: base = Folder base path
void databaseLoadFromFolder(string base)
{
    // Load CRT entries
    static immutable pathCrt = "crt";
    databaseLoadCrt(buildPath(base, pathCrt, "glibc_amd64.json"));
    databaseLoadCrt(buildPath(base, pathCrt, "msvc_amd64.json"));
    databaseLoadCrt(buildPath(base, pathCrt, "musl_amd64.json"));
    
    // Load Windows header and module entries
    static immutable pathWindows = "windows";
    databaseLoadWindowsHeaders(buildPath(base, pathWindows, "headers.json"));
    databaseLoadWindowsModules(buildPath(base, pathWindows, "modules.json"));
    
    // Make up merged error stuff from Windows headers and modules.
    // 1. Make error entries out of every module error codes
    // 2. Update error entries with their symbolic name if available
    
    // 
    with (statistics) totalMessageCount =
        crtMessageCount + windowsModuleErrorCount;
    
    GC.collect();
    GC.minimize();
}

//
// Windows headers
//

/// Represents a symbolic entry
struct WindowsSymbolic
{
    uint id;        /// Formatted error code
    string origId;  /// Original error code, hexadecimal
    string decId;   /// Error code formatted as decimal
    string key;     /// Lowercase symbolic name for searching
    string name;    /// Symbolic name
    string message; /// Error message
}
/// Represents a Windows header that holds one or more symbolic entries
struct WindowsHeader
{
    string key;     /// Lowercase header name for searching
    string name;    /// Header name
    string description; /// Short description
    WindowsSymbolic[] symbolics; /// List of symbolic entries
}

private void databaseLoadWindowsHeaders(string path)
{
    // Open, read, and parse as JSON
    scope JSONValue j = readJSON(path);
    
    size_t totalSymbolic;
    scope WindowsHeader[] winheaders;
    foreach (ref JSONValue jheader; j["headers"].array)
    {
        WindowsHeader winheader;
        winheader.name        = jheader["name"].str.idup;
        winheader.key         = toLower(winheader.name);
        winheader.description = jheader["description"].str.idup;
        
        foreach (ref JSONValue jsym; jheader["symbolics"].array)
        {
            WindowsSymbolic sym;
            sym.name    = jsym["name"].str.idup;
            sym.key     = toLower(sym.name);
            sym.message = jsym["description"].str.idup;
            sym.origId  = jsym["id"].str.idup;
            sym.decId   = text(sym.id);
            if (parseCode(sym.origId, sym.id) == false)
                stderr.writeln("warning: parsing code '", sym.origId, "' failed");
            
            winheader.symbolics ~= sym;
        }
        
        totalSymbolic += winheader.symbolics.length;
        winheaders ~= winheader;
    }
    
    // Sort array
    // TODO: Find in-place sort
    // returns: SortedRange!(string[], "a < b", SortedRangeOptions.assumeSorted);
    scope auto sorted = sort!("a.key < b.key")(winheaders);
    foreach (ref WindowsHeader winheader; sorted)
    {
        data_windows_headers ~= winheader;
    }
    winheaders = null;
    
    statistics.windowsHeaderCount = data_windows_headers.length;
    statistics.windowsSymbolicCount = totalSymbolic;
    
    GC.collect();
    GC.minimize();
}

// Get a list of Windows headers
WindowsHeader[] databaseWindowsHeaders()
{
    return data_windows_headers;
}

// Get header by its name
WindowsHeader databaseWindowsHeader(string name)
{
    string key = toLower(name);
    
    foreach (ref WindowsHeader winheader; data_windows_headers)
    {
        if (key == winheader.key)
            return winheader;
    }
    
    static immutable WindowsHeader empty;
    return cast()empty;
}

WindowsSymbolic databaseWindowsSymbolicByName(string name, ref WindowsHeader header)
{
    static immutable WindowsHeader emptyhdr;
    static immutable WindowsSymbolic emptysym;
    
    string key = toLower(name);
    
    foreach (ref WindowsHeader winheader; data_windows_headers)
    {
        foreach (ref WindowsSymbolic winsym; winheader.symbolics)
        {
            if (key == winsym.key)
            {
                header = winheader;
                return winsym;
            }
        }
    }
    
    header = cast()emptyhdr;
    return emptysym;
}

//
// Windows modules
//

struct WindowsModuleError
{
    uint id;
    string origId;
    string message;
}
struct WindowsModule
{
    string name;
    string description;
    WindowsModuleError[] messages;
}

private void databaseLoadWindowsModules(string path)
{
    // Open, read, and parse as JSON
    scope JSONValue j = readJSON(path);
    
    // NOTE: Somehow, all the module names are already lowercase
    size_t modmsgcnt;
    WindowsModule[] modules;
    foreach (jmodule; j["modules"].array)
    {
        WindowsModuleError[] errors;
        foreach (ref JSONValue jerror; jmodule["messages"].array)
        {
            WindowsModuleError error;
            error.message = jerror["message"].str.idup;
            error.origId  = jerror["code"].str.idup;
            if (parseCode(error.origId, error.id) == false)
                stderr.writeln("warning: parsing code '", error.origId, "' failed");
            
            errors ~= error;
        }
        
        WindowsModule mod;
        mod.name        = jmodule["name"].str.idup;
        mod.description = jmodule["description"].str.idup;
        mod.messages    = errors;
        modules ~= mod;
        modmsgcnt += errors.length;
    }
    
    // Sort array
    // TODO: Find in-place sort
    scope auto sorted = sort!("a.name < b.name")(modules);
    foreach (ref WindowsModule winmod; sorted)
    {
        data_windows_modules ~= winmod;
    }
    modules = null;
    
    statistics.windowsModuleCount = data_windows_modules.length;
    statistics.windowsModuleErrorCount = modmsgcnt;
    
    GC.collect();
    GC.minimize();
}

// Get all modules
WindowsModule[] databaseWindowsModules()
{
    return data_windows_modules;
}

// Get module by its name
WindowsModule databaseWindowsModule(string key)
{
    foreach (ref WindowsModule mod; data_windows_modules)
    {
        if (mod.name == key)
            return mod;
    }
    
    static immutable WindowsModule empty;
    return cast()empty;
}

//
// CRT facilities
//

struct DatabaseCrtMessage
{
    int code;
    string origId;
    string message;
}
struct DatabaseCrt
{
    string name; // TODO: Rename to `key`
    string full; /// Full name
    string arch;
    DatabaseCrtMessage[] messages;
}

private void databaseLoadCrt(string path)
{
    // Open, read, and parse as JSON
    scope JSONValue j = readJSON(path);
    
    // Buildup the entry
    // All these entries are mandatory, so crash if it's missing
    DatabaseCrt crt;
    crt.name = j["name"].str.idup;
    crt.full = j["full"].str.idup;
    crt.arch = j["arch"].str.idup;
    foreach (jmsg; j["messages"].array)
    {
        DatabaseCrtMessage msg = void;
        msg.code = cast(int)jmsg["code"].integer;
        msg.origId  = text(msg.code);
        msg.message = jmsg["message"].str.idup;
        crt.messages ~= msg;
    }
    
    // Add it to the list
    data_crt ~= crt;
    statistics.crtMessageCount += crt.messages.length;
}

// List everything
DatabaseCrt[] databaseListCrt()
{
    return data_crt;
}

// Get CRT instance from a key, typically its shortname
DatabaseCrt databaseCrt(string key)
{
    foreach (ref crt; data_crt)
    {
        if (crt.name == key)
            return crt;
    }
    
    // faster than rethrowing another exception
    static immutable DatabaseCrt empty;
    return cast()empty;
}

//
// Misc
//

struct DatabaseStatistics
{
    size_t crtMessageCount;
    
    size_t windowsHeaderCount;
    size_t windowsModuleCount;
    size_t windowsSymbolicCount; // symbolic names + code
    size_t windowsModuleErrorCount; // errors from module
    
    size_t totalMessageCount;
}
DatabaseStatistics databaseStatistics()
{
    return statistics;
}

//
// Search facilities
//

/// Global search results
struct SearchResult
{
    const(char)[] type;     /// symbolic/header/module type string
    const(char)[] origId;   /// original code
    const(char)[] name;     /// header/module name string
    
    // Description
    const(char)[] pre;      /// pre-needle snippet
    const(char)[] needle;   /// needle
    const(char)[] post;     /// post-needle snippet
}

/// How many characters to snip before and after needle
private enum SNIPPET_PADDING = 40;
// TODO: This should be a limit per "type" (module/header/crt) and not a Grand Total
/// How many results in total
private enum SEARCH_LIMIT = 50;

private const(char)[] preSnip(const(char)[] text, const(char)[] input, ptrdiff_t i) {
    if (i == 0)
        return "";
    return i >= SNIPPET_PADDING ? "..." ~ text[i - SNIPPET_PADDING..i] : text[0..i];
}
private const(char)[] needleSnip(const(char)[] text, const(char)[] input, ptrdiff_t i) {
    return text[i..i + input.length];
}
private const(char)[] postSnip(const(char)[] text, const(char)[] input, ptrdiff_t i) {
    if (i >= text.length)
        return "";
    i += input.length;
    size_t i2 = i + SNIPPET_PADDING;
    return i2 < text.length ? text[i..i2] ~ "..." : text[i..$];
}

SearchResult[] search(string input)
{
    uint code = void;
    bool iscode = parseCode(input, code);
    
    SearchResult[] results;
    
    if (input.length == 0)
        return results;
    
    // Take reference code/message reference and compare it with
    // local code/input
    bool process(uint refcode, string reforigid, string refdesc,
        string type,    // winmodule, winsymbol, crt)
        string name,    // Name of module, header, or crt
    )
    {
        bool found;
        ptrdiff_t i = void;
        
        if (iscode)
        {
            found = code == refcode;
        }
        else if (refdesc) // Typically descriptions of windows modules/headers
        {
            i = indexOf(refdesc, input, CaseSensitive.no);
            if (i < 0)
                return false;
            
            found = true;
        }
        else return false; // Nothing we can do
        
        if (found)
        {
            const(char)[] msgpre;
            const(char)[] msgneedle;
            const(char)[] msgpost;
            
            if (iscode == false)
            {
                msgpre = preSnip(refdesc, input, i);
                msgneedle = needleSnip(refdesc, input, i);
                msgpost = postSnip(refdesc, input, i);
            }
            
            results ~= SearchResult(type, reforigid, name,
                 msgpre, msgneedle, msgpost);
        }
        
        return results.length >= SEARCH_LIMIT;
    }
    
    // check modules first, a code or message description is more ambiguous than symbolic names
    // for code, check error id
    // for text, check in messages
    foreach (ref winmodule; data_windows_modules)
    foreach (ref err; winmodule.messages)
    {
        with (err)
        if (process(id, origId, message, "windows-module", winmodule.name))
            return results;
    }
    
    // for code, check error id
    // for text, check symbolic names and descriptions
    foreach (ref winheader; data_windows_headers)
    foreach (ref winsymbol; winheader.symbolics)
    {
        with (winsymbol)
        if (process(id, name, message, "windows-symbol", winheader.name))
            return results;
    }
    
    // for code, check error code
    // for text, check message
    foreach (ref crt; data_crt)
    foreach (ref err; crt.messages)
    {
        if (process(err.code, err.origId, err.message, "crt", crt.name))
            return results;
    }
    
    return results;
}

struct SearchWindowsModuleResult
{
    WindowsModule module_;
    WindowsModuleError error;
}

// Get associated modules by error code
SearchWindowsModuleResult[] searchWindowsModulesByCode(uint errcode)
{
    SearchWindowsModuleResult[] results;
    foreach (ref module_; data_windows_modules)
    {
        foreach (ref errmsg; module_.messages)
        {
            if (errcode == errmsg.id)
            {
                SearchWindowsModuleResult result;
                result.module_ = module_;
                result.error   = errmsg;
                results ~= result;
            }
        }
    }
    return results;
}

struct SearchWindowsHeaderResult
{
    WindowsHeader header;
    WindowsSymbolic error;
}

// Get associated headers by error code
SearchWindowsHeaderResult[] searchWindowsHeadersByCode(uint errcode)
{
    SearchWindowsHeaderResult[] results;
    foreach (ref header; data_windows_headers)
    {
        foreach (ref sym; header.symbolics)
        {
            if (errcode == sym.id)
            {
                SearchWindowsHeaderResult result;
                result.header = header;
                result.error  = sym;
                results ~= result;
            }
        }
    }
    return results;
}

private:
__gshared:

DatabaseStatistics statistics;

// Data, to make it easier to iterate over (e.g., listings)
DatabaseCrt[] data_crt;
WindowsHeader[] data_windows_headers;
WindowsModule[] data_windows_modules;

// Cache, to make it easier to search from data
//WindowsError[string] cache_windows; // Module+Header code merged
