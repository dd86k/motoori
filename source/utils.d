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

pragma(inline, true)
string plural(size_t count, string single, string multi)
{
    return count == 1 ? single : multi;
}