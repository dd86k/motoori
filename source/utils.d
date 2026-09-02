module utils;

import std.format : sformat;

string sformatWindowsCode(char[] buffer, uint code)
{
    return cast(string)sformat(buffer, "0x%x", code);
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