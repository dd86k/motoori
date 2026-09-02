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

/// Identifies the OS release a dataset was scanned on
struct OSInfo
{
    string key;   /// Dataset key, used as the data filename suffix
    string name;  /// Display name
    string build; /// Full version string, including UBR when available
}

version (Windows)
{
    import core.sys.windows.winnt : OSVERSIONINFOEXW, VER_NT_WORKSTATION;

    // RtlGetVersion is the only version call that manifest-based shimming does
    // not lie about, but it rejects the struct outright unless the size field
    // matches one of the two wide variants exactly.
    private OSVERSIONINFOEXW getVersionInfo()
    {
        import core.sys.windows.winbase : GetModuleHandleA, GetProcAddress;
        import core.sys.windows.windef : HMODULE;

        OSVERSIONINFOEXW info;
        info.dwOSVersionInfoSize = OSVERSIONINFOEXW.sizeof;

        HMODULE handle = GetModuleHandleA("ntdll");
        if (handle == null)
            throw new Exception("Could not get ntdll handle");

        extern (Windows)
        uint function(OSVERSIONINFOEXW*) RtlGetVersion =
            cast(uint function(OSVERSIONINFOEXW*)) GetProcAddress(handle, "RtlGetVersion");
        if (RtlGetVersion == null)
            throw new Exception("Could not get function RtlGetVersion");

        if (RtlGetVersion(&info))
            throw new Exception("RtlGetVersion failed");

        return info;
    }

    // Update Build Revision, only exists since Windows 10
    private bool getUBR(out uint ubr)
    {
        import core.sys.windows.windef : KEY_QUERY_VALUE, HKEY;
        import core.sys.windows.winreg : RegOpenKeyExA, RegCloseKey, RegQueryValueExA,
            REG_DWORD, HKEY_LOCAL_MACHINE;

        enum KEY = `SOFTWARE\Microsoft\Windows NT\CurrentVersion`;
        enum SUB = `UBR`;

        HKEY key = void;
        if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, KEY, 0, KEY_QUERY_VALUE, &key))
            return false;

        uint type = REG_DWORD;
        uint l = cast(uint)uint.sizeof;
        uint status = RegQueryValueExA(key, SUB, null, &type, &ubr, &l);

        RegCloseKey(key);
        return status == 0;
    }

    // Windows reused the 6.x and 10.0 version pairs across releases, so only the
    // build number and product type tell them apart. Build 26100 is both
    // Windows 11 24H2 and Server 2025.
    private OSInfo releaseName(uint major, uint minor, uint build, bool server)
    {
        import std.format : format;

        OSInfo os;

        if (major == 10 && minor == 0)
        {
            if (server == false)
            {
                os.key  = build >= 22000 ? "11" : "10";
                os.name = build >= 22000 ? "Windows 11" : "Windows 10";
            }
            else if (build >= 26100) { os.key = "server2025"; os.name = "Windows Server 2025"; }
            else if (build >= 20348) { os.key = "server2022"; os.name = "Windows Server 2022"; }
            else if (build >= 17763) { os.key = "server2019"; os.name = "Windows Server 2019"; }
            else                     { os.key = "server2016"; os.name = "Windows Server 2016"; }
        }
        else if (major == 6)
        {
            switch (minor)
            {
            case 0:
                os.key  = server ? "server2008"   : "vista";
                os.name = server ? "Windows Server 2008" : "Windows Vista";
                break;
            case 1:
                os.key  = server ? "server2008r2" : "7";
                os.name = server ? "Windows Server 2008 R2" : "Windows 7";
                break;
            case 2:
                os.key  = server ? "server2012"   : "8";
                os.name = server ? "Windows Server 2012" : "Windows 8";
                break;
            case 3:
                os.key  = server ? "server2012r2" : "8.1";
                os.name = server ? "Windows Server 2012 R2" : "Windows 8.1";
                break;
            default:
            }
        }

        if (os.key == null)
        {
            os.key  = format("%u.%u", major, minor);
            os.name = format("Windows %u.%u", major, minor);
        }

        return os;
    }
}

OSInfo getOSInfo()
{
version (Windows)
{
    import std.format : format;

    OSVERSIONINFOEXW info = getVersionInfo();

    OSInfo os = releaseName(info.dwMajorVersion, info.dwMinorVersion, info.dwBuildNumber,
        info.wProductType != VER_NT_WORKSTATION);

    uint ubr = void;
    os.build = getUBR(ubr)
        ? format("%u.%u.%u.%u", info.dwMajorVersion, info.dwMinorVersion, info.dwBuildNumber, ubr)
        : format("%u.%u.%u", info.dwMajorVersion, info.dwMinorVersion, info.dwBuildNumber);

    return os;
}
else
{
    throw new Exception("Todo");
}
}

const(char)[] getOSVersion()
{
    return getOSInfo().build;
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