module extract.main;

import std.stdio, std.file, std.getopt;
import extract.source.crt : processCrtMessages;
import extract.source.windows;
import core.stdc.stdlib : exit;
import extract.platform;
import extract.utils;

private:

// Locate a single MUI
void locateMUIFile(string val, string root)
{
    string mui = locatemui(val, root);
    if (mui == null) // retry with suffix
        mui = locatemui(val~".dll", root);
    writefln("%20s: %s", val, mui ? mui : "Not found");
    exit(mui ? 2 : 0);
}

// Check and list available MUIs
void checkMUIFiles(string root)
{
    foreach (mod; modules)
    {
        string mui = locatemui(mod.name, root);
        if (mui == null) // retry with suffix
            mui = locatemui(mod.name~".dll", root);
        writefln("%20s: %s", mod.name, mui ? mui : "Not found");
    }
    exit(0);
}

void checkCode(string val, bool all, string root)
{
    import extract.utils : parseCode;
    import extract.resource.pe32 : ErrorMessage, loadmuimsgs;
    uint code = void;
    if (parseCode(val, code) == false)
        throw new Exception("Not an error code");

    string[] muis;
    if (all)
        muis = fetchallmui(root);
    else
        foreach (mod; modules)
        {
            string mui = locatemui(mod.name, root);
            if (mui)
                muis ~= mui;
        }

    foreach (mui; muis)
    {
        try
        {
            scope ErrorMessage[] msgs = loadmuimsgs(mui);
            foreach (msg; msgs)
            {
                if (msg.id == code)
                {
                    writeln(mui);
                    writeln('\t', msg);
                }
            }
        }
        catch (Exception) {}
    }
    exit(0);
}

void cliPlatformInfo()
{
    writeln("CRuntime: ", CRT_NAME);
    
    version (Windows)
    {
        const(char)[] winver = getOSVersion();
        writeln("Windows: ", winver);
    }
    
    exit(0);
}

void main(string[] args)
{
    string ooutdir = "data";
    string oerrcsv;
    int ogenflags;
    enum {
        GEN_CRT = 1,
        GEN_WIN_HDR = 16,
        GEN_WIN_MOD = 32,
        GEN_ARCHIVE = 256,
        GEN_ALL = GEN_CRT | GEN_WIN_HDR | GEN_WIN_MOD | GEN_ARCHIVE,
    }
    string olocatemui;
    bool olistmuis;
    string ocode;
    bool oall;
    string oroot;
    string oosbuild;
    bool oosserver;
    GetoptResult optres = void;
    try
    {
        optres = getopt(args, std.getopt.config.caseSensitive,
        // Generic
        "outdir",       "Change output directory (default='data')", &ooutdir,
        "print-info",   "Print information of current platform", &cliPlatformInfo,
        "generate-crt", "Generate CRT entries from current C runtime",
        () {
            ogenflags |= GEN_CRT;
        },
        "generate-windows-headers", "Generate Windows header entries from Err_6.4.5.exe CSV output",
        (string _, string v) {
            oerrcsv = v;
            ogenflags |= GEN_WIN_HDR;
        },
        "generate-windows-modules", "Generate Windows module entries from active platform",
        () {
            ogenflags |= GEN_WIN_MOD;
        },
        "generate-all", "Generate all info possible",
        () {
            ogenflags |= GEN_ALL;
        },
        //"create-archive", "Generate the compressed archive", &"",
        // CRT settings
        // Windows MUI settings
        "root",         "Read modules from an extracted image instead of the running system", &oroot,
        "os-build",     "Release the image is from, e.g. '10.0.26100.4652' (required with --root)", &oosbuild,
        "os-server",    "Treat --os-build as a Server release", &oosserver,
        "locate-mui",   "Locate MUI module given name", &olocatemui,
        "list-mui",     "Check availability of all MUI modules", &olistmuis,
        "code",         "Check if this code exists in MUIs", &ocode,
        "all-modules",  "Search every MUI under the root instead of the common ones", &oall,
        //"print-mui",  "Windows: Only print strings of MUI module", &strings,
        //"headerdesc", "Windows: Write header descriptions", &headerDesc,
        );
    }
    catch (Exception ex)
    {
        stderr.writeln("error: ", ex.msg);
        exit(1);
    }
    
    if (optres.helpWanted)
    {
    Lhelp:
        defaultGetoptPrinter(
            "extract: Error message extractor\n" ~
            "\n" ~
            "OPTIONS",
            optres.options);
        exit(0);
    }
    
    if (olocatemui)
    {
        locateMUIFile(olocatemui, oroot);
        exit(0);
    }

    if (olistmuis)
    {
        checkMUIFiles(oroot);
        exit(0);
    }

    if (ocode)
    {
        checkCode(ocode, oall, oroot);
        exit(0);
    }

    if (ogenflags == int.init)
        goto Lhelp;

    try
    {
        // An extracted image cannot be asked what release it is
        OSInfo os;
        if (oosbuild)
            os = parseOSBuild(oosbuild, oosserver);
        else if (oroot)
            throw new Exception("Option --root needs --os-build to name the release");

        if (ogenflags & GEN_CRT)
            processCrtMessages(ooutdir);

        if (ogenflags & GEN_WIN_HDR)
            processWindowsHeaders(ooutdir, oerrcsv);

        if (ogenflags & GEN_WIN_MOD)
            processWindowsModules(ooutdir, oall, oroot, os);
    }
    catch (Exception ex)
    {
        stderr.writeln("error: ", ex.msg);
        debug stderr.writeln("Exception:\n", ex.info);
        chdir("..");
        exit(2);
    }
}
