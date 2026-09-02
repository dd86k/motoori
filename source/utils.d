module utils;

import std.format : sformat;
import ddhttpd : HTTPReply, HTTPRequest;

// Origin used to make canonical, og:url, and sitemap URLs absolute. Null means:
// derive it from the request, which is all a local run or a single-host
// deployment needs.
__gshared string base_url;

string sformatWindowsCode(char[] buffer, uint code)
{
    return cast(string)sformat(buffer, "0x%x", code);
}

/// Zero-padded form, the one /windows/code/:code points its canonical at.
///
/// Listings display the short form but must link the padded one: the same code
/// is reachable as 5, 0x5 and 0x00000005, and a link to any of the others lands
/// on a page that immediately disclaims itself.
string sformatWindowsCodeURL(char[] buffer, uint code)
{
    return cast(string)sformat(buffer, "0x%08x", code);
}

/// Parse an error code as hexadecimal ("0x1f") or decimal ("31").
///
/// A leading '-' wraps into the 32-bit space, since runtimes and shells
/// routinely hand out codes as signed decimals (e.g., -1073741819 for
/// STATUS_ACCESS_VIOLATION). Trailing garbage is rejected so that a query
/// like "6 5 4" falls through to a text search instead of matching code 6.
bool parseCode(const(char)[] input, out uint code)
{
    import std.conv : parse, ConvException;

    if (input.length == 0)
        return false;

    bool negative = input[0] == '-';
    if (negative || input[0] == '+')
        input = input[1..$];

    // parse() takes no prefix, so scope it out and pick the radix from it
    uint radix = 10;
    if (input.length > 2 && input[0] == '0' && (input[1] == 'x' || input[1] == 'X'))
    {
        radix = 16;
        input = input[2..$];
    }

    uint value = void;
    try value = parse!uint(input, radix);
    catch (ConvException)
        return false;

    if (input.length) // parse() stops at the first invalid digit, leaving it here
        return false;
    if (negative && value > 2_147_483_648)
        return false;

    code = negative ? -value : value;
    return true;
}
unittest
{
    uint code;
    assert(parseCode("0", code));
    assert(code == 0);
    assert(parseCode("5", code));
    assert(code == 5);
    assert(parseCode("0x5", code));
    assert(code == 0x5);
    assert(parseCode("0x1000", code));
    assert(code == 0x1000);
    assert(parseCode("0x88884444", code));
    assert(code == 0x8888_4444);
    assert(parseCode("0xC0000005", code));
    assert(code == 0xC000_0005);
    assert(parseCode("0Xc0000005", code));
    assert(code == 0xC000_0005);

    // Unsigned decimals, as printed by shells and runtimes
    assert(parseCode("3221225477", code));
    assert(code == 0xC000_0005);
    assert(parseCode("4294967295", code));
    assert(code == uint.max);

    // Signed decimals, a common sight from cmd
    assert(parseCode("-1073741819", code));
    assert(code == 0xC000_0005);
    assert(parseCode("-1", code));
    assert(code == uint.max);
    assert(parseCode("-2147483648", code));
    assert(code == 0x8000_0000);

    assert(parseCode("4294967296", code) == false);
    assert(parseCode("0x100000000", code) == false);
    assert(parseCode("-2147483649", code) == false);

    assert(parseCode("6 5 4", code) == false);
    assert(parseCode("12abc", code) == false);
    assert(parseCode("0x5g", code) == false);
    assert(parseCode("Hello", code) == false);
    assert(parseCode("0x", code) == false);
    assert(parseCode("-", code) == false);
    assert(parseCode("", code) == false);
}

/// ASCII-only toLower into a caller-provided buffer. Returns a slice of buf.
char[] toLowerBuf(char[] buf, const(char)[] input)
{
    if (input.length > buf.length)
        return null;
    foreach (idx, c; input)
        buf[idx] = (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
    return buf[0 .. input.length];
}
unittest
{
    char[32] buf;
    assert(toLowerBuf(buf, "Hello") == "hello");
    assert(toLowerBuf(buf, "ALLCAPS") == "allcaps");
    assert(toLowerBuf(buf, "already") == "already");
    assert(toLowerBuf(buf, "MiXeD_CaSe123") == "mixed_case123");
    assert(toLowerBuf(buf, "") == "");

    char[4] tiny;
    assert(toLowerBuf(tiny, "toolong") is null);
    assert(toLowerBuf(tiny, "FOUR") == "four");
}

pragma(inline, true)
string plural(size_t count, string single, string multi)
{
    return count == 1 ? single : multi;
}

// Search engines cut descriptions off around here, and module messages can run
// for paragraphs, so the tail is dropped on a word boundary.
enum DESCRIPTION_MAX = 160;

bool isSpace(char c)
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

/// Cut text down to max bytes without splitting a UTF-8 sequence.
const(char)[] limit(const(char)[] text, size_t max)
{
    if (text.length <= max)
        return text;

    while (max && (text[max] & 0xc0) == 0x80) // continuation byte
        --max;

    return text[0..max];
}
unittest
{
    assert(limit("hello", 10) == "hello");
    assert(limit("hello", 5)  == "hello");
    assert(limit("hello", 3)  == "hel");
    assert(limit("héllo", 2)  == "h"); // would have split the two-byte 'é'
    assert(limit("héllo", 3)  == "hé");
    assert(limit("", 4) == "");
}

/// Write text into a content="" attribute: whitespace collapsed, escaped, and
/// cut to a length a search result can show.
void putSummary(ref HTTPReply buffer, const(char)[] text)
{
    const(char)[] head = limit(text, DESCRIPTION_MAX);
    bool truncated = head.length < text.length;
    if (truncated)
    {
        foreach_reverse (i, char c; head)
        {
            if (isSpace(c))
            {
                head = head[0..i];
                break;
            }
        }
    }

    // A run of whitespace only becomes a separator once there is text on both
    // sides of it, which drops the leading and trailing ones along the way.
    bool started;
    bool pending;
    foreach (char c; head)
    {
        if (isSpace(c))
        {
            pending = started;
            continue;
        }
        if (pending)
        {
            buffer.put(' ');
            pending = false;
        }
        started = true;
        switch (c) {
        case '<':  buffer.put("&lt;");   break;
        case '>':  buffer.put("&gt;");   break;
        case '&':  buffer.put("&amp;");  break;
        case '"':  buffer.put("&quot;"); break;
        case '\'': buffer.put("&#39;");  break;
        default:   buffer.put(c);        break;
        }
    }

    if (truncated)
        buffer.put("&hellip;");
}
unittest
{
    static const(char)[] summary(const(char)[] text)
    {
        HTTPReply reply = HTTPReply.create(512);
        putSummary(reply, text);
        return reply[];
    }

    assert(summary("Access is denied.") == "Access is denied.");
    assert(summary("  padded  ") == "padded");
    assert(summary("a\r\n\tb   c") == "a b c");
    assert(summary(`<b>&"'`) == "&lt;b&gt;&amp;&quot;&#39;");

    // Cut on a word boundary, marker outside the escaped text
    string source;
    foreach (i; 0..40)
        source ~= "filler ";
    const(char)[] cut = summary(source);
    assert(cut[0..14] == "filler filler ");
    assert(cut[$-14..$] == "filler&hellip;"); // never mid-word
    assert(cut.length - "&hellip;".length <= DESCRIPTION_MAX);
}

/// Accept only what a hostname and port can legally hold.
///
/// A Host header is client-supplied and lands in a URL attribute, so anything
/// else is rejected outright rather than escaped into something that still
/// points somewhere unintended.
bool validHost(const(char)[] host)
{
    if (host.length == 0 || host.length > 260)
        return false;

    foreach (char c; host)
    {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
            continue;
        switch (c) {
        case '.', '-', ':', '[', ']': continue;
        default: return false;
        }
    }

    return true;
}
unittest
{
    assert(validHost("oedb.dd86k.xyz"));
    assert(validHost("localhost:8999"));
    assert(validHost("[::1]:8999"));
    assert(validHost("") == false);
    assert(validHost(`evil.example"><script>`) == false);
    assert(validHost("evil.example/path") == false);
    assert(validHost("evil example") == false);
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