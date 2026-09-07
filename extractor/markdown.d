/// Markdown reader for the Microsoft documentation corpus.
///
/// Only the constructs those articles actually use are implemented, and the raw
/// HTML blocks the older ones carry are passed through as-is. Links are resolved
/// here rather than at serve time: a page rendered out of the database has no
/// source tree left to walk a relative path against.
module extract.markdown;

import std.array : Appender, appender;
import std.algorithm.searching : startsWith, endsWith;
import std.ascii : isAlpha, isAlphaNum, isDigit;
import std.path : buildNormalizedPath;
import std.string : indexOf, splitLines, strip, stripLeft, stripRight, toLower;

/// Frontmatter fields the extractors read.
struct Frontmatter
{
    string title;
    string description;
    string date;
    string[] apiNames;
}

/// Where relative links in a document point to.
struct LinkResolver
{
    string base; /// Docset base URL, without a trailing slash
    string dir;  /// Directory of the document, relative to the docset root
    string self; /// URL of the document itself, for bare fragment links
}

/// Split a document into its frontmatter and the lines that follow it.
Frontmatter readFrontmatter(const(char)[][] lines, out const(char)[][] rest)
{
    Frontmatter front;
    rest = lines;

    if (lines.length == 0 || strip(lines[0]) != "---")
        return front;

    string listkey;
    size_t i = 1;
    for (; i < lines.length; ++i)
    {
        const(char)[] line = stripRight(lines[i]);
        if (strip(line) == "---")
        {
            ++i;
            break;
        }

        if (startsWith(stripLeft(line), "- "))
        {
            if (listkey == "api_name")
                front.apiNames ~= unquote(strip(stripLeft(line)[2..$])).idup;
            continue;
        }

        ptrdiff_t colon = indexOf(line, ':');
        if (colon <= 0)
            continue;

        const(char)[] key = strip(line[0..colon]);
        const(char)[] value = strip(line[colon + 1..$]);
        listkey = value.length ? null : key.idup;

        switch (key) {
        case "title":       front.title       = unquote(value).idup; break;
        case "description": front.description = unquote(value).idup; break;
        case "ms.date":     front.date        = unquote(value).idup; break;
        default:
        }
    }

    rest = lines[i..$];
    return front;
}

/// Render a document body to HTML.
string renderMarkdown(const(char)[][] lines, ref LinkResolver links)
{
    Renderer renderer = Renderer(lines, links);
    return renderer.run();
}

/// One table, with its cells already rendered to HTML.
struct Table
{
    string[] header;
    string[][] rows;

    bool empty() const
    {
        return header.length == 0 && rows.length == 0;
    }
}

/// Lines a table was found on, so a caller can take it out of the document.
struct TableRange
{
    size_t start;
    size_t end; /// One past the last line
}

/// First table in the lines given, in either the pipe or the raw HTML form.
Table extractTable(const(char)[][] lines, ref LinkResolver links, out TableRange range)
{
    foreach (size_t i, const(char)[] line; lines)
    {
        const(char)[] stripped = strip(line);

        if (isTableStart(lines, i))
        {
            size_t end = i;
            while (end < lines.length && indexOf(lines[end], '|') >= 0)
                ++end;

            range = TableRange(i, end);
            return pipeTable(lines, i, links);
        }

        if (startsWith(toLower(stripped), "<table"))
        {
            size_t end = i;
            while (end < lines.length && toLower(strip(lines[end])) != "</table>")
                ++end;

            range = TableRange(i, end < lines.length ? end + 1 : end);
            return htmlTable(lines[i..$], links);
        }
    }

    return Table.init;
}

/// Escape text for use in HTML content.
string escapeHTML(const(char)[] text)
{
    Appender!string sink = appender!string;
    putEscaped(sink, text);
    return sink[];
}

/// Render a run of text, without the block markup that would surround it.
string renderInlineText(const(char)[] text, ref LinkResolver links)
{
    Appender!string sink = appender!string;
    renderInline(sink, text, links);
    return sink[];
}

private:

const(char)[] unquote(const(char)[] value)
{
    if (value.length >= 2 && (value[0] == '"' || value[0] == '\'') && value[$-1] == value[0])
        return value[1..$-1];
    return value;
}

void putEscaped(ref Appender!string sink, const(char)[] text)
{
    foreach (char c; text)
    {
        switch (c) {
        case '&':  sink.put("&amp;");  break;
        case '<':  sink.put("&lt;");   break;
        case '>':  sink.put("&gt;");   break;
        case '"':  sink.put("&quot;"); break;
        default:   sink.put(c);
        }
    }
}

//
// Links
//

string resolveURL(ref LinkResolver links, const(char)[] dest)
{
    dest = strip(dest);
    if (dest.length == 0)
        return null;

    // Already absolute, or something no rewrite would improve
    if (startsWith(dest, "http://") || startsWith(dest, "https://") ||
        startsWith(dest, "mailto:") || startsWith(dest, "//"))
        return dest.idup;

    // Fragment of the article itself
    if (dest[0] == '#')
        return links.self ~ dest.idup;

    // Site-absolute, e.g. /windows-hardware/drivers/ddi/...
    if (dest[0] == '/')
        return LEARN_BASE ~ dest.idup;

    const(char)[] path = dest;
    const(char)[] fragment;
    ptrdiff_t hash = indexOf(path, '#');
    if (hash >= 0)
    {
        fragment = path[hash..$];
        path = path[0..hash];
    }

    if (path.length == 0) // "#anchor" was handled above, this is a bare query
        return links.self ~ dest.idup;

    if (endsWith(path, ".md"))
        path = path[0..$-3];

    return links.base ~ "/" ~ buildNormalizedPath(links.dir, path.idup) ~ fragment.idup;
}

enum LEARN_BASE = "https://learn.microsoft.com/en-us";

//
// Block level
//

struct Renderer
{
    const(char)[][] lines;
    LinkResolver links;
    size_t index;
    Appender!string sink;

    this(const(char)[][] lines, ref LinkResolver links)
    {
        this.lines = lines;
        this.links = links;
        sink = appender!string;
    }

    string run()
    {
        while (index < lines.length)
        {
            const(char)[] line = lines[index];
            const(char)[] stripped = strip(line);

            if (stripped.length == 0)
            {
                ++index;
                continue;
            }

            if (startsWith(stripped, "```") || startsWith(stripped, "~~~"))
                fence();
            else if (stripped[0] == '#' && headingLevel(stripped))
                heading();
            else if (stripped[0] == '>')
                quote();
            else if (stripped[0] == '<')
                rawHTML();
            else if (isTableStart(lines, index))
                table();
            else if (isRule(stripped))
            {
                sink.put("<hr>");
                ++index;
            }
            else if (listMarker(line).length)
                list();
            else
                paragraph();
        }

        return sink[];
    }

    void fence()
    {
        const(char)[] opening = strip(lines[index]);
        const(char)[] delim = opening[0..3];
        ++index;

        sink.put("<pre><code>");
        for (; index < lines.length; ++index)
        {
            if (startsWith(strip(lines[index]), delim))
            {
                ++index;
                break;
            }

            putEscaped(sink, lines[index]);
            sink.put('\n');
        }
        sink.put("</code></pre>");
    }

    void heading()
    {
        const(char)[] stripped = strip(lines[index]);
        size_t level = headingLevel(stripped);
        ++index;

        // The article title is written out separately, so what is left starts at
        // <h2> and the levels below it shift down with it.
        if (level < 2)
            level = 2;
        if (level > 6)
            level = 6;

        sink.put("<h");
        sink.put(cast(char)('0' + level));
        sink.put('>');
        inline(strip(stripped[headingLevel(stripped)..$]));
        sink.put("</h");
        sink.put(cast(char)('0' + level));
        sink.put('>');
    }

    // A note, warning or tip renders as a blockquote with its kind named, since
    // the stylesheet has no callout of its own to hand these to.
    void quote()
    {
        const(char)[][] inner;
        for (; index < lines.length; ++index)
        {
            const(char)[] stripped = stripLeft(lines[index]);
            if (stripped.length == 0 || stripped[0] != '>')
                break;

            stripped = stripped[1..$];
            if (stripped.length && stripped[0] == ' ')
                stripped = stripped[1..$];
            inner ~= stripped;
        }

        string kind;
        if (inner.length && startsWith(strip(inner[0]), "[!"))
        {
            const(char)[] tag = strip(inner[0]);
            ptrdiff_t end = indexOf(tag, ']');
            if (end > 2)
            {
                kind = titleCase(tag[2..end]);
                inner = inner[1..$];
            }
        }

        sink.put("<blockquote>");
        if (kind.length)
        {
            sink.put("<p><strong>");
            putEscaped(sink, kind);
            sink.put("</strong></p>");
        }
        sink.put(renderBlocks(inner, links));
        sink.put("</blockquote>");
    }

    // Passed through untouched, bar the link rewriting: these are hand-written
    // tables from articles that predate the Markdown conversion, and rebuilding
    // them from a parse would only lose their cell markup.
    void rawHTML()
    {
        const(char)[] name = tagName(strip(lines[index]));
        const(char)[] closing = isContainerTag(name) ? "</" ~ name ~ ">" : null;

        Appender!string block = appender!string;
        for (; index < lines.length; ++index)
        {
            const(char)[] line = lines[index];
            const(char)[] stripped = strip(line);

            if (closing is null && stripped.length == 0)
                break;

            block.put(line);
            block.put('\n');

            if (closing.length && toLower(stripped) == closing)
            {
                ++index;
                break;
            }
        }

        sink.put(rewriteHTML(block[], links));
    }

    void table()
    {
        size_t start = index;
        while (index < lines.length && indexOf(lines[index], '|') >= 0)
            ++index;

        Table tbl = pipeTable(lines, start, links);
        putTable(sink, tbl);
    }

    void list()
    {
        Marker first = listMarker(lines[index]);
        string tag = first.ordered ? "ol" : "ul";

        sink.put('<');
        sink.put(tag);
        sink.put('>');

        while (index < lines.length)
        {
            // Items separated by a blank line still belong to the same list
            size_t next = index;
            while (next < lines.length && strip(lines[next]).length == 0)
                ++next;
            if (next >= lines.length)
                break;

            Marker marker = listMarker(lines[next]);
            if (marker.length == 0 || marker.indent != first.indent || marker.ordered != first.ordered)
                break;
            index = next;

            // The item runs until the next marker at this level, or until a line
            // that is neither indented under it nor a lazy continuation of it.
            const(char)[][] item = [ lines[index][marker.indent + marker.length..$] ];
            ++index;
            for (; index < lines.length; ++index)
            {
                const(char)[] line = lines[index];
                const(char)[] stripped = strip(line);

                if (stripped.length == 0)
                {
                    // A blank line only ends the item if nothing indented follows
                    if (index + 1 >= lines.length || leadingSpaces(lines[index + 1]) <= first.indent)
                        break;
                    item ~= "";
                    continue;
                }

                size_t indent = leadingSpaces(line);
                if (indent <= first.indent && listMarker(line).length)
                    break;
                if (indent <= first.indent && indent == 0 && isBlockStart(lines, index))
                    break;

                item ~= indent > first.indent ? line[first.indent + 1..$] : line;
            }

            sink.put("<li>");
            sink.put(soleParagraph(renderBlocks(item, links)));
            sink.put("</li>");
        }

        sink.put("</");
        sink.put(tag);
        sink.put('>');
    }

    void paragraph()
    {
        sink.put("<p>");
        for (bool first = true; index < lines.length; ++index, first = false)
        {
            const(char)[] line = lines[index];
            const(char)[] stripped = strip(line);

            if (stripped.length == 0)
                break;
            if (first == false && isBlockStart(lines, index))
                break;

            if (first == false)
                sink.put(' ');
            inline(stripped);
        }
        sink.put("</p>");
    }

    void inline(const(char)[] text)
    {
        renderInline(sink, text, links);
    }
}

string renderBlocks(const(char)[][] lines, ref LinkResolver links)
{
    Renderer renderer = Renderer(lines, links);
    return renderer.run();
}

// A list item that is one plain paragraph reads better without it
string soleParagraph(string html)
{
    if (startsWith(html, "<p>") == false || endsWith(html, "</p>") == false)
        return html;

    string inner = html[3..$-4];
    return indexOf(inner, "<p>") >= 0 ? html : inner;
}

size_t headingLevel(const(char)[] stripped)
{
    size_t level;
    while (level < stripped.length && stripped[level] == '#')
        ++level;

    if (level == 0 || level > 6 || level >= stripped.length || stripped[level] != ' ')
        return 0;

    return level;
}

bool isRule(const(char)[] stripped)
{
    if (stripped.length < 3)
        return false;

    char c = stripped[0];
    if (c != '-' && c != '*' && c != '_')
        return false;

    foreach (char ch; stripped)
    {
        if (ch != c && ch != ' ')
            return false;
    }
    return true;
}

struct Marker
{
    size_t indent;
    size_t length; /// Zero when the line does not start a list item
    bool ordered;
}

Marker listMarker(const(char)[] line)
{
    Marker marker;
    marker.indent = leadingSpaces(line);

    const(char)[] rest = line[marker.indent..$];
    if (rest.length < 2)
        return marker;

    if ((rest[0] == '-' || rest[0] == '*' || rest[0] == '+') && rest[1] == ' ')
    {
        marker.length = 2;
        return marker;
    }

    size_t digits;
    while (digits < rest.length && isDigit(rest[digits]))
        ++digits;

    if (digits && digits + 1 < rest.length && rest[digits] == '.' && rest[digits + 1] == ' ')
    {
        marker.length = digits + 2;
        marker.ordered = true;
    }

    return marker;
}

size_t leadingSpaces(const(char)[] line)
{
    size_t i;
    while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
        ++i;
    return i;
}

// Whether a line inside a paragraph or list item opens a block of its own
bool isBlockStart(const(char)[][] lines, size_t i)
{
    const(char)[] stripped = strip(lines[i]);
    if (stripped.length == 0)
        return true;

    return headingLevel(stripped) != 0 ||
        stripped[0] == '>' || stripped[0] == '<' ||
        startsWith(stripped, "```") || isRule(stripped) ||
        listMarker(lines[i]).length != 0 || isTableStart(lines, i);
}

//
// Tables
//

bool isTableStart(const(char)[][] lines, size_t i)
{
    if (indexOf(lines[i], '|') < 0 || i + 1 >= lines.length)
        return false;

    return isDelimiterRow(lines[i + 1]);
}

bool isDelimiterRow(const(char)[] line)
{
    const(char)[] stripped = strip(line);
    if (stripped.length == 0 || indexOf(stripped, '-') < 0)
        return false;

    foreach (char c; stripped)
    {
        if (c != '-' && c != '|' && c != ':' && c != ' ')
            return false;
    }
    return true;
}

const(char)[][] splitCells(const(char)[] line)
{
    const(char)[] row = strip(line);
    if (row.length && row[0] == '|')
        row = row[1..$];
    if (row.length && row[$-1] == '|')
        row = row[0..$-1];

    const(char)[][] cells;
    size_t start;
    for (size_t i; i < row.length; ++i)
    {
        if (row[i] == '\\') // an escaped pipe belongs to the cell
        {
            ++i;
            continue;
        }
        if (row[i] != '|')
            continue;

        cells ~= strip(row[start..i]);
        start = i + 1;
    }
    cells ~= strip(row[start..$]);

    return cells;
}

Table pipeTable(const(char)[][] lines, size_t start, ref LinkResolver links)
{
    Table tbl;

    foreach (const(char)[] cell; splitCells(lines[start]))
        tbl.header ~= renderInlineText(cell, links);

    for (size_t i = start + 2; i < lines.length; ++i)
    {
        if (indexOf(lines[i], '|') < 0)
            break;

        string[] row;
        foreach (const(char)[] cell; splitCells(lines[i]))
            row ~= dropStrayParagraphEnds(renderInlineText(cell, links));
        tbl.rows ~= row;
    }

    return tbl;
}

// Cells of a hand-written table, with their own markup kept but the paragraph
// wrapper the conversion left around single values dropped.
Table htmlTable(const(char)[][] lines, ref LinkResolver links)
{
    Appender!string joined = appender!string;
    foreach (const(char)[] line; lines)
    {
        joined.put(line);
        joined.put('\n');

        if (toLower(strip(line)) == "</table>")
            break;
    }

    string source = rewriteHTML(joined[], links);
    string lowered = toLower(source);

    Table tbl;
    size_t pos;
    while (true)
    {
        ptrdiff_t open = indexOf(lowered[pos..$], "<tr");
        if (open < 0)
            break;

        size_t rowstart = pos + open;
        ptrdiff_t close = indexOf(lowered[rowstart..$], "</tr>");
        size_t rowend = close < 0 ? source.length : rowstart + close;

        string[] cells;
        bool header;
        size_t cellpos = rowstart;
        while (cellpos < rowend)
        {
            ptrdiff_t cellopen = indexOf(lowered[cellpos..rowend], "<td");
            ptrdiff_t headopen = indexOf(lowered[cellpos..rowend], "<th");
            bool ishead = headopen >= 0 && (cellopen < 0 || headopen < cellopen);
            ptrdiff_t at = ishead ? headopen : cellopen;
            if (at < 0)
                break;

            size_t cellstart = cellpos + at;
            ptrdiff_t gt = indexOf(source[cellstart..rowend], '>');
            if (gt < 0)
                break;

            size_t inner = cellstart + gt + 1;
            ptrdiff_t cellclose = indexOf(lowered[inner..rowend], ishead ? "</th>" : "</td>");
            size_t innerend = cellclose < 0 ? rowend : inner + cellclose;

            header = header || ishead;
            cells ~= unwrapParagraph(strip(source[inner..innerend]));
            cellpos = innerend + 5;
        }

        if (cells.length)
        {
            if (header && tbl.header.length == 0)
                tbl.header = cells;
            else
                tbl.rows ~= cells;
        }

        pos = rowend + 5;
        if (pos >= source.length)
            break;
    }

    return tbl;
}

string unwrapParagraph(const(char)[] html)
{
    const(char)[] inner = html;
    if (startsWith(toLower(inner), "<p>") && endsWith(toLower(inner), "</p>"))
    {
        inner = strip(inner[3..$-4]);
        if (indexOf(toLower(inner), "<p>") >= 0) // several paragraphs, keep them
            return dropStrayParagraphEnds(html);
    }
    return dropStrayParagraphEnds(inner);
}

// A few cells in the hand-written tables close a paragraph they never opened.
// The table around them is written here rather than passed through, so the
// stray tag comes off instead of ending up in markup this side is answerable for.
string dropStrayParagraphEnds(const(char)[] html)
{
    Appender!string sink = appender!string;

    size_t open;
    for (size_t i; i < html.length;)
    {
        if (html[i] != '<')
        {
            sink.put(html[i]);
            ++i;
            continue;
        }

        size_t end = indexOfFrom(html, '>', i + 1);
        if (end >= html.length)
        {
            sink.put(html[i..$]);
            break;
        }

        const(char)[] tag = toLower(html[i..end + 1]);
        if (startsWith(tag, "<p>") || startsWith(tag, "<p "))
            ++open;
        else if (tag == "</p>")
        {
            if (open == 0)
            {
                i = end + 1;
                continue;
            }
            --open;
        }

        sink.put(html[i..end + 1]);
        i = end + 1;
    }

    return sink[];
}

void putTable(ref Appender!string sink, ref Table tbl)
{
    sink.put(`<table class="table">`);
    if (tbl.header.length)
    {
        sink.put("<thead><tr>");
        foreach (string cell; tbl.header)
        {
            sink.put("<th>");
            sink.put(cell);
            sink.put("</th>");
        }
        sink.put("</tr></thead>");
    }

    sink.put("<tbody>");
    foreach (string[] row; tbl.rows)
    {
        sink.put("<tr>");
        foreach (string cell; row)
        {
            sink.put("<td>");
            sink.put(cell);
            sink.put("</td>");
        }
        sink.put("</tr>");
    }
    sink.put("</tbody></table>");
}

//
// Inline level
//

void renderInline(ref Appender!string sink, const(char)[] text, ref LinkResolver links)
{
    for (size_t i; i < text.length;)
    {
        char c = text[i];

        switch (c) {
        case '\\': // escape, the next character stands for itself
            if (i + 1 < text.length)
            {
                putEscaped(sink, text[i + 1..i + 2]);
                i += 2;
                continue;
            }
            break;
        case '`':
            size_t end = indexOfFrom(text, '`', i + 1);
            if (end < text.length)
            {
                sink.put("<code>");
                putEscaped(sink, text[i + 1..end]);
                sink.put("</code>");
                i = end + 1;
                continue;
            }
            break;
        case '*':
            // Only asterisks carry emphasis here: underscores turn up inside
            // symbolic names far more often than they delimit anything.
            bool strong = i + 1 < text.length && text[i + 1] == '*';
            const(char)[] delim = strong ? "**" : "*";
            size_t start = i + delim.length;
            size_t end = indexOfFrom(text, delim, start);
            if (end < text.length && end > start)
            {
                sink.put(strong ? "<strong>" : "<em>");
                renderInline(sink, text[start..end], links);
                sink.put(strong ? "</strong>" : "</em>");
                i = end + delim.length;
                continue;
            }
            break;
        case '!':
            // Images are dropped, the alt text carries what they said
            if (i + 1 < text.length && text[i + 1] == '[')
            {
                size_t textend = indexOfFrom(text, ']', i + 2);
                if (textend < text.length)
                {
                    renderInline(sink, text[i + 2..textend], links);
                    i = skipLinkTarget(text, textend + 1);
                    continue;
                }
            }
            break;
        case '[':
            size_t labelend = matchBracket(text, i);
            if (labelend < text.length && labelend + 1 < text.length && text[labelend + 1] == '(')
            {
                size_t destend = indexOfFrom(text, ')', labelend + 2);
                if (destend < text.length)
                {
                    const(char)[] dest = text[labelend + 2..destend];
                    ptrdiff_t space = indexOf(dest, ' '); // link title, dropped
                    if (space >= 0)
                        dest = dest[0..space];

                    sink.put(`<a href="`);
                    putEscaped(sink, resolveURL(links, dest));
                    sink.put(`">`);
                    renderInline(sink, text[i + 1..labelend], links);
                    sink.put("</a>");
                    i = destend + 1;
                    continue;
                }
            }
            break;
        case '<':
            size_t end = indexOfFrom(text, '>', i + 1);
            if (end < text.length && i + 1 < text.length &&
                (isAlpha(text[i + 1]) || text[i + 1] == '/'))
            {
                sink.put(rewriteTag(text[i..end + 1], links));
                i = end + 1;
                continue;
            }
            break;
        case '&':
            if (isEntity(text[i..$]))
            {
                size_t end = indexOfFrom(text, ';', i + 1);
                sink.put(text[i..end + 1]);
                i = end + 1;
                continue;
            }
            break;
        default:
        }

        putEscaped(sink, text[i..i + 1]);
        ++i;
    }
}

size_t indexOfFrom(const(char)[] text, char c, size_t from)
{
    for (size_t i = from; i < text.length; ++i)
    {
        if (text[i] == c)
            return i;
    }
    return text.length;
}

size_t indexOfFrom(const(char)[] text, const(char)[] needle, size_t from)
{
    if (needle.length == 0 || from >= text.length)
        return text.length;

    for (size_t i = from; i + needle.length <= text.length; ++i)
    {
        if (text[i..i + needle.length] == needle)
            return i;
    }
    return text.length;
}

// Bracketed link labels nest, e.g. [see [!analyze](...)](...)
size_t matchBracket(const(char)[] text, size_t open)
{
    size_t depth;
    for (size_t i = open; i < text.length; ++i)
    {
        if (text[i] == '\\')
        {
            ++i;
            continue;
        }
        if (text[i] == '[')
            ++depth;
        else if (text[i] == ']' && --depth == 0)
            return i;
    }
    return text.length;
}

size_t skipLinkTarget(const(char)[] text, size_t i)
{
    if (i < text.length && text[i] == '(')
    {
        size_t end = indexOfFrom(text, ')', i + 1);
        if (end < text.length)
            return end + 1;
    }
    return i;
}

bool isEntity(const(char)[] text)
{
    if (text.length < 3 || text[0] != '&')
        return false;

    size_t i = text[1] == '#' ? 2 : 1;
    size_t start = i;
    while (i < text.length && isAlphaNum(text[i]))
        ++i;

    return i > start && i < text.length && text[i] == ';';
}

string titleCase(const(char)[] word)
{
    char[] text = new char[word.length];
    foreach (size_t i, char c; word)
    {
        text[i] = i == 0
            ? (c >= 'a' && c <= 'z' ? cast(char)(c - 32) : c)
            : (c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c);
    }
    return cast(string)text;
}

//
// Raw HTML
//

const(char)[] tagName(const(char)[] stripped)
{
    size_t i = 1;
    while (i < stripped.length && isAlphaNum(stripped[i]))
        ++i;
    return toLower(stripped[1..i]);
}

bool isContainerTag(const(char)[] name)
{
    switch (name) {
    case "table", "ul", "ol", "dl", "div", "blockquote", "pre":
        return true;
    default:
        return false;
    }
}

// Rewrite the hrefs of a passed-through block, so its links leave the docset
// the same way the Markdown ones do.
string rewriteHTML(const(char)[] html, ref LinkResolver links)
{
    Appender!string sink = appender!string;

    for (size_t i; i < html.length;)
    {
        if (html[i] != '<')
        {
            sink.put(html[i]);
            ++i;
            continue;
        }

        size_t end = indexOfFrom(html, '>', i + 1);
        if (end >= html.length)
        {
            sink.put(html[i..$]);
            break;
        }

        sink.put(rewriteTag(html[i..end + 1], links));
        i = end + 1;
    }

    return sink[];
}

string rewriteTag(const(char)[] tag, ref LinkResolver links)
{
    ptrdiff_t href = indexOf(toLower(tag), `href="`);
    if (href < 0)
        return tag.idup;

    size_t start = href + 6;
    ptrdiff_t close = indexOf(tag[start..$], '"');
    if (close < 0)
        return tag.idup;

    size_t end = start + close;
    return tag[0..start].idup ~ escapeHTML(resolveURL(links, tag[start..end])) ~ tag[end..$].idup;
}

//
// Tests
//

unittest
{
    const(char)[][] lines = splitLines(cast(const(char)[])
        "---\ntitle: Bug Check 0x1 APC_INDEX_MISMATCH\napi_name:\n- APC_INDEX_MISMATCH\n---\n\nBody text.");
    const(char)[][] rest;
    Frontmatter front = readFrontmatter(lines, rest);

    assert(front.title == "Bug Check 0x1 APC_INDEX_MISMATCH");
    assert(front.apiNames == [ "APC_INDEX_MISMATCH" ]);
    assert(strip(rest[$-1]) == "Body text.");
}

unittest
{
    LinkResolver links = LinkResolver("https://learn.microsoft.com/en-us/windows-hardware/drivers",
        "debugger", "https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/bug-check-0x1");

    assert(resolveURL(links, "crash-dump-files.md") ==
        "https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/crash-dump-files");
    assert(resolveURL(links, "../debuggercmds/-analyze.md") ==
        "https://learn.microsoft.com/en-us/windows-hardware/drivers/debuggercmds/-analyze");
    assert(resolveURL(links, "/windows-hardware/drivers/ddi/ntddk/nf-ntddk-keentercriticalregion") ==
        "https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/nf-ntddk-keentercriticalregion");
    assert(resolveURL(links, "https://www.windows.com/stopcode") == "https://www.windows.com/stopcode");
    assert(resolveURL(links, "#cause") ==
        "https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/bug-check-0x1#cause");
}

unittest
{
    LinkResolver links = LinkResolver("https://example.com", "debugger", "https://example.com/doc");

    assert(renderInlineText("*Thread* >**SpecialApcDisable**", links) ==
        "<em>Thread</em> &gt;<strong>SpecialApcDisable</strong>");
    // Underscores are left alone, symbolic names are full of them
    assert(renderInlineText("APC_INDEX_MISMATCH", links) == "APC_INDEX_MISMATCH");
    assert(renderInlineText("`!analyze -v`", links) == "<code>!analyze -v</code>");
    assert(renderInlineText("[analyze](-analyze.md)", links) ==
        `<a href="https://example.com/debugger/-analyze">analyze</a>`);
    assert(renderInlineText("a<br />b", links) == "a<br />b");
    assert(renderInlineText("5 < 6 & 7", links) == "5 &lt; 6 &amp; 7");
    assert(renderInlineText(`\|`, links) == "|");
}

unittest
{
    LinkResolver links = LinkResolver("https://example.com", "debugger", "https://example.com/doc");
    const(char)[][] lines = splitLines(cast(const(char)[])(
        "## Cause\n\nA driver did something.\n\n" ~
        "| Parameter | Description |\n| --- | --- |\n| 1 | The address. |\n\n" ~
        "- First\n- Second\n"));

    string html = renderMarkdown(lines, links);
    assert(html ==
        "<h2>Cause</h2><p>A driver did something.</p>" ~
        `<table class="table"><thead><tr><th>Parameter</th><th>Description</th></tr></thead>` ~
        "<tbody><tr><td>1</td><td>The address.</td></tr></tbody></table>" ~
        "<ul><li>First</li><li>Second</li></ul>");
}

unittest
{
    LinkResolver links = LinkResolver("https://example.com", "debugger", "https://example.com/doc");
    const(char)[][] lines = splitLines(cast(const(char)[])(
        "<table>\n<thead>\n<tr class=\"header\">\n<th align=\"left\">Parameter</th>\n" ~
        "<th align=\"left\">Description</th>\n</tr>\n</thead>\n<tbody>\n" ~
        "<tr class=\"odd\">\n<td align=\"left\"><p>1</p></td>\n" ~
        "<td align=\"left\"><p>The address.</p></td>\n</tr>\n</tbody>\n</table>\n"));

    TableRange range = void;
    Table tbl = extractTable(lines, links, range);
    assert(tbl.header == [ "Parameter", "Description" ]);
    assert(tbl.rows == [ [ "1", "The address." ] ]);
    assert(range == TableRange(0, lines.length));
}
