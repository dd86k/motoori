module extract.source.crt;

import std.stdio, std.file;
import std.string : toLower;
import std.json;
import std.string;
import core.stdc.string : strerror, strncmp, strlen;
import extract.utils;
import extract.platform;

immutable string filename_crt = toLower(CRT_NAME)~"_"~toLower(PLATFORM)~".json";

void processCrtMessages(string outdir, string locale = "en-US")
{
    mkchdir(outdir);
    mkchdir("crt");
    
    // The "message not found" message
    version (CRuntime_Musl)
        enum UNKNOWN_MSG = "No error information"; // musl
    else // Glibc, MSVC
        enum UNKNOWN_MSG = "Unknown error"; // glibc/msvc
    
    // A little slower but a lot less error-prone than manually writing json
    JSONValue j;
    j["version"] = 1;
    j["name"] = CRT_NAME;
    j["full"] = CRT_FULL;
    j["arch"] = PLATFORM;
    //j["locale"] = locale;
    
    // Generally starts from 0 to some number in the few thousands
    // Musl Generic: up to 133
    // Musl MIPS: up to 168, and an 1133 code
    JSONValue jmessages = JSONValue(JSONValue[].init); // for older D compilers
    for (int code = 0; code <= 2000; ++code)
    {
        char *s = strerror(code);
        if (s == null)
            continue;
        
        scope string e = cast(string)fromStringz( strerror(code) );
        if (e == UNKNOWN_MSG)
            continue;
        
        // Recent versions of Glibc will prepend the unknown msg with
        // the code, and we *do not* want that
        version (CRuntime_Glibc)
        {
            if (startsWith(e, UNKNOWN_MSG))
                continue;
        }
        
        JSONValue jmsg;
        jmsg["code"] = code;
        jmsg["message"] = e.idup;
        jmessages.array ~= jmsg;
    }
    j["messages"] = jmessages;
    
    writefile(filename_crt, j.toString());
    
    chdir("..");
    chdir("..");
}
