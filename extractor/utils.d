module extract.utils;

public import std.file;

public alias writefile = std.file.write;
public alias readfile = std.file.read;

import std.file : exists, chdir, mkdir;

void mkchdir(string path)
{
    if (exists(path) == false)
        mkdir(path);
    
    chdir(path);
}

const(char)[] getOSVersion()
{
version (Windows)
{
    import core.sys.windows.winnt : OSVERSIONINFOA;
    import core.sys.windows.winbase : GetModuleHandleA, GetProcAddress, INVALID_HANDLE_VALUE;
    import core.sys.windows.windef : HMODULE, KEY_QUERY_VALUE, HKEY;
    import core.sys.windows.winreg : RegOpenKeyExA, RegCloseKey, RegQueryValueExA, REG_DWORD, HKEY_LOCAL_MACHINE;
    import std.format : format;
    
    OSVERSIONINFOA info;

    HMODULE handle = GetModuleHandleA("ntdll");
    if (handle == INVALID_HANDLE_VALUE)
        throw new Exception("Could not load ntdll");
    
    extern (Windows)
    uint function(OSVERSIONINFOA*) RtlGetVersion =
        cast(uint function(OSVERSIONINFOA*)) GetProcAddress(handle, "RtlGetVersion");
    if (RtlGetVersion == null)
        throw new Exception("Could not get function RtlGetVersion");

    RtlGetVersion(&info);

    HKEY key = void;

    enum KEY = `SOFTWARE\Microsoft\Windows NT\CurrentVersion`;
    enum SUB = `UBR`;
    enum HKLM = HKEY_LOCAL_MACHINE;

    uint type = REG_DWORD;
    uint ubr = void;
    uint l = cast(uint) uint.sizeof;

    uint status = RegOpenKeyExA(HKLM, KEY, 0, KEY_QUERY_VALUE, &key);
    if (status) // Error
    {
        goto Lregfailed;
    }

    status = RegQueryValueExA(key, SUB, null, &type, &ubr, &l);
    if (status) // Error
    {
        RegCloseKey(key);
        goto Lregfailed;
    }

    RegCloseKey(key);

    return format("%u.%u.%u.%u",
        info.dwMajorVersion,
        info.dwMinorVersion,
        info.dwBuildNumber,
        ubr);

Lregfailed:
    return format("%u.%u.%u",
        info.dwMajorVersion,
        info.dwMinorVersion,
        info.dwBuildNumber);
}
else // assume linux for now
{
    throw new Exception("Todo");
}
}