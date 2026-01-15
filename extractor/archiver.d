module extract.archiver;

import std.stdio;
import std.zip;
import std.json;
import std.file;
import std.datetime.systime;

import extract.utils;

alias writefile = std.file.write;
alias readfile = std.file.read;

enum DELIM = "\x1b";

immutable string dirRoot = "data";
immutable string dirWindows = "windows";
immutable string dirModules = "modules";

// Make and change directory
private
void mkchdir(string dir)
{
    if (exists(dir) == false) mkdir(dir);
    chdir(dir);
}

// Go up parent directory
private
void chdirparent()
{
    chdir("..");
}

// Prepare folder structure for data before archiving
void prepareFolders(string datapath)
{
    mkchdir(datapath);
    
    JSONValue jinfo;
    jinfo["version"] = 1;
    
    writefile("info", "v1");
    
    mkchdir(dirWindows);
    
    writefile("info", getOSVersion() ~ DELIM ~ Clock.currTime().toISOExtString());
    
    mkchdir(dirModules);
    
    
}

void archive(string outpath, string infolder)
{
    ZipArchive zip = new ZipArchive();
    zip.comment = "Motoori Database, version 1";
    
    foreach (DirEntry entry; dirEntries("data", SpanMode.depth))
    {
        if (entry.isDir)
            continue;
        writefln("compressing '%s'", entry.name);
        ArchiveMember m = new ArchiveMember();
        m.name = entry.name;
        m.compressionMethod = CompressionMethod.deflate;
        m.expandedData = cast(ubyte[])readfile(entry.name);
        zip.addMember(m);
    }
    
    writefile("database.zip", zip.build());
}