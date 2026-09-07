/// Articles from the Windows driver documentation repository.
///
/// Two families carry a symbolic name and a code the database already speaks:
/// the bug checks under debugger/, and the Config Manager problem codes under
/// install/. Everything else in that repository is prose about writing drivers,
/// which has no error entry to attach to.
module extract.source.driverdocs;

import std.stdio, std.file, std.path, std.string;
import std.datetime.systime : Clock;
import std.json;
import extract.markdown;
import extract.utils;

/// Where the articles are published
private enum DOCSET_URL = "https://learn.microsoft.com/en-us/windows-hardware/drivers";

private enum DIR_BUGCHECK = "debugger";
private enum DIR_CMPROB   = "install";

private struct DocParameter
{
    string name;
    string description;
}

private struct DriverDoc
{
    string kind;        /// "bugcheck" or "cmprob"
    string name;        /// Symbolic name
    string code;        /// Code as the article writes it
    uint id;            /// Code, parsed
    string title;
    string description; /// Plain text, for search results and meta tags
    string path;        /// Article path, relative to the docset root
    string url;
    string header;      /// Header defining the symbolic, when one does
    DocParameter[] parameters;
    string html;
}

/// Read the bug check and problem code articles out of a windows-driver-docs
/// checkout into one document.
void processDriverDocs(string outdir, string docsroot)
{
    string root = resolveDocsRoot(docsroot);

    DriverDoc[] docs;
    foreach (string path; sortedFiles(buildPath(root, DIR_BUGCHECK), "bug-check-0x*.md"))
        docs ~= parseBugCheck(root, path);
    foreach (string path; sortedFiles(buildPath(root, DIR_CMPROB), "cm-prob-*.md"))
        docs ~= parseProblemCode(root, path);

    if (docs.length == 0)
        throw new Exception("No articles found under '"~root~"'");

    mapSymbolics(docs, buildPath(outdir, "windows", "headers.json"));

    mkchdir(outdir);
    mkchdir("windows");

    JSONValue jdocs = JSONValue(JSONValue[].init); // for older D compilers
    foreach (ref DriverDoc doc; docs)
        jdocs.array ~= toJSON(doc);

    JSONValue jsource;
    jsource["name"] = "windows-driver-docs";
    jsource["url"]  = "https://github.com/MicrosoftDocs/windows-driver-docs";
    jsource["license"] = "CC-BY-4.0";
    jsource["date"] = Clock.currTime().toISOExtString();

    JSONValue j;
    j["version"] = 1;
    j["source"]  = jsource;
    j["docs"]    = jdocs;

    writefile("driver-docs.json", j.toString());
    writeln("wrote ", docs.length, " articles to driver-docs.json");

    chdir("..");
    chdir("..");
}

private JSONValue toJSON(ref DriverDoc doc)
{
    JSONValue jparameters = JSONValue(JSONValue[].init);
    foreach (ref DocParameter param; doc.parameters)
    {
        JSONValue jparam;
        jparam["name"] = param.name;
        jparam["description"] = param.description;
        jparameters.array ~= jparam;
    }

    JSONValue j;
    j["kind"] = doc.kind;
    j["name"] = doc.name;
    j["code"] = doc.code;
    j["title"] = doc.title;
    j["description"] = doc.description;
    j["path"] = doc.path;
    j["url"] = doc.url;
    if (doc.header.length)
        j["header"] = doc.header;
    if (doc.parameters.length)
        j["parameters"] = jparameters;
    j["html"] = doc.html;
    return j;
}

// The repository holds the docset one folder down, but pointing at that folder
// directly is just as reasonable, so take either.
private string resolveDocsRoot(string path)
{
    if (path.length == 0)
        throw new Exception("No windows-driver-docs path given");

    string inner = buildPath(path, "windows-driver-docs-pr");
    if (exists(buildPath(inner, DIR_BUGCHECK)))
        return inner;

    if (exists(buildPath(path, DIR_BUGCHECK)))
        return path;

    throw new Exception("'"~path~"' does not look like a windows-driver-docs checkout");
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

private string[] sortedFiles(string dir, string pattern)
{
    import std.algorithm.sorting : sort;

    if (exists(dir) == false)
        throw new Exception("Missing docset folder '"~dir~"'");

    string[] paths;
    foreach (DirEntry entry; dirEntries(dir, pattern, SpanMode.shallow))
        paths ~= entry.name;

    return sort(paths).release();
}

//
// Articles
//

// The article body, with its heading pulled off. Everything up to and including
// the first level 1 heading is metadata: the H1 repeats the title, and the page
// writes that itself.
private const(char)[][] splitTitle(const(char)[][] lines, out const(char)[] title)
{
    foreach (size_t i, const(char)[] line; lines)
    {
        const(char)[] stripped = strip(line);
        if (startsWith(stripped, "# ") == false)
            continue;

        title = unescapeMarkdown(strip(stripped[2..$]));
        return lines[i + 1..$];
    }

    return lines;
}

// Symbolic names carry underscores, which the articles escape in headings
private string unescapeMarkdown(const(char)[] text)
{
    char[] out_;
    for (size_t i; i < text.length; ++i)
    {
        if (text[i] == '\\' && i + 1 < text.length)
            ++i;
        out_ ~= text[i];
    }
    return cast(string)out_;
}

private DriverDoc parseBugCheck(string root, string path)
{
    DriverDoc doc;
    doc.kind = "bugcheck";
    doc.path = docPath(root, path);
    doc.url  = DOCSET_URL ~ "/" ~ stripExtension(doc.path);

    const(char)[][] lines = splitLines(cast(const(char)[])readfile(path));
    const(char)[][] body_;
    Frontmatter front = readFrontmatter(lines, body_);
    const(char)[] title;
    body_ = splitTitle(body_, title);

    // The bug check number is in the filename, which is the only place every
    // article spells it the same way: a few titles drop the "0x" prefix.
    doc.code = bugCheckCode(baseName(path));
    if (parseCode(doc.code, doc.id) == false)
        throw new Exception("Could not read a bug check code out of '"~path~"'");

    // The heading is taken over api_name: the live dump articles were copied
    // from the bug check they mirror and kept its api_name, so that field names
    // the wrong stop code on a handful of them.
    doc.name = symbolicFromTitle(title);
    if (doc.name.length == 0 && front.apiNames.length)
        doc.name = symbolicFromTitle(front.apiNames[0]);
    if (doc.name.length == 0)
        throw new Exception("No symbolic name in '"~path~"'");

    doc.title = title.length ? title.idup : front.title;
    doc.description = front.description;

    LinkResolver links = resolver(doc);
    doc.parameters = takeParameters(body_, links);
    doc.html = renderMarkdown(body_, links);

    if (doc.description.length == 0)
        doc.description = leadText(body_, links);
    doc.description = stripValueSentence(doc.description);

    return doc;
}

private DriverDoc parseProblemCode(string root, string path)
{
    DriverDoc doc;
    doc.kind = "cmprob";
    doc.path = docPath(root, path);
    doc.url  = DOCSET_URL ~ "/" ~ stripExtension(doc.path);

    const(char)[][] lines = splitLines(cast(const(char)[])readfile(path));
    const(char)[][] body_;
    Frontmatter front = readFrontmatter(lines, body_);
    const(char)[] title;
    body_ = splitTitle(body_, title);

    // "Code 24 - CM_PROB_DEVICE_NOT_THERE"
    doc.name = symbolicFromTitle(title);
    if (doc.name.length == 0)
        doc.name = toUpper(baseName(path, ".md")).replace("-", "_");

    doc.code = problemCode(title);
    if (doc.code.length == 0 || parseCode(doc.code, doc.id) == false)
        throw new Exception("Could not read a problem code out of '"~path~"'");

    doc.title = title.length ? title.idup : front.title;

    LinkResolver links = resolver(doc);
    doc.html = renderMarkdown(body_, links);

    // These articles set their description to the symbolic name, which says
    // nothing the entry does not already carry
    doc.description = front.description == doc.name ? null : front.description;
    if (doc.description.length == 0)
        doc.description = leadText(body_, links);

    return doc;
}

private LinkResolver resolver(ref DriverDoc doc)
{
    return LinkResolver(DOCSET_URL, dirName(doc.path), doc.url);
}

// "bug-check-0x1a2--win32k-callout-watchdog.md" -> "0x1a2"
private string bugCheckCode(string filename)
{
    enum PREFIX = "bug-check-0x";

    if (startsWith(filename, PREFIX) == false)
        return null;

    size_t end = PREFIX.length;
    while (end < filename.length && isHexDigit(filename[end]))
        ++end;

    return filename[PREFIX.length - 2..end]; // keeps the "0x"
}

private bool isHexDigit(char c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

// Last word of the title that reads like a symbolic name
private string symbolicFromTitle(const(char)[] title)
{
    foreach_reverse (const(char)[] word; split(title))
    {
        if (isSymbolic(word))
            return word.idup;
    }
    return null;
}

private bool isSymbolic(const(char)[] word)
{
    if (word.length < 2)
        return false;

    foreach (char c; word)
    {
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')
            continue;
        return false;
    }
    return indexOf(word, '_') > 0;
}

// "Code 24 - CM_PROB_DEVICE_NOT_THERE"
private string problemCode(const(char)[] title)
{
    const(char)[][] words = split(title);
    foreach (size_t i, const(char)[] word; words)
    {
        if (icmp(word, "code") != 0 || i + 1 >= words.length)
            continue;

        const(char)[] value = words[i + 1];
        foreach (char c; value)
        {
            if (c < '0' || c > '9')
                return null;
        }
        return value.idup;
    }
    return null;
}

// The parameter table is written out as data, so what it sits in comes out of
// the body rather than being rendered twice.
private DocParameter[] takeParameters(ref const(char)[][] body_, ref LinkResolver links)
{
    size_t start = body_.length;
    size_t end = body_.length;

    foreach (size_t i, const(char)[] line; body_)
    {
        const(char)[] stripped = strip(line);
        if (startsWith(stripped, "## ") == false)
            continue;

        if (start < body_.length) // section after it, so the section ends here
        {
            end = i;
            break;
        }

        if (endsWith(toLower(strip(stripped[3..$])), "parameters"))
            start = i;
    }

    TableRange range = void;
    Table tbl;

    if (start < body_.length)
    {
        tbl = extractTable(body_[start..end], links, range);
    }
    else
    {
        // A handful of articles drop the table straight under the title, with no
        // heading over it, so only the header cell says what it holds.
        tbl = extractTable(body_, links, range);
        if (tbl.header.length == 0 || icmp(tbl.header[0], "parameter") != 0)
            return null;

        start = range.start;
        end = range.end;
    }

    if (tbl.empty())
        return null;

    DocParameter[] parameters;
    foreach (string[] row; tbl.rows)
    {
        if (row.length < 2)
            continue;

        DocParameter param;
        param.name = row[0];
        param.description = row[1];
        parameters ~= param;
    }

    if (parameters.length == 0)
        return null;

    body_ = body_[0..start] ~ body_[end..$];
    return parameters;
}

// Nearly every bug check article opens by restating the code as prose ("The
// FOO bug check has a value of 0x000000FF."), which says nothing a listing does
// not already show in its own column. It comes off, unless it is all there is.
private string stripValueSentence(string description)
{
    ptrdiff_t at = indexOf(description, "has a value of");
    if (at < 0)
        return description;

    ptrdiff_t stop = indexOf(description[at..$], '.');
    if (stop < 0)
        return description;

    string rest = strip(description[at + stop + 1..$]);
    return rest.length ? rest : description;
}

// First paragraph of an article, as plain text, for articles whose frontmatter
// has no description worth using.
private string leadText(const(char)[][] body_, ref LinkResolver links)
{
    foreach (const(char)[] line; body_)
    {
        const(char)[] stripped = strip(line);
        if (stripped.length == 0 || stripped[0] == '#' || stripped[0] == '>' ||
            stripped[0] == '<' || stripped[0] == '|' || stripped[0] == '-')
            continue;

        return stripTags(renderInlineText(stripped, links));
    }
    return null;
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

    return cast(string)text
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", `"`)
        .strip();
}

//
// Symbolic mapping
//

// Point every article at the header its symbolic name comes from, and report
// the ones nothing defines. A code the two disagree on means one of the sides
// moved, which is worth knowing before the data ships.
private void mapSymbolics(ref DriverDoc[] docs, string headerspath)
{
    if (exists(headerspath) == false)
    {
        stderr.writeln("warning: '", headerspath, "' not found, symbolics left unmapped");
        return;
    }

    HeaderSymbolics known = readHeaderSymbolics(headerspath);

    size_t mapped;
    foreach (ref DriverDoc doc; docs)
    {
        string *header = doc.name in known.headers;
        if (header is null)
            continue;

        doc.header = *header;
        ++mapped;

        // Problem codes are ordinals of their own, they share no space with the
        // header symbolic that happens to carry the same name
        if (doc.kind != "bugcheck")
            continue;

        uint code = known.codes[doc.name];
        if (code != doc.id)
            stderr.writefln("warning: %s is %#x in %s, %#x in %s",
                doc.name, code, *header, doc.id, doc.path);
    }

    writefln("mapped %u of %u symbolics to a header", mapped, docs.length);
}

unittest
{
    assert(bugCheckCode("bug-check-0x1a2--win32k-callout-watchdog.md") == "0x1a2");
    assert(bugCheckCode("bug-check-0x1000007e--system-thread-m.md") == "0x1000007e");
    assert(bugCheckCode("bug-check-code-reference2.md") is null);

    assert(symbolicFromTitle("Bug Check 0x1: APC_INDEX_MISMATCH") == "APC_INDEX_MISMATCH");
    assert(symbolicFromTitle("Code 24 - CM_PROB_DEVICE_NOT_THERE") == "CM_PROB_DEVICE_NOT_THERE");
    assert(symbolicFromTitle("Bug check code reference") is null);

    assert(problemCode("Code 24 - CM_PROB_DEVICE_NOT_THERE") == "24");
    assert(problemCode("CM_PROB_DEVICE_NOT_THERE") is null);

    assert(unescapeMarkdown(`Bug Check 0x1: APC\_INDEX\_MISMATCH`) == "Bug Check 0x1: APC_INDEX_MISMATCH");
    assert(stripTags("A <strong>driver</strong> failed &amp; died.") == "A driver failed & died.");

    assert(stripValueSentence("The FOO bug check has a value of 0x1. It indicates a thing.") ==
        "It indicates a thing.");
    assert(stripValueSentence("The FOO bug check has a value of 0x1.") == // nothing else to say
        "The FOO bug check has a value of 0x1.");
    assert(stripValueSentence("A device is not present.") == "A device is not present.");
}
