module extract.platform;

version (X86)
    enum PLATFORM = "i686";
else version (X86_64)
    enum PLATFORM = "amd64";

// for alias: lowercase
// for description: append "C runtime"
version (CRuntime_Bionic)
{
    enum CRT_NAME = "bionic";
    enum CRT_FULL = "Bionic";
}
else version (CRuntime_DigitalMars)
{
    enum CRT_NAME = "digitalmars";
    enum CRT_FULL = "DigitalMars";
}
else version (CRuntime_Glibc)
{
    enum CRT_NAME = "glibc";
    enum CRT_FULL = "GNU";
}
else version (CRuntime_Microsoft)
{
    enum CRT_NAME = "msvc";
    enum CRT_FULL = "Microsoft Visual";
}
else version (CRuntime_Musl)
{
    enum CRT_NAME = "musl";
    enum CRT_FULL = "Musl";
}
else version (CRuntime_Newlib)
{
    enum CRT_NAME = "newlib";
    enum CRT_FULL = "Newlib";
}
else version (CRuntime_UClibc)
{
    enum CRT_NAME = "uclibc";
    enum CRT_FULL = "µClibc";
}
else version (CRuntime_WASI)
{
    enum CRT_NAME = "wasi";
    enum CRT_FULL = "WebAssembly System Interface";
}