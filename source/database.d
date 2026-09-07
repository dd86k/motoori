module database;

import core.memory : GC;
import std.stdio;
import std.file;
import std.path;
import std.format : sformat;
import std.string : toLower;
import std.algorithm.sorting : sort;
import std.datetime.systime : SysTime;
import jsonpull : JSONReader;
import utils : parseCode, toLowerBuf, indexOfFold;

private alias readFile = std.file.read;

// NOTE: All data structures SHOULD NOT have dictionaries
//
//       For purely listing purposes, do not use dictionaries. Dictionary
//       usage is strongly for searching purposes, and these can be found in
//       the caches found later.

//
// String arena
//
// NOTE: Why the loaders do not hand each string to the GC
//
//       Strings read out of a document outlive it, and there is close to a
//       million of them. Allocated one by one they end up scattered across
//       pools, and a pool with even one live object in it can never be returned
//       to the OS, so every transient allocation the load makes gets pinned
//       behind them. Bump-allocating out of dedicated blocks keeps the durable
//       data in pools of its own.

private enum ARENA_BLOCK = 4 * 1024 * 1024;

private __gshared char[] arena_block;
private __gshared size_t arena_used;

/// Copy a string into the arena. Blocks are never freed, so only call this for
/// data that lives as long as the process.
private string arenaDup(const(char)[] str)
{
    if (str.length == 0)
        return null;

    // An outlier would waste most of a block, and is rare enough to hand over
    if (str.length > ARENA_BLOCK / 4)
        return str.idup;

    if (arena_used + str.length > arena_block.length)
    {
        arena_block = (cast(char*)GC.malloc(ARENA_BLOCK, GC.BlkAttr.NO_SCAN))[0..ARENA_BLOCK];
        arena_used = 0;
    }

    char[] dest = arena_block[arena_used .. arena_used + str.length];
    dest[] = str[];
    arena_used += str.length;
    return cast(string)dest;
}

/// ASCII-lowercased copy of a string, into the arena.
private string arenaLower(const(char)[] str)
{
    string dest = arenaDup(str);
    foreach (ref char c; cast(char[])dest)
    {
        if (c >= 'A' && c <= 'Z')
            c += 32;
    }
    return dest;
}

/// Decimal form of a code, into the arena.
private string arenaText(T)(T value)
{
    char[32] buf = void;
    return arenaDup(sformat(buf, "%d", value));
}

// A read only holds until the next one, and a module message that turns out to
// be a duplicate of one an earlier scan already carries must not have cost the
// arena anything, so the merge check runs against these instead.
private __gshared char[] scratch_name;
private __gshared char[] scratch_code;
private __gshared char[] scratch_message;

private const(char)[] hold(ref char[] buffer, const(char)[] str)
{
    if (buffer.length < str.length)
        buffer.length = str.length;

    buffer[0..str.length] = str[];
    return buffer[0..str.length];
}

// For database loader only
private const(char)[] readSource(string path)
{
    SysTime mtime = timeLastModified(path);
    if (mtime > data_timestamp)
        data_timestamp = mtime;

    return cast(const(char)[])readFile(path);
}

// The reader only ever hands out copies, so the document can go the moment its
// walk is done. Waiting for a collection instead would mean holding every scan
// read so far, tens of megabytes of it, for the whole load.
private void releaseSource(const(char)[] source)
{
    GC.free(cast(void*)source.ptr);
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
    string dirWindows = buildPath(base, pathWindows);
    databaseLoadWindowsHeaders(buildPath(dirWindows, "headers.json"));

    // One module scan per OS release (modules-10.json, modules-11.json, ...),
    // loaded in name order so the older release takes the lower OS bit
    string[] modulefiles;
    foreach (DirEntry entry; dirEntries(dirWindows, "modules-*.json", SpanMode.shallow))
        modulefiles ~= entry.name;
    if (modulefiles.length == 0)
        stderr.writeln("warning: no module scans found in '", dirWindows, "'");
    foreach (string path; sort(modulefiles))
        databaseLoadWindowsModules(path);
    databaseSortWindowsModules();

    // Documentation is extracted from a checkout of the Microsoft docs, which
    // an instance may well not have, so its absence is not an error
    string docspath = buildPath(dirWindows, "driver-docs.json");
    if (exists(docspath))
        databaseLoadWindowsDocs(docspath);
    else
        stderr.writeln("warning: no documentation found in '", dirWindows, "'");

    string win32path = buildPath(dirWindows, "win32-docs.json");
    if (exists(win32path))
        databaseLoadWin32Docs(win32path);
    else
        stderr.writeln("warning: no Win32 code listings found in '", dirWindows, "'");

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
    const(char)[] source = readSource(path);
    scope(exit) releaseSource(source);
    JSONReader reader = JSONReader(source);

    size_t totalSymbolic;
    const(char)[] key = void;

    reader.enterObject();
    while (reader.readKey(key))
    {
        if (key != "headers")
        {
            reader.skipValue();
            continue;
        }

        reader.enterArray();
        while (reader.nextElement())
        {
            WindowsHeader winheader;
            reader.enterObject();
            while (reader.readKey(key))
            {
                switch (key) {
                case "name":
                    winheader.name = arenaDup(reader.readString());
                    winheader.key  = arenaLower(winheader.name);
                    break;
                case "description":
                    winheader.description = arenaDup(reader.readString());
                    break;
                case "symbolics":
                    reader.enterArray();
                    while (reader.nextElement())
                        winheader.symbolics ~= readSymbolic(reader);
                    break;
                default:
                    reader.skipValue();
                }
            }

            totalSymbolic += winheader.symbolics.length;
            data_windows_headers ~= winheader;
        }
    }

    sort!("a.key < b.key")(data_windows_headers);

    statistics.windowsHeaderCount = data_windows_headers.length;
    statistics.windowsSymbolicCount = totalSymbolic;
}

private WindowsSymbolic readSymbolic(ref JSONReader reader)
{
    WindowsSymbolic sym;
    const(char)[] key = void;

    reader.enterObject();
    while (reader.readKey(key))
    {
        switch (key) {
        case "name":
            sym.name = arenaDup(reader.readString());
            sym.key  = arenaLower(sym.name);
            break;
        case "description":
            sym.message = arenaDup(reader.readString());
            break;
        case "id":
            sym.origId = arenaDup(reader.readString());
            break;
        default:
            reader.skipValue();
        }
    }

    if (parseCode(sym.origId, sym.id) == false)
        stderr.writeln("warning: parsing code '", sym.origId, "' failed");
    sym.decId = arenaText(sym.id);

    return sym;
}

// Get a list of Windows headers
WindowsHeader[] databaseWindowsHeaders()
{
    return data_windows_headers;
}

// Get header by its name
WindowsHeader databaseWindowsHeader(string name)
{
    char[256] keybuf = void;
    const(char)[] key = toLowerBuf(keybuf, name);
    
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
    
    char[256] keybuf = void;
    const(char)[] key = toLowerBuf(keybuf, name);
    
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

/// Set of OS releases, tested against WindowsRelease.bit
alias WindowsOSSet = uint;

/// An OS release a module scan was taken from
struct WindowsRelease
{
    WindowsOSSet bit; /// Bit this release occupies in a set
    string key;   /// Short key, e.g. "11"
    string name;  /// Display name, e.g. "Windows 11"
    string build; /// Build the scan was taken on
    size_t moduleCount;  /// Modules the scan found
    size_t messageCount; /// Messages the scan found
}

struct WindowsModuleError
{
    uint id;
    string origId;
    string message;
    WindowsOSSet os; /// Releases shipping this exact message
}
struct WindowsModule
{
    string name;
    string description;
    WindowsModuleError[] messages;
    WindowsOSSet os; /// Releases shipping this module
}

// NOTE: Scans overlap heavily
//
//       Consecutive Windows releases share the vast majority of their module
//       messages. Rather than keeping one module list per release, entries are
//       merged on load and tagged with the set of releases they appear in, so
//       a code lookup reports "10 11" instead of returning two near-identical
//       rows, and the shared message strings are only stored once.
private void databaseLoadWindowsModules(string path)
{
    if (data_windows_releases.length >= WindowsOSSet.sizeof * 8)
        throw new Exception("Too many OS releases to tag");

    const(char)[] source = readSource(path);
    scope(exit) releaseSource(source);
    JSONReader reader = JSONReader(source);

    // The bit only depends on how many scans came before, so it does not have
    // to wait on the "os" object, which some scans put after the modules
    WindowsOSSet osbit = 1 << data_windows_releases.length;
    WindowsRelease release;
    release.bit = osbit;

    const(char)[] key = void;
    reader.enterObject();
    while (reader.readKey(key))
    {
        switch (key) {
        case "os":
            readRelease(reader, release);
            break;
        case "modules":
            reader.enterArray();
            while (reader.nextElement())
                readModule(reader, osbit);
            break;
        default:
            reader.skipValue();
        }
    }

    if (release.key.length == 0) // pre-v2 scan, no OS metadata to go on
        release.key = release.name = baseName(stripExtension(path));

    data_windows_releases ~= release;
}

private void readRelease(ref JSONReader reader, ref WindowsRelease release)
{
    const(char)[] key = void;

    reader.enterObject();
    while (reader.readKey(key))
    {
        switch (key) {
        case "key":   release.key   = arenaDup(reader.readString()); break;
        case "name":  release.name  = arenaDup(reader.readString()); break;
        case "build": release.build = arenaDup(reader.readString()); break;
        default:      reader.skipValue();
        }
    }
}

// NOTE: Somehow, all the module names are already lowercase
private void readModule(ref JSONReader reader, WindowsOSSet osbit)
{
    const(char)[] key = void;

    // The scans write their fields in alphabetical order, which puts "name"
    // behind the messages that need the module resolved first, so it gets
    // picked out in a pass of its own. Skipping is a plain byte scan and costs
    // far less than buffering a module's messages until the name shows up.
    size_t start = reader.tell();
    const(char)[] name;
    reader.enterObject();
    while (reader.readKey(key))
    {
        if (key == "name")
        {
            name = hold(scratch_name, reader.readString());
            break;
        }
        reader.skipValue();
    }
    if (name.length == 0)
        throw new Exception("Module entry carries no name");
    reader.seek(start);

    size_t modindex = void;
    if (size_t *existing = name in cache_windows_modules)
    {
        modindex = *existing;
    }
    else
    {
        modindex = data_windows_modules.length;
        data_windows_modules ~= WindowsModule(arenaDup(name));
        cache_windows_module_errors.length = data_windows_modules.length;
        cache_windows_modules[ data_windows_modules[modindex].name ] = modindex;
    }

    WindowsModule *mod = &data_windows_modules[modindex];
    mod.os |= osbit;
    size_t[][uint] *byCode = &cache_windows_module_errors[modindex];

    reader.enterObject();
    while (reader.readKey(key))
    {
        switch (key) {
        case "description":
            // --all-modules finds modules we have no blurb for
            if (mod.description.length == 0)
                mod.description = arenaDup(reader.readString());
            else
                reader.skipValue();
            break;
        case "messages":
            reader.enterArray();
            while (reader.nextElement())
                readModuleError(reader, mod, byCode, osbit);
            break;
        default:
            reader.skipValue();
        }
    }
}

private void readModuleError(ref JSONReader reader, WindowsModule *mod,
    size_t[][uint] *byCode, WindowsOSSet osbit)
{
    const(char)[] key = void;
    const(char)[] origId;
    const(char)[] message;

    reader.enterObject();
    while (reader.readKey(key))
    {
        switch (key) {
        case "code":    origId  = hold(scratch_code, reader.readString());    break;
        case "message": message = hold(scratch_message, reader.readString()); break;
        default:        reader.skipValue();
        }
    }

    uint id = void;
    if (parseCode(origId, id) == false)
        stderr.writeln("warning: parsing code '", origId, "' failed");

    // Same code can carry different text between releases, so both have to
    // match for the entries to be one and the same
    if (size_t[] *known = id in *byCode)
    {
        foreach (size_t i; *known)
        {
            if (mod.messages[i].message != message)
                continue;

            mod.messages[i].os |= osbit;
            return;
        }
    }

    WindowsModuleError error;
    error.id      = id;
    error.message = arenaDup(message);
    error.origId  = arenaDup(origId);
    error.os      = osbit;

    (*byCode)[id] ~= mod.messages.length;
    mod.messages ~= error;
}

// Sort key out of a version string like "10.0.26100.4652". The revision is left
// out, two scans of the same build would share a key and overwrite each other.
private ulong versionRank(string build)
{
    import std.array : split;
    import std.conv : to;

    string[] parts = split(build, '.');
    ulong rank;

    try
    {
        if (parts.length >= 1) rank |= cast(ulong)to!ubyte(parts[0]) << 56;
        if (parts.length >= 2) rank |= cast(ulong)to!ubyte(parts[1]) << 48;
        if (parts.length >= 3) rank |= to!uint(parts[2]);
    }
    catch (Exception) // hand-edited metadata shouldn't stop a load
    {
    }

    return rank;
}

private void databaseSortWindowsModules()
{
    cache_windows_modules = null;
    cache_windows_module_errors = null;

    sort!("a.name < b.name")(data_windows_modules);

    // Scans are loaded in filename order, which puts "modules-7.json" after
    // "modules-11.json". Releases carry their bit, so this only affects display.
    sort!((ref a, ref b) => versionRank(a.build) < versionRank(b.build))(data_windows_releases);

    size_t modmsgcnt;
    foreach (ref WindowsModule mod; data_windows_modules)
    {
        modmsgcnt += mod.messages.length;

        foreach (ref WindowsRelease release; data_windows_releases)
        {
            if (mod.os & release.bit)
                release.moduleCount++;
        }

        foreach (ref WindowsModuleError error; mod.messages)
        {
            foreach (ref WindowsRelease release; data_windows_releases)
            {
                if (error.os & release.bit)
                    release.messageCount++;
            }
        }
    }

    statistics.windowsOSCount = data_windows_releases.length;
    statistics.windowsModuleCount = data_windows_modules.length;
    statistics.windowsModuleErrorCount = modmsgcnt;

    GC.collect();
    GC.minimize();
}

// Get the OS releases module scans were loaded from, oldest first
WindowsRelease[] databaseWindowsReleases()
{
    return data_windows_releases;
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

/// Newest modification time across the loaded data files
SysTime databaseTimestamp()
{
    return data_timestamp;
}

//
// Windows documentation
//

/// A parameter of a bug check, as its article documents it
struct WindowsDocParameter
{
    string name;
    string description; /// Rendered HTML
}

/// An article from the Windows driver documentation, attached to the symbolic
/// name it documents
struct WindowsDoc
{
    string kind;    /// "bugcheck" or "cmprob"
    string key;     /// Lowercase symbolic name for searching
    string name;    /// Symbolic name
    uint id;        /// Code the article documents
    string origId;  /// Code as the article writes it
    string decId;   /// Code formatted as decimal
    string title;
    string description; /// Plain text summary
    string url;     /// Article on learn.microsoft.com
    string header;  /// Header defining the symbolic, null when none does
    WindowsDocParameter[] parameters;
    string html;    /// Article body, rendered
}

private void databaseLoadWindowsDocs(string path)
{
    const(char)[] source = readSource(path);
    scope(exit) releaseSource(source);
    JSONReader reader = JSONReader(source);

    const(char)[] key = void;

    reader.enterObject();
    while (reader.readKey(key))
    {
        if (key != "docs")
        {
            reader.skipValue();
            continue;
        }

        reader.enterArray();
        while (reader.nextElement())
            data_windows_docs ~= readDoc(reader);
    }

    sort!("a.key < b.key")(data_windows_docs);

    statistics.windowsDocCount = data_windows_docs.length;
}

private WindowsDoc readDoc(ref JSONReader reader)
{
    WindowsDoc doc;
    const(char)[] key = void;

    reader.enterObject();
    while (reader.readKey(key))
    {
        switch (key) {
        case "kind":
            doc.kind = arenaDup(reader.readString());
            break;
        case "name":
            doc.name = arenaDup(reader.readString());
            doc.key  = arenaLower(doc.name);
            break;
        case "code":
            doc.origId = arenaDup(reader.readString());
            break;
        case "title":
            doc.title = arenaDup(reader.readString());
            break;
        case "description":
            doc.description = arenaDup(reader.readString());
            break;
        case "url":
            doc.url = arenaDup(reader.readString());
            break;
        case "header":
            doc.header = arenaDup(reader.readString());
            break;
        case "html":
            doc.html = arenaDup(reader.readString());
            break;
        case "parameters":
            reader.enterArray();
            while (reader.nextElement())
                doc.parameters ~= readDocParameter(reader);
            break;
        default:
            reader.skipValue();
        }
    }

    if (parseCode(doc.origId, doc.id) == false)
        stderr.writeln("warning: parsing code '", doc.origId, "' failed");
    doc.decId = arenaText(doc.id);

    return doc;
}

private WindowsDocParameter readDocParameter(ref JSONReader reader)
{
    WindowsDocParameter param;
    const(char)[] key = void;

    reader.enterObject();
    while (reader.readKey(key))
    {
        switch (key) {
        case "name":        param.name        = arenaDup(reader.readString()); break;
        case "description": param.description = arenaDup(reader.readString()); break;
        default:            reader.skipValue();
        }
    }

    return param;
}

// Get all articles, by symbolic name
WindowsDoc[] databaseWindowsDocs()
{
    return data_windows_docs;
}

// Get article by the symbolic name it documents
//
// Searched rather than scanned: the bug code listing looks up every row it
// writes, which a linear walk would turn into a quarter of a million compares.
WindowsDoc databaseWindowsDocByName(const(char)[] name)
{
    char[256] keybuf = void;
    const(char)[] key = toLowerBuf(keybuf, name);

    size_t low;
    size_t high = data_windows_docs.length;

    while (low < high)
    {
        size_t mid = low + ((high - low) / 2);
        if (data_windows_docs[mid].key < key)
            low = mid + 1;
        else if (data_windows_docs[mid].key > key)
            high = mid;
        else
            return data_windows_docs[mid];
    }

    static immutable WindowsDoc empty;
    return cast()empty;
}

//
// Win32 documentation
//

/// A constant, as one of the Win32 code listings writes it
struct Win32Entry
{
    string key;     /// Lowercase name for searching
    string name;
    uint id;        /// Value, when the listing gives one
    string origId;  /// Value as the listing writes it, null when it gives none
    string decId;   /// Value formatted as decimal
    string description;
    bool defined;   /// Whether a header already carries this name
}

/// An error, status or return code listing from the Win32 documentation
struct Win32Doc
{
    string key;     /// Slug the listing is served under
    string title;
    string description; /// Plain text summary
    string header;  /// Header the listing belongs to, null when it names none
    string url;     /// Article on learn.microsoft.com
    string html;    /// Prose above the listing, rendered
    Win32Entry[] entries;
}

// Where one name is documented. A name can be listed by more than one article,
// so the lookups hand back every place it turns up.
private struct Win32Ref
{
    string key;
    uint id;
    uint doc;
    uint entry;
}

/// One constant in the listing that documents it
struct Win32Result
{
    Win32Doc doc;
    Win32Entry entry;
}

private void databaseLoadWin32Docs(string path)
{
    const(char)[] source = readSource(path);
    scope(exit) releaseSource(source);
    JSONReader reader = JSONReader(source);

    const(char)[] key = void;

    reader.enterObject();
    while (reader.readKey(key))
    {
        if (key != "docs")
        {
            reader.skipValue();
            continue;
        }

        reader.enterArray();
        while (reader.nextElement())
            data_win32_docs ~= readWin32Doc(reader);
    }

    sort!("a.key < b.key")(data_win32_docs);

    // Which names are new is what the listings are here for, and the answer is
    // only knowable once the headers are in. The set goes away with the load.
    bool[string] defined;
    foreach (ref WindowsHeader header; data_windows_headers)
    {
        foreach (ref WindowsSymbolic sym; header.symbolics)
            defined[sym.key] = true;
    }

    size_t total;
    foreach (size_t d, ref Win32Doc doc; data_win32_docs)
    {
        foreach (size_t e, ref Win32Entry entry; doc.entries)
        {
            entry.defined = (entry.key in defined) !is null;
            data_win32_index ~= Win32Ref(entry.key, entry.id, cast(uint)d, cast(uint)e);

            // A name a header already defines is looked up under that header,
            // whose code is the one to trust: a handful of articles print a
            // value their own header disagrees with.
            if (entry.defined == false && entry.origId.length)
                data_win32_codes ~= Win32Ref(entry.key, entry.id, cast(uint)d, cast(uint)e);
        }

        total += doc.entries.length;
    }

    sort!("a.key < b.key")(data_win32_index);
    sort!("a.id < b.id")(data_win32_codes);

    statistics.win32DocCount = data_win32_docs.length;
    statistics.win32EntryCount = total;
}

private Win32Doc readWin32Doc(ref JSONReader reader)
{
    Win32Doc doc;
    const(char)[] key = void;

    reader.enterObject();
    while (reader.readKey(key))
    {
        switch (key) {
        case "key":         doc.key         = arenaDup(reader.readString()); break;
        case "title":       doc.title       = arenaDup(reader.readString()); break;
        case "description": doc.description = arenaDup(reader.readString()); break;
        case "header":      doc.header      = arenaDup(reader.readString()); break;
        case "url":         doc.url         = arenaDup(reader.readString()); break;
        case "html":        doc.html        = arenaDup(reader.readString()); break;
        case "entries":
            reader.enterArray();
            while (reader.nextElement())
                doc.entries ~= readWin32Entry(reader);
            break;
        default:
            reader.skipValue();
        }
    }

    return doc;
}

private Win32Entry readWin32Entry(ref JSONReader reader)
{
    Win32Entry entry;
    const(char)[] key = void;

    reader.enterObject();
    while (reader.readKey(key))
    {
        switch (key) {
        case "name":
            entry.name = arenaDup(reader.readString());
            entry.key  = arenaLower(entry.name);
            break;
        case "code":
            entry.origId = arenaDup(reader.readString());
            break;
        case "description":
            entry.description = arenaDup(reader.readString());
            break;
        default:
            reader.skipValue();
        }
    }

    // Plenty of constants are documented without one, so a missing value is
    // not the error a missing value is anywhere else in the database. One the
    // article mistyped is dropped rather than kept as a zero, which would file
    // the name under a code it has nothing to do with.
    if (entry.origId.length)
    {
        if (parseCode(entry.origId, entry.id))
        {
            entry.decId = arenaText(entry.id);
        }
        else
        {
            stderr.writeln("warning: ", entry.name, " has an unreadable code '", entry.origId, "'");
            entry.origId = null;
            entry.id = 0;
        }
    }

    return entry;
}

// Get all listings, by slug
Win32Doc[] databaseWin32Docs()
{
    return data_win32_docs;
}

// Get a listing by its slug
Win32Doc databaseWin32Doc(const(char)[] key)
{
    size_t low;
    size_t high = data_win32_docs.length;

    while (low < high)
    {
        size_t mid = low + ((high - low) / 2);
        if (data_win32_docs[mid].key < key)
            low = mid + 1;
        else if (data_win32_docs[mid].key > key)
            high = mid;
        else
            return data_win32_docs[mid];
    }

    static immutable Win32Doc empty;
    return cast()empty;
}

/// Every listing documenting a symbolic name. Reused buffer, see search().
Win32Result[] databaseWin32ByName(const(char)[] name)
{
    char[256] keybuf = void;
    const(char)[] key = toLowerBuf(keybuf, name);

    static Win32Result[] results;
    results.length = 0;
    results.assumeSafeAppend();

    size_t at = lowerBound!("a.key < b")(data_win32_index, key);
    for (; at < data_win32_index.length && data_win32_index[at].key == key; ++at)
        results ~= win32Result(data_win32_index[at]);

    return results;
}

/// Constants carrying a code that no header defines. Reused buffer, see search().
Win32Result[] databaseWin32ByCode(uint code)
{
    static Win32Result[] results;
    results.length = 0;
    results.assumeSafeAppend();

    size_t at = lowerBound!("a.id < b")(data_win32_codes, code);
    for (; at < data_win32_codes.length && data_win32_codes[at].id == code; ++at)
        results ~= win32Result(data_win32_codes[at]);

    return results;
}

private Win32Result win32Result(ref Win32Ref found)
{
    Win32Doc doc = data_win32_docs[found.doc];
    return Win32Result(doc, doc.entries[found.entry]);
}

// First index whose element is not below the value, the usual half-open form
private size_t lowerBound(alias less, T, K)(T[] sorted, K value)
{
    import std.functional : binaryFun;

    size_t low;
    size_t high = sorted.length;

    while (low < high)
    {
        size_t mid = low + ((high - low) / 2);
        if (binaryFun!less(sorted[mid], value))
            low = mid + 1;
        else
            high = mid;
    }

    return low;
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
    const(char)[] source = readSource(path);
    scope(exit) releaseSource(source);
    JSONReader reader = JSONReader(source);

    DatabaseCrt crt;
    const(char)[] key = void;

    reader.enterObject();
    while (reader.readKey(key))
    {
        switch (key) {
        case "name": crt.name = arenaDup(reader.readString()); break;
        case "full": crt.full = arenaDup(reader.readString()); break;
        case "arch": crt.arch = arenaDup(reader.readString()); break;
        case "messages":
            reader.enterArray();
            while (reader.nextElement())
                crt.messages ~= readCrtMessage(reader);
            break;
        default:
            reader.skipValue();
        }
    }

    // All of these are mandatory, so refuse a file that came out half-written
    if (crt.name.length == 0 || crt.full.length == 0 || crt.arch.length == 0)
        throw new Exception("Missing name, full, or arch in '"~path~"'");

    data_crt ~= crt;
    statistics.crtMessageCount += crt.messages.length;
}

private DatabaseCrtMessage readCrtMessage(ref JSONReader reader)
{
    DatabaseCrtMessage msg;
    const(char)[] key = void;

    reader.enterObject();
    while (reader.readKey(key))
    {
        switch (key) {
        case "code":    msg.code    = cast(int)reader.readInteger();  break;
        case "message": msg.message = arenaDup(reader.readString());  break;
        default:        reader.skipValue();
        }
    }

    msg.origId = arenaText(msg.code);
    return msg;
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
    
    size_t windowsOSCount;
    size_t windowsHeaderCount;
    size_t windowsModuleCount;
    size_t windowsSymbolicCount; // symbolic names + code
    size_t windowsModuleErrorCount; // errors from module
    size_t windowsDocCount; // documented bug checks and problem codes
    size_t win32DocCount;   // Win32 code listings
    size_t win32EntryCount; // constants those listings carry

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
    WindowsOSSet os;        /// releases this message appears in, module results only

    // Description
    const(char)[] pre;      /// pre-needle snippet
    const(char)[] needle;   /// needle
    const(char)[] post;     /// post-needle snippet
    bool preTruncated;      /// whether pre snippet was truncated
    bool postTruncated;     /// whether post snippet was truncated
}

/// How many characters to snip before and after needle
private enum SNIPPET_PADDING = 40;
// TODO: This should be a limit per "type" (module/header/crt) and not a Grand Total
/// How many results in total
private enum SEARCH_LIMIT = 50;

private const(char)[] preSnip(const(char)[] text, const(char)[] input, ptrdiff_t i) {
    if (i == 0)
        return "";
    return i >= SNIPPET_PADDING ? text[i - SNIPPET_PADDING..i] : text[0..i];
}
private bool preSnipTruncated(const(char)[] text, const(char)[] input, ptrdiff_t i) {
    return i >= SNIPPET_PADDING;
}
private const(char)[] needleSnip(const(char)[] text, const(char)[] input, ptrdiff_t i) {
    return text[i..i + input.length];
}
private const(char)[] postSnip(const(char)[] text, const(char)[] input, ptrdiff_t i) {
    if (i >= text.length)
        return "";
    i += input.length;
    size_t i2 = i + SNIPPET_PADDING;
    return i2 < text.length ? text[i..i2] : text[i..$];
}
private bool postSnipTruncated(const(char)[] text, const(char)[] input, ptrdiff_t i) {
    if (i >= text.length)
        return false;
    return (i + input.length + SNIPPET_PADDING) < text.length;
}

/// Cap on how many results a search returns, for the API to document.
size_t searchLimit()
{
    return SEARCH_LIMIT;
}

/// Search every message for a code or a piece of text.
///
/// The result is only good until this thread searches again: the buffer behind
/// it is reused, since a fresh one per request is a few kilobytes of garbage
/// that adds up to a collection of the whole database several times an hour.
SearchResult[] search(string input)
{
    uint code = void;
    bool iscode = parseCode(input, code);

    static SearchResult[] results;
    results.length = 0;
    results.assumeSafeAppend();
    results.reserve(SEARCH_LIMIT);

    if (input.length == 0)
        return results;

    // Folded once here: every message in the database gets compared against it
    char[256] needlebuf = void;
    const(char)[] needle;
    if (iscode == false)
    {
        needle = toLowerBuf(needlebuf, input);
        if (needle is null) // query longer than the buffer, rare enough to allocate for
            needle = toLower(input);
    }

    // Take reference code/message reference and compare it with
    // local code/input
    bool process(uint refcode, string reforigid, string refdesc,
        string type,    // winmodule, winsymbol, crt)
        string name,    // Name of module, header, or crt
        WindowsOSSet os = 0,
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
            i = indexOfFold(refdesc, needle);
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

            bool pretrunc, posttrunc;
            if (iscode == false)
            {
                msgpre      = preSnip(refdesc, needle, i);
                pretrunc    = preSnipTruncated(refdesc, needle, i);
                msgneedle   = needleSnip(refdesc, needle, i);
                msgpost     = postSnip(refdesc, needle, i);
                posttrunc   = postSnipTruncated(refdesc, needle, i);
            }

            results ~= SearchResult(type, reforigid, name, os,
                 msgpre, msgneedle, msgpost, pretrunc, posttrunc);
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
        if (process(id, origId, message, "windows-module", winmodule.name, err.os))
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
    
    // Only the names no header defines: the rest were already offered above,
    // under the header that is authoritative for them.
    foreach (ref win32doc; data_win32_docs)
    foreach (ref entry; win32doc.entries)
    {
        if (entry.defined || (iscode && entry.origId.length == 0))
            continue;

        with (entry)
        if (process(id, name, description, "windows-win32", win32doc.title))
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

/// Get associated modules by error code. Reused buffer, see search().
SearchWindowsModuleResult[] searchWindowsModulesByCode(uint errcode)
{
    static SearchWindowsModuleResult[] results;
    results.length = 0;
    results.assumeSafeAppend();
    results.reserve(16);
    foreach (ref module_; data_windows_modules)
    {
        foreach (ref errmsg; module_.messages)
        {
            if (errcode == errmsg.id)
            {
                results ~= SearchWindowsModuleResult(module_, errmsg);
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

/// Get associated headers by error code. Reused buffer, see search().
SearchWindowsHeaderResult[] searchWindowsHeadersByCode(uint errcode)
{
    static SearchWindowsHeaderResult[] results;
    results.length = 0;
    results.assumeSafeAppend();
    results.reserve(16);
    foreach (ref header; data_windows_headers)
    {
        foreach (ref sym; header.symbolics)
        {
            if (errcode == sym.id)
            {
                results ~= SearchWindowsHeaderResult(header, sym);
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
WindowsRelease[] data_windows_releases;
WindowsDoc[] data_windows_docs;
Win32Doc[] data_win32_docs;
Win32Ref[] data_win32_index; // by name
Win32Ref[] data_win32_codes; // by code, names no header defines

SysTime data_timestamp;

// Load-time only, dropped once every module scan is merged
size_t[string] cache_windows_modules;      // module name -> data_windows_modules index
size_t[][uint][] cache_windows_module_errors; // per module, error code -> message indexes

// Cache, to make it easier to search from data
//WindowsError[string] cache_windows; // Module+Header code merged
