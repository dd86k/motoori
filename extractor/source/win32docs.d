/// Error, status and return code listings from the Win32 documentation.
///
/// That repository has no machine-readable index of its constants: the
/// conversion to Markdown left every one of them as a definition list, laid out
/// a different way depending on the decade the article was written in. Some are
/// pipe tables with the name and the value sharing a cell, some put the name in
/// one column and the value in another, some are block level `<dl>` runs with
/// no table at all. What they agree on is that a listing has a symbolic name, a
/// value more often than not, and a description, so the reader below sniffs
/// those out of the shape of the cells instead of trusting any single layout.
module extract.source.win32docs;

import std.stdio, std.file, std.path, std.string;
import std.array : Appender, appender;
import std.datetime.systime : Clock;
import std.json;
import extract.markdown;
import extract.utils;

/// Where the articles are published
private enum DOCSET_URL = "https://learn.microsoft.com/en-us/windows/win32";

private enum DOCSET_DIR = "desktop-src";

private struct Win32Entry
{
    string name;
    string code;        /// Value as the article writes it, empty when it gives none
    string description;
}

private struct Win32Doc
{
    string key;         /// Slug the listing is served under
    string title;
    string description; /// Plain text, for search results and meta tags
    string header;      /// Header the title names, when it names one
    string path;        /// Article path, relative to the docset root
    string url;
    string html;        /// Prose above the listing, rendered
    Win32Entry[] entries;
}

/// Read the error code listings out of a MicrosoftDocs/win32 checkout into one
/// document.
void processWin32Docs(string outdir, string docsroot)
{
    string root = resolveDocsRoot(docsroot);

    Win32Doc[] docs;
    bool[string] taken;

    foreach (string path; sortedArticles(root))
    {
        string title = peekTitle(path);
        if (title.length == 0 || isErrorArticle(title) == false)
            continue;

        Win32Doc doc = parseArticle(root, path);

        // Most of what the title rule lets through is prose about handling
        // errors rather than a listing of them, and says so by holding none.
        if (doc.entries.length == 0)
            continue;

        doc.key = uniqueKey(taken, doc.path);
        docs ~= doc;
    }

    if (docs.length == 0)
        throw new Exception("No listings found under '"~root~"'");

    report(docs, buildPath(outdir, "windows", "headers.json"));

    mkchdir(outdir);
    mkchdir("windows");

    JSONValue jdocs = JSONValue(JSONValue[].init); // for older D compilers
    foreach (ref Win32Doc doc; docs)
        jdocs.array ~= toJSON(doc);

    JSONValue jsource;
    jsource["name"] = "win32";
    jsource["url"]  = "https://github.com/MicrosoftDocs/win32";
    jsource["license"] = "CC-BY-4.0";
    jsource["date"] = Clock.currTime().toISOExtString();

    JSONValue j;
    j["version"] = 1;
    j["source"]  = jsource;
    j["docs"]    = jdocs;

    writefile("win32-docs.json", j.toString());
    writeln("wrote ", docs.length, " listings to win32-docs.json");

    chdir("..");
    chdir("..");
}

private JSONValue toJSON(ref Win32Doc doc)
{
    JSONValue jentries = JSONValue(JSONValue[].init);
    foreach (ref Win32Entry entry; doc.entries)
    {
        JSONValue jentry;
        jentry["name"] = entry.name;
        if (entry.code.length)
            jentry["code"] = entry.code;
        if (entry.description.length)
            jentry["description"] = entry.description;
        jentries.array ~= jentry;
    }

    JSONValue j;
    j["key"] = doc.key;
    j["title"] = doc.title;
    if (doc.description.length)
        j["description"] = doc.description;
    if (doc.header.length)
        j["header"] = doc.header;
    j["path"] = doc.path;
    j["url"] = doc.url;
    if (doc.html.length)
        j["html"] = doc.html;
    j["entries"] = jentries;
    return j;
}

// The repository holds the docset one folder down, but pointing at that folder
// directly is just as reasonable, so take either.
private string resolveDocsRoot(string path)
{
    if (path.length == 0)
        throw new Exception("No win32 path given");

    string inner = buildPath(path, DOCSET_DIR);
    if (exists(inner))
        return inner;

    if (exists(buildPath(path, "Debug")))
        return path;

    throw new Exception("'"~path~"' does not look like a win32 docs checkout");
}

private string[] sortedArticles(string root)
{
    import std.algorithm.sorting : sort;

    string[] paths;
    foreach (DirEntry entry; dirEntries(root, "*.md", SpanMode.depth))
        paths ~= entry.name;

    return sort(paths).release();
}

// std.path.relativePath needs both sides absolute, and the root given on the
// command line rarely is, so the prefix comes off by hand.
private string docPath(string root, string path)
{
    string relative = path[root.length..$];
    while (relative.length && (relative[0] == '/' || relative[0] == '\\'))
        relative = relative[1..$];

    return relative.replace("\\", "/");
}

// Two folders name their listing the same thing often enough to matter, so the
// folder joins the slug only where it has to.
private string uniqueKey(ref bool[string] taken, string path)
{
    string key = toLower(baseName(path, ".md"));
    if (key in taken)
        key = toLower(baseName(dirName(path))) ~ "-" ~ key;

    taken[key] = true;
    return key;
}

//
// Selection
//

// Reading 48,000 articles in full to look at nine bytes of frontmatter is most
// of the run, and the title is always within the first few hundred of them.
private string peekTitle(string path)
{
    char[4096] buffer = void;

    File file = File(path, "rb");
    scope(exit) file.close();

    char[] head = file.rawRead(buffer);
    foreach (const(char)[] line; splitLines(head))
    {
        if (startsWith(line, "title:"))
            return cleanTitle(strip(line[6..$]));
    }

    return null;
}

// One article let the markup of its first entry leak into the title field, and
// nothing downstream should have to carry that.
private string cleanTitle(const(char)[] raw)
{
    const(char)[] title = raw;

    title = title[0..cutAt(title, "<")];
    title = title[0..cutAt(title, "**")];
    title = stripRight(title);

    while (endsWith(title, "(") || endsWith(title, "-"))
        title = stripRight(title[0..$-1]);

    title = strip(title);
    if (title.length >= 2 && (title[0] == '"' || title[0] == '\'') && title[$-1] == title[0])
        title = title[1..$-1];

    return unescapeMarkdown(strip(title));
}

private size_t cutAt(const(char)[] text, const(char)[] mark)
{
    ptrdiff_t at = indexOf(text, mark);
    return at < 0 ? text.length : at;
}

// A listing of codes says so in its title. The API reference pages that merely
// mention errors end in the kind of thing they document, which is what tells
// the two apart.
private bool isErrorArticle(const(char)[] title)
{
    const(char)[] bare = toLower(dropParenthetical(title));

    switch (lastWord(bare)) {
    case "structure", "enumeration", "method", "function", "class", "property",
         "event", "transaction", "interface", "macro", "message", "sample",
         "element", "styles", "style":
        return false;
    default:
    }

    return indexOf(bare, "error code") >= 0
        || indexOf(bare, "error constant") >= 0
        || indexOf(bare, "error message") >= 0
        || indexOf(bare, "error value") >= 0
        || indexOf(bare, "return value") >= 0
        || indexOf(bare, "return code") >= 0
        || indexOf(bare, "status code") >= 0
        || indexOf(bare, "hresult") >= 0
        || indexOf(bare, "success and error") >= 0
        || indexOf(bare, "error and success") >= 0
        || hasWord(bare, "errors");
}

private const(char)[] dropParenthetical(const(char)[] title)
{
    const(char)[] bare = stripRight(title);
    if (endsWith(bare, ")") == false)
        return bare;

    ptrdiff_t open = lastIndexOf(bare, '(');
    return open < 0 ? bare : stripRight(bare[0..open]);
}

private const(char)[] lastWord(const(char)[] text)
{
    size_t start = text.length;
    while (start > 0 && isWordChar(text[start - 1]))
        --start;

    return text[start..$];
}

private bool hasWord(const(char)[] text, const(char)[] word)
{
    for (size_t at; at < text.length; )
    {
        ptrdiff_t hit = indexOf(text[at..$], word);
        if (hit < 0)
            return false;

        size_t start = at + hit;
        size_t end = start + word.length;
        if ((start == 0 || isWordChar(text[start - 1]) == false) &&
            (end == text.length || isWordChar(text[end]) == false))
            return true;

        at = start + 1;
    }

    return false;
}

private bool isWordChar(char c)
{
    return isAlphaNum(c) || c == '_';
}

private bool isAlphaNum(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

// The header a listing belongs to, which the title carries in a trailing
// parenthetical: "WFP Error Codes (Winerror.h)".
private string headerFromTitle(const(char)[] title)
{
    const(char)[] bare = stripRight(title);
    if (endsWith(bare, ")") == false)
        return null;

    ptrdiff_t open = lastIndexOf(bare, '(');
    if (open < 0)
        return null;

    const(char)[] inside = strip(bare[open + 1..$-1]);
    if (endsWith(toLower(inside), ".h") == false || indexOf(inside, ' ') >= 0)
        return null;

    return toLower(inside).idup;
}

//
// Articles
//

private Win32Doc parseArticle(string root, string path)
{
    Win32Doc doc;
    doc.path = docPath(root, path);
    doc.url  = DOCSET_URL ~ "/" ~ toLower(stripExtension(doc.path));

    const(char)[][] lines = splitLines(cast(const(char)[])readfile(path));
    const(char)[][] body_;
    Frontmatter front = readFrontmatter(lines, body_);
    body_ = dropTitle(body_);

    doc.title = cleanTitle(front.title);
    doc.header = headerFromTitle(doc.title);

    // The header is carried as a field of its own, so the title stops repeating
    // it: "TBS Return Codes (Tbs.h)" reads as "TBS Return Codes" beside "tbs.h".
    if (doc.header.length)
        doc.title = dropParenthetical(doc.title).idup;

    LinkResolver links = LinkResolver(DOCSET_URL, dirName(doc.path), doc.url);

    doc.entries = tableEntries(body_, links);
    foreach (ref Win32Entry entry; blockEntries(body_))
        addEntry(doc.entries, entry);

    size_t cut = listingStart(body_, links);
    doc.html = renderMarkdown(body_[0..cut], links);
    doc.description = articleDescription(front.description, body_[0..cut], links);

    return doc;
}

// Everything up to and including the level 1 heading is metadata: the heading
// repeats the title, which the page writes itself.
private const(char)[][] dropTitle(const(char)[][] lines)
{
    foreach (size_t i, const(char)[] line; lines)
    {
        if (startsWith(strip(line), "# "))
            return lines[i + 1..$];
    }

    return lines;
}

// Half the corpus sets its description to "Learn more about: <title>", which
// says nothing the title does not, so the opening paragraph stands in.
private string articleDescription(string front, const(char)[][] lead, ref LinkResolver links)
{
    string description = cleanTitle(front);
    if (description.length && startsWith(description, "Learn more about") == false)
        return description;

    foreach (const(char)[] line; lead)
    {
        const(char)[] stripped = strip(line);
        if (stripped.length == 0 || stripped[0] == '#' || stripped[0] == '>' ||
            stripped[0] == '<' || stripped[0] == '|' || stripped[0] == '-')
            continue;

        return cellText(renderInlineText(stripped, links));
    }

    return description;
}

// Everything above the first constant is what the article says about the set as
// a whole. Below it is the listing, which is written out as data instead.
private size_t listingStart(const(char)[][] lines, ref LinkResolver links)
{
    TableRange range = void;
    Table tbl = extractTable(lines, links, range);
    size_t cut = tbl.empty() ? lines.length : range.start;

    foreach (size_t i, const(char)[] line; lines)
    {
        if (i >= cut)
            break;
        if (boldName(line).length)
            return i;
    }

    return cut;
}

private void addEntry(ref Win32Entry[] entries, ref Win32Entry entry)
{
    foreach (ref Win32Entry seen; entries)
    {
        if (seen.name == entry.name)
            return;
    }

    entries ~= entry;
}

//
// Table listings
//

private struct Columns
{
    ptrdiff_t name = -1;
    ptrdiff_t value = -1;
    ptrdiff_t description = -1;
}

private Win32Entry[] tableEntries(const(char)[][] lines, ref LinkResolver links)
{
    Win32Entry[] entries;

    foreach (ref Table tbl; extractTables(lines, links))
    {
        Columns columns = sniffColumns(tbl);
        if (columns.name < 0)
            continue;

        foreach (string[] row; tbl.rows)
        {
            Win32Entry entry = rowEntry(row, columns);
            if (entry.name.length)
                addEntry(entries, entry);
        }
    }

    return entries;
}

// Column headings run from "Constant/value" through "Term" to "HRESULT", so
// what a column holds is decided by what is in it.
private Columns sniffColumns(ref Table tbl)
{
    Columns columns;
    if (tbl.rows.length == 0)
        return columns;

    size_t width;
    foreach (string[] row; tbl.rows)
    {
        if (row.length > width)
            width = row.length;
    }

    size_t[] symbolics = new size_t[width];
    size_t[] values = new size_t[width];
    size_t[] lengths = new size_t[width];

    foreach (string[] row; tbl.rows)
    {
        foreach (size_t i, string cell; row)
        {
            string text = cellText(cell);
            lengths[i] += text.length;

            if (firstSymbolic(text).length)
                ++symbolics[i];
            if (firstValue(text).length)
                ++values[i];
        }
    }

    size_t half = tbl.rows.length / 2;

    foreach (size_t i; 0..width)
    {
        if (symbolics[i] > half && (columns.name < 0 || symbolics[i] > symbolics[columns.name]))
            columns.name = i;
    }

    if (columns.name < 0)
        return columns;

    // The description is settled before the value, because prose that ends in
    // "Value: 0x80630107" counts as numeric too, and a two column listing
    // written that way has nothing left to describe itself with.
    foreach (size_t i, string cell; tbl.header)
    {
        if (i != columns.name && isDescriptionHeading(cellText(cell)))
        {
            columns.description = i;
            break;
        }
    }

    foreach (size_t i; 0..width)
    {
        if (i == columns.name || i == columns.description || values[i] <= half)
            continue;
        if (columns.value < 0 || values[i] > values[columns.value])
            columns.value = i;
    }

    if (columns.description < 0)
        foreach (size_t i; 0..width)
        {
            if (i == columns.name || i == columns.value)
                continue;
            if (columns.description < 0 || lengths[i] > lengths[columns.description])
                columns.description = i;
        }

    return columns;
}

private bool isDescriptionHeading(const(char)[] heading)
{
    switch (toLower(strip(heading))) {
    case "description", "meaning", "message", "remarks", "comment", "comments",
         "definition", "explanation", "error message", "cause":
        return true;
    default:
        return false;
    }
}

private Win32Entry rowEntry(string[] row, ref Columns columns)
{
    Win32Entry entry;

    if (cast(size_t)columns.name >= row.length)
        return entry;

    string named = cellText(row[columns.name]);
    entry.name = firstSymbolic(named);
    if (entry.name.length == 0)
        return entry;

    // Where the two share a cell the value follows the name; a column of its
    // own is only read when there is one.
    entry.code = firstValue(named);
    if (entry.code.length == 0 && columns.value >= 0 && cast(size_t)columns.value < row.length)
        entry.code = firstValue(cellText(row[columns.value]));

    if (columns.description >= 0 && cast(size_t)columns.description < row.length)
        entry.description = takeValueSuffix(cellText(row[columns.description]), entry.code);

    return entry;
}

// Peer networking writes the value at the end of the description rather than
// beside the name, and nowhere else.
private string takeValueSuffix(string description, ref string code)
{
    ptrdiff_t at = indexOf(description, "Value: ");
    if (at < 0)
        return description;

    if (code.length == 0)
        code = firstValue(description[at + 7..$]);

    return strip(description[0..at]).idup;
}

//
// Block listings
//

// The older articles have no table at all: the name sits alone on a line, in
// bold, with the value and the description on the lines below it.
private Win32Entry[] blockEntries(const(char)[][] lines)
{
    Win32Entry[] entries;
    Win32Entry entry;
    string description;

    void flush()
    {
        if (entry.name.length == 0)
            return;

        entry.description = strip(description).idup;
        addEntry(entries, entry);
        entry = Win32Entry.init;
        description = null;
    }

    foreach (const(char)[] line; lines)
    {
        string name = boldName(line);
        if (name.length)
        {
            flush();
            entry.name = name;
            continue;
        }

        if (entry.name.length == 0)
            continue;

        const(char)[] stripped = strip(line);
        if (stripped.length && stripped[0] == '#') // a section, so the listing ended
        {
            flush();
            continue;
        }

        string text = cellText(line);
        if (text.length == 0)
            continue;

        if (entry.code.length == 0 && description.length == 0)
        {
            string value = firstValue(text);
            if (value.length && isValueOnly(text))
            {
                entry.code = value;
                continue;
            }
        }

        if (description.length)
            description ~= ' ';
        description ~= text;
    }

    flush();
    return entries;
}

// A line that is nothing but "**SOME\_NAME**", whatever anchors surround it.
// The whole of it has to be the name: the compiler diagnostic articles head
// each entry with a bold sentence, and words inside one are not constants.
private string boldName(const(char)[] line)
{
    const(char)[] text = strip(stripTags(line));
    if (text.length < 5 || startsWith(text, "**") == false || endsWith(text, "**") == false)
        return null;

    string name = unescapeMarkdown(strip(text[2..$-2]));
    return isSymbolicName(name) ? name : null;
}

// "0 (0x0)" and "12111" are values; a sentence that opens with a number is not.
private bool isValueOnly(const(char)[] text)
{
    foreach (const(char)[] token; splitTokens(text))
    {
        if (normalizeValue(token).length == 0)
            return false;
    }

    return true;
}

//
// Text
//

// Cells arrive as rendered HTML, and a tag between two words is a word break
// rather than nothing, so the markup leaves a space behind.
private string cellText(const(char)[] html)
{
    Appender!string sink = appender!string;
    bool space;

    void putSpace()
    {
        if (sink[].length)
            space = true;
    }

    for (size_t i; i < html.length; ++i)
    {
        if (html[i] == '<')
        {
            while (i < html.length && html[i] != '>')
                ++i;
            putSpace();
            continue;
        }

        if (html[i] == ' ' || html[i] == '\t' || html[i] == '\n' || html[i] == '\r')
        {
            putSpace();
            continue;
        }

        if (space)
        {
            sink.put(' ');
            space = false;
        }

        sink.put(html[i]);
    }

    return unescapeMarkdown(unescapeHTML(sink[]));
}

private string unescapeHTML(string text)
{
    if (indexOf(text, '&') < 0)
        return text;

    return text
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", `"`)
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&");
}

// Symbolic names carry underscores, which the articles escape
private string unescapeMarkdown(const(char)[] text)
{
    if (indexOf(text, '\\') < 0)
        return text.idup;

    char[] out_;
    for (size_t i; i < text.length; ++i)
    {
        if (text[i] == '\\' && i + 1 < text.length && isAlphaNum(text[i + 1]) == false)
            ++i;
        out_ ~= text[i];
    }

    return cast(string)out_;
}

private string stripTags(const(char)[] html)
{
    char[] text;
    for (size_t i; i < html.length; ++i)
    {
        if (html[i] == '<')
        {
            while (i < html.length && html[i] != '>')
                ++i;
            continue;
        }
        text ~= html[i];
    }

    return cast(string)text;
}

private const(char)[][] splitTokens(const(char)[] text)
{
    const(char)[][] tokens;
    size_t start;

    for (size_t i; i <= text.length; ++i)
    {
        if (i < text.length && isTokenChar(text[i]))
            continue;

        if (i > start)
            tokens ~= text[start..i];
        start = i + 1;
    }

    return tokens;
}

private bool isTokenChar(char c)
{
    return isWordChar(c) || c == '.' || c == '-';
}

// First token that reads like a constant. Names with no underscore exist
// (WSAEACCES), so an all-capital run counts too, minus the handful of English
// words that would otherwise pass.
private string firstSymbolic(const(char)[] text)
{
    foreach (const(char)[] token; splitTokens(text))
    {
        if (isSymbolicName(token))
            return token.idup;
    }

    return null;
}

private bool isSymbolicName(const(char)[] token)
{
    if (token.length < 3 || token.length > 80)
        return false;

    if ((token[0] >= 'A' && token[0] <= 'Z') == false)
        return false;

    bool underscore;
    bool lowercase;
    foreach (char c; token)
    {
        if (c == '_')
            underscore = true;
        else if (c >= 'a' && c <= 'z')
            lowercase = true;
        else if (isWordChar(c) == false)
            return false;
    }

    if (underscore == false && lowercase)
        return false;

    // The prefix is what makes a name a name: NERR_NetNotStarted is one,
    // Something_Else is not.
    ptrdiff_t split = indexOf(token, '_');
    if (split > 0)
    {
        foreach (char c; token[0..split])
        {
            if (c >= 'a' && c <= 'z')
                return false;
        }
    }

    // Words that read like a constant but name a type, a technology or nothing
    // at all. The listings introduce their own subject in bold often enough for
    // this to be worth spelling out.
    switch (token) {
    case "HRESULT", "NTSTATUS", "TRUE", "FALSE", "NULL", "NOTE", "VALUE",
         "CODE", "NONE", "ERROR", "STATUS", "WINDOWS", "AND", "THE",
         "ADSI", "COM", "DDE", "HTTP", "MCI", "MTP", "OLE", "RPC", "SNMP",
         "TAPI", "WMI":
        return false;
    default:
        return true;
    }
}

// Best numeric literal in a run of text, preferring the hexadecimal spelling:
// the system error listings write both, as "1450 (0x5AA)".
private string firstValue(const(char)[] text)
{
    string best;

    foreach (const(char)[] token; splitTokens(text))
    {
        string value = normalizeValue(token);
        if (value.length == 0)
            continue;

        if (best.length == 0)
            best = value;
        if (startsWith(value, "0x"))
            return value;
    }

    return best;
}

// "0x00005011L" and "(0x0)" are both the value they wrap
private string normalizeValue(const(char)[] token)
{
    const(char)[] value = token;

    while (value.length && (value[$-1] == 'L' || value[$-1] == 'l' ||
                            value[$-1] == 'U' || value[$-1] == 'u'))
        value = value[0..$-1];

    if (value.length == 0 || value.length > 18)
        return null;

    if (startsWith(value, "0x") || startsWith(value, "0X"))
    {
        if (value.length < 3)
            return null;

        foreach (char c; value[2..$])
        {
            if (isHexDigit(c) == false)
                return null;
        }

        return "0x" ~ value[2..$].idup;
    }

    foreach (char c; value)
    {
        if (c < '0' || c > '9')
            return null;
    }

    return value.idup;
}

private bool isHexDigit(char c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

//
// Reporting
//

// The point of the scan is the names no header defines, so say how many those
// are, and warn where the two sides disagree on a code.
private void report(ref Win32Doc[] docs, string headerspath)
{
    size_t total;
    foreach (ref Win32Doc doc; docs)
        total += doc.entries.length;

    if (exists(headerspath) == false)
    {
        stderr.writeln("warning: '", headerspath, "' not found, nothing to compare against");
        writeln("read ", total, " constants");
        return;
    }

    HeaderSymbolics known = readHeaderSymbolics(headerspath);

    size_t mapped;
    size_t coded;
    foreach (ref Win32Doc doc; docs)
    {
        foreach (ref Win32Entry entry; doc.entries)
        {
            if (entry.code.length)
                ++coded;

            string *header = entry.name in known.headers;
            if (header is null)
                continue;

            ++mapped;

            uint code = void;
            if (entry.code.length == 0 || parseCode(entry.code, code) == false)
                continue;

            if (code != known.codes[entry.name])
                stderr.writefln("warning: %s is %#x in %s, %s in %s",
                    entry.name, known.codes[entry.name], *header, entry.code, doc.path);
        }
    }

    writefln("read %u constants, %u with a value, %u already in a header, %u new",
        total, coded, mapped, total - mapped);
}

unittest
{
    assert(isErrorArticle("COM Error Codes (Generic) (Winerror.h)"));
    assert(isErrorArticle("Error Messages (Wininet.h)"));
    assert(isErrorArticle("Windows Sockets Error Codes (Winsock2.h)"));
    assert(isErrorArticle("Digital-Video Errors"));
    assert(isErrorArticle("TBS Return Codes (Tbs.h)"));
    assert(isErrorArticle("HTTP Status Codes (Winhttp.h)"));
    assert(isErrorArticle("XTYP_ERROR transaction") == false);
    assert(isErrorArticle("glGetError function") == false);
    assert(isErrorArticle("Status Bar Styles (CommCtrl.h)") == false);
    assert(isErrorArticle("Bug Check 0x1: APC_INDEX_MISMATCH") == false);

    assert(headerFromTitle("WFP Error Codes (Winerror.h)") == "winerror.h");
    assert(headerFromTitle("Client Error Codes (Winbio_err.h)") == "winbio_err.h");
    assert(headerFromTitle("Error Codes (Windows Media Format 11 SDK)") is null);
    assert(headerFromTitle("Common Return Codes") is null);

    assert(isSymbolicName("E_UNEXPECTED"));
    assert(isSymbolicName("WSAEACCES"));
    assert(isSymbolicName("NERR_NetNotStarted"));
    assert(isSymbolicName("Corrective") == false);
    assert(isSymbolicName("HRESULT") == false);
    assert(isSymbolicName("value") == false);

    assert(firstSymbolic("E_UNEXPECTED 0x8000FFFF") == "E_UNEXPECTED");
    assert(firstSymbolic("D3DERR_INVALIDCALL (replaced with DXGI_ERROR_INVALID_CALL)") ==
        "D3DERR_INVALIDCALL");
    assert(firstSymbolic("The operation completed successfully.") is null);

    assert(firstValue("E_UNEXPECTED 0x8000FFFF") == "0x8000FFFF");
    assert(firstValue("1450 (0x5AA)") == "0x5AA"); // both spellings, one value
    assert(firstValue("12111") == "12111");
    assert(firstValue("0x00005011L") == "0x00005011");
    assert(firstValue("Catastrophic failure") is null);

    assert(isValueOnly("0 (0x0)"));
    assert(isValueOnly("The operation completed successfully.") == false);

    assert(cellText("<dl> <dt><strong>E_UNEXPECTED</strong></dt> <dt>0x8000FFFF</dt> </dl>") ==
        "E_UNEXPECTED 0x8000FFFF");
    assert(cellText("A driver failed &amp; died.<br/>") == "A driver failed & died.");

    assert(boldName(`<span id="ERROR_SUCCESS"></span><span id="error_success"></span>**ERROR\_SUCCESS**`) ==
        "ERROR_SUCCESS");
    assert(boldName("0 (0x0)") is null);

    assert(lastWord("xtyp_error transaction") == "transaction");
    assert(hasWord("digital-video errors", "errors"));
    assert(hasWord("no errorsomething here", "errors") == false);
}
