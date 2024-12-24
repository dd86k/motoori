module utils;

import std.format : sformat;

string sformatWindowsCode(char[] buffer, uint code)
{
    return cast(string)sformat(buffer, "0x%x", code);
}

deprecated("Use parseCode")
bool unformatCode(ref uint code, const(char)[] input)
{
    import core.stdc.stdio : sscanf;
    import std.string : toStringz;
    
    return sscanf(input.toStringz, "%i", cast(int*)&code) != 1;
}
unittest
{
    uint code = void;
    assert(unformatCode(code, "0x20") == false);
    assert(code == 0x20);
}

import core.stdc.stdio : sscanf;
import std.string : toStringz;

uint parseCode(const(char)[] input, out bool success)
{
    uint code = void;
    success = sscanf(input.toStringz, "%i", cast(int*)&code) >= 1;
    return code;
}
unittest
{
    bool succ;
    assert(parseCode("0", succ) == 0);
    assert(succ);
    assert(parseCode("5", succ) == 5);
    assert(succ);
    assert(parseCode("0x5", succ) == 0x5);
    assert(succ);
    assert(parseCode("0x1000", succ) == 0x1000);
    assert(succ);
    assert(parseCode("0x88884444", succ) == 0x8888_4444);
    assert(succ);
    assert(parseCode("0xC0000005", succ) == 0xC000_0005);
    assert(succ);
    assert(parseCode("6 5 4", succ) == 6);
    assert(succ);
    
    parseCode("Hello", succ);
    assert(succ == false);
}

deprecated("Use plural(size_t,string,string)")
pragma(inline, true)
string plural(size_t count, string base, string singular, string multiple)
{
    return count == 1 ? base~singular : base~multiple;
}
string plural(size_t count, string single, string multi)
{
    return count == 1 ? single : multi;
}