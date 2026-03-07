module utils;

import std.format : sformat;

string sformatWindowsCode(char[] buffer, uint code)
{
    return cast(string)sformat(buffer, "0x%x", code);
}

import core.stdc.stdio : sscanf;

bool parseCode(const(char)[] input, out uint code)
{
    char[32] buffer = void;
    
    if (input.length >= buffer.length)
        throw new Exception("Buffer too small");
    
    buffer[0..input.length] = input[];
    buffer[input.length] = 0;
    
    return sscanf(buffer.ptr, "%i", cast(int*)&code) == 1;
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
    assert(parseCode("6 5 4", code));
    assert(code == 6);
    
    assert(parseCode("Hello", code) == false);
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