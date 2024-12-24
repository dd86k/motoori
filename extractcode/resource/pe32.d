module extract.resource.pe32;

version (Windows):

import std.stdio;
import std.file : read;
import std.encoding : transcode;
import core.sys.windows.winbase : ExpandEnvironmentStringsA;
import core.stdc.inttypes : uint8_t, uint16_t, uint32_t, uint64_t;

version = Trace;

//TODO: Consider including resource version (typically 4.0)
//      into db

struct ErrorMessage
{
    uint id;
    const(char)[] message;
}

ErrorMessage[] loadmuimsgs(string path)
{
    version(Trace)
        writeln(path);
    
    ubyte[] buffer = cast(ubyte[]) read(path);
    size_t buflen = buffer.length;
    ubyte* ptr = buffer.ptr;

    //
    // Parse MZ
    //

    if (buflen < mz_hdr.sizeof)
        throw new Exception("buflen < mz_hdr.sizeof");

    mz_hdr* mz = cast(mz_hdr*) ptr;
    if (mz.e_magic != MZ_SIGN)
        throw new Exception("Invalid MZ signature");
    uint pe32off = mz.e_lfanew;
    if (pe32off + PE_HEADER.sizeof > buflen)
        throw new Exception("pe32off + PE_HEADER.sizeof > buflen");

    //
    // Parse PE32
    //

    // or 0x3c
    PE_HEADER* pe32 = cast(PE_HEADER*)(ptr + pe32off);
    if (pe32.Signature32 != PE_SIGN)
        throw new Exception("Invalid PE32 signature");

    union hdr_t
    {
        alias u this;
        PE_OPTIONAL_HEADER* u;
        PE_OPTIONAL_HEADER64* u64;
        PE_OPTIONAL_HEADERROM* urom;
        ubyte* raw;
    }

    hdr_t pe32opt;

    pe32opt.u = cast(PE_OPTIONAL_HEADER*) ADDPTR(pe32, PE_HEADER.sizeof);

    PE_IMAGE_DATA_DIRECTORY* pe32dir = void;
    PE_SECTION_ENTRY* sections = void;

    switch (pe32opt.Magic)
    {
    case PE_FMT_ROM:
        pe32dir = cast(PE_IMAGE_DATA_DIRECTORY*)(pe32opt.raw + PE_OPTIONAL_HEADERROM.sizeof);
        sections = cast(PE_SECTION_ENTRY*)(
            pe32opt.raw + PE_OPTIONAL_HEADERROM.sizeof + PE_IMAGE_DATA_DIRECTORY.sizeof);
        break;
    case PE_FMT_32:
        pe32dir = cast(PE_IMAGE_DATA_DIRECTORY*)(pe32opt.raw + PE_OPTIONAL_HEADER.sizeof);
        sections = cast(PE_SECTION_ENTRY*)(
            pe32opt.raw + PE_OPTIONAL_HEADER.sizeof + PE_IMAGE_DATA_DIRECTORY.sizeof);
        break;
    case PE_FMT_64:
        pe32dir = cast(PE_IMAGE_DATA_DIRECTORY*)(pe32opt.raw + PE_OPTIONAL_HEADER64.sizeof);
        sections = cast(PE_SECTION_ENTRY*)(
            pe32opt.raw + PE_OPTIONAL_HEADER64.sizeof + PE_IMAGE_DATA_DIRECTORY.sizeof);
        break;
    default: // Invalid magic
        throw new Exception("Unsupported PE32 Magic");
    }

    // no resource table
    if (pe32dir.ResourceTable.size == 0)
        throw new Exception("No resource table");

    //TODO: Consider getting FILEVERSION
    //      FILEVERSION 10, 0, 19041, 1

    // locale ".rsrc"
    // we are matching RVA instead of name because a name can easily be
    // changed, but the resource directory RVA hardly can be changed
    uint respos;
    uint rva = pe32dir.ResourceTable.rva;
    for (ushort i; i < pe32.NumberOfSections; ++i)
    {
        PE_SECTION_ENTRY* section = &sections[i];

        if (rva == section.VirtualAddress)
        {
            respos = section.PointerToRawData;
            break;
        }
    }

    // section not found
    if (respos == 0)
        throw new Exception("'.rsrc' section not found");

    // start of .rsrc
    PE_IMAGE_RESOURCE_DIRECTORY* directory =
        cast(PE_IMAGE_RESOURCE_DIRECTORY*)(ptr + respos);

    MUIEnv mui = MUIEnv(rva, directory);

    muiParseDir(mui, directory, 1);

    return mui.messages;
}

private:

// missing in defs
//enum LOAD_LIBRARY_AS_IMAGE_RESOURCE = 0x00000020;

enum : ushort
{
    MZ_SIGN = 0x5a4d,
    ERESWDS = 0x10,
}
enum : uint
{
    PE_SIGN = 0x4550,
    RESOURCE_TYPE_STRING = 6,
    RESOURCE_TYPE_MESSAGETABLE = 0xb,
    RESOURCE_TYPE_VERSION = 0x10,
}

enum : ushort
{ // PE image format/magic
    PE_FMT_ROM = 0x0107, // No longer used? Docs no longer have it
    PE_FMT_32 = 0x010B, /// PE32
    PE_FMT_64 = 0x020B, /// PE32+
}

/// MZ header structure
struct mz_hdr
{
    ushort e_magic; /// Magic number
    ushort e_cblp; /// Bytes on last page of file
    ushort e_cp; /// Pages in file
    ushort e_crlc; /// Number of relocation entries in the table
    ushort e_cparh; /// Size of header in paragraphs
    ushort e_minalloc; /// Minimum extra paragraphs needed
    ushort e_maxalloc; /// Maximum extra paragraphs needed
    ushort e_ss; /// Initial (relative) SS value
    ushort e_sp; /// Initial SP value
    ushort e_csum; /// Checksum
    ushort e_ip; /// Initial IP value
    ushort e_cs; /// Initial (relative) CS value
    ushort e_lfarlc; /// File address of relocation table
    ushort e_ovno; /// Overlay number
    ushort[ERESWDS] e_res; /// Reserved words
    uint e_lfanew; /// File address of new exe header (usually at 3Ch)
}

/// MZ relocation entry
struct mz_reloc
{
    ushort offset;
    ushort segment;
}

/// COFF file header (object and image)
struct PE_HEADER
{
align(1):
    union
    {
        uint8_t[4] Signature;
        uint32_t Signature32;
    }

    uint16_t Machine;
    uint16_t NumberOfSections;
    uint32_t TimeDateStamp; // C time_t
    uint32_t PointerToSymbolTable;
    uint32_t NumberOfSymbols;
    uint16_t SizeOfOptionalHeader;
    uint16_t Characteristics;
}
// https://msdn.microsoft.com/en-us/library/windows/desktop/ms680339(v=vs.85).aspx
// Image only
struct PE_OPTIONAL_HEADER
{
align(1):
    uint16_t Magic; // "Format"
    uint8_t MajorLinkerVersion;
    uint8_t MinorLinkerVersion;
    uint32_t SizeOfCode;
    uint32_t SizeOfInitializedData;
    uint32_t SizeOfUninitializedData;
    uint32_t AddressOfEntryPoint;
    uint32_t BaseOfCode;
    uint32_t BaseOfData;
    uint32_t ImageBase;
    uint32_t SectionAlignment;
    uint32_t FileAlignment;
    uint16_t MajorOperatingSystemVersion;
    uint16_t MinorOperatingSystemVersion;
    uint16_t MajorImageVersion;
    uint16_t MinorImageVersion;
    uint16_t MajorSubsystemVersion;
    uint16_t MinorSubsystemVersion;
    uint32_t Win32VersionValue;
    uint32_t SizeOfImage;
    uint32_t SizeOfHeaders;
    uint32_t CheckSum;
    uint16_t Subsystem;
    uint16_t DllCharacteristics;
    uint32_t SizeOfStackReserve;
    uint32_t SizeOfStackCommit;
    uint32_t SizeOfHeapReserve;
    uint32_t SizeOfHeapCommit;
    uint32_t LoaderFlags; /// Obsolete
    uint32_t NumberOfRvaAndSizes;
}

struct PE_OPTIONAL_HEADER64
{
align(1):
    uint16_t Magic; // "Format"
    uint8_t MajorLinkerVersion;
    uint8_t MinorLinkerVersion;
    uint32_t SizeOfCode;
    uint32_t SizeOfInitializedData;
    uint32_t SizeOfUninitializedData;
    uint32_t AddressOfEntryPoint;
    uint32_t BaseOfCode;
    uint64_t ImageBase;
    uint32_t SectionAlignment;
    uint32_t FileAlignment;
    uint16_t MajorOperatingSystemVersion;
    uint16_t MinorOperatingSystemVersion;
    uint16_t MajorImageVersion;
    uint16_t MinorImageVersion;
    uint16_t MajorSubsystemVersion;
    uint16_t MinorSubsystemVersion;
    uint32_t Win32VersionValue;
    uint32_t SizeOfImage;
    uint32_t SizeOfHeaders;
    uint32_t CheckSum;
    uint16_t Subsystem;
    uint16_t DllCharacteristics;
    uint64_t SizeOfStackReserve;
    uint64_t SizeOfStackCommit;
    uint64_t SizeOfHeapReserve;
    uint64_t SizeOfHeapCommit;
    uint32_t LoaderFlags; // Obsolete
    uint32_t NumberOfRvaAndSizes;
}

struct PE_OPTIONAL_HEADERROM
{
    uint16_t Magic;
    uint8_t MajorLinkerVersion;
    uint8_t MinorLinkerVersion;
    uint32_t SizeOfCode;
    uint32_t SizeOfInitializedData;
    uint32_t SizeOfUninitializedData;
    uint32_t AddressOfEntryPoint;
    uint32_t BaseOfCode;
    uint32_t BaseOfData;
    uint32_t BaseOfBss;
    uint32_t GprMask;
    uint32_t[4] CprMask;
    uint32_t GpValue;
}

struct PE_DIRECTORY_ENTRY
{
align(1):
    uint32_t rva; /// Relative Virtual Address
    uint32_t size; /// Size in bytes
}
// IMAGE_NUMBEROF_DIRECTORY_ENTRIES = 16
// MS recommends checking NumberOfRvaAndSizes but it always been 16
struct PE_IMAGE_DATA_DIRECTORY
{
align(1):
    PE_DIRECTORY_ENTRY ExportTable;
    PE_DIRECTORY_ENTRY ImportTable;
    PE_DIRECTORY_ENTRY ResourceTable;
    PE_DIRECTORY_ENTRY ExceptionTable;
    PE_DIRECTORY_ENTRY CertificateTable; // File Pointer (instead of RVA)
    PE_DIRECTORY_ENTRY BaseRelocationTable;
    PE_DIRECTORY_ENTRY DebugDirectory;
    PE_DIRECTORY_ENTRY ArchitectureData;
    PE_DIRECTORY_ENTRY GlobalPtr;
    PE_DIRECTORY_ENTRY TLSTable;
    PE_DIRECTORY_ENTRY LoadConfigurationTable;
    PE_DIRECTORY_ENTRY BoundImportTable;
    PE_DIRECTORY_ENTRY ImportAddressTable;
    PE_DIRECTORY_ENTRY DelayImport;
    PE_DIRECTORY_ENTRY CLRHeader; // Used to be COM+ Runtime Header
    PE_DIRECTORY_ENTRY Reserved;
}

struct PE_SECTION_ENTRY
{
align(1):
    char[8] Name;
    uint32_t VirtualSize;
    uint32_t VirtualAddress;
    uint32_t SizeOfRawData;
    uint32_t PointerToRawData;
    uint32_t PointerToRelocations;
    uint32_t PointerToLinenumbers;
    uint16_t NumberOfRelocations;
    uint16_t NumberOfLinenumbers;
    uint32_t Characteristics;
}

struct PE_IMAGE_RESOURCE_DIRECTORY
{
    uint32_t Characteristics;
    uint32_t DateStamp;
    uint16_t major;
    uint16_t minor;
    uint16_t NumberOfNamedEntries;
    uint16_t NumberOfIdEntries;
}

struct PE_IMAGE_RESOURCE_DIRECTORY_ENTRY
{
    union
    {
        uint32_t NameRVA;
        uint32_t ID;
    }

    union
    {
        uint32_t DataEntryRVA;
        uint32_t SubdirectoryRVA;
    }
}

struct PE_IMAGE_RESOURCE_DATA_ENTRY
{
    uint32_t DataRVA;
    uint32_t Size;
    uint32_t CodePage;
    uint32_t Reserved;
}

// MESSAGETABLE_ENTRY
struct PE_IMAGE_RESOURCE_BLOCK_ENTRY
{ // unofficial
    uint32_t RangeLow;
    uint32_t RangeHigh;
    uint32_t RVA;
}

struct PE_IMAGE_RESOURCE_MUI
{ // unofficial
    uint32_t Signature;
    uint32_t RVA; // ?
    uint16_t Reserved;
    uint16_t ID;
    uint32_t Reserved2;
}

struct PE_IMAGE_RESOURCE_STRING
{
    uint16_t size;
    uint16_t type; // 1=ascii, 2=ucs-2/utf-16
    // String data...
    // Can't do a pointer, D will think it's an actual pointer
    // in terms of storage space (size_t.sizeof)
}

struct MUIEnv
{
    uint rva;
    PE_IMAGE_RESOURCE_DIRECTORY* root;
    ErrorMessage[] messages;
}

T* ADDPTR(T)(T* baseptr, size_t size)
{
    return cast(T*)(cast(ubyte*) baseptr + size);
}

// MUI entries are typically named entries
// The rest, such as STRING, MESSAGETABLE, and VERSION entries are ID'd
// Level 1: Type
// Level 2: Name (can be anything)
// Level 3: Language (e.g. 0x0409 for en-US)

void muiParseDir(ref MUIEnv mui, PE_IMAGE_RESOURCE_DIRECTORY* directory, int level)
{
    PE_IMAGE_RESOURCE_DIRECTORY_ENTRY* entry =
        cast(PE_IMAGE_RESOURCE_DIRECTORY_ENTRY*)(
            cast(ubyte*) directory + PE_IMAGE_RESOURCE_DIRECTORY.sizeof);

    for (uint16_t i; i < directory.NumberOfIdEntries; ++i, ++entry)
    {
        version(Trace)
            writefln("\tL%u PE_IMAGE_RESOURCE_DIRECTORY_ENTRY(ID=%08x,DataEntryRVA=%08x)",
                level, entry.ID, entry.DataEntryRVA);

        if (level == 1)
            if (entry.ID != RESOURCE_TYPE_MESSAGETABLE)
                continue;

        if (entry.DataEntryRVA >= 0x8000_0000)
        {
            uint rva = entry.SubdirectoryRVA & 0x7fff_ffff;

            PE_IMAGE_RESOURCE_DIRECTORY* subdir =
                cast(PE_IMAGE_RESOURCE_DIRECTORY*)
                ADDPTR(mui.root, rva);

            muiParseDir(mui, subdir, level + 1);
            continue;
        }

        PE_IMAGE_RESOURCE_DATA_ENTRY* data =
            cast(PE_IMAGE_RESOURCE_DATA_ENTRY*)
            ADDPTR(mui.root, entry.DataEntryRVA);

        muiParseData(mui, data);
    }
}

// Only MESSAGETABLE for now
void muiParseData(ref MUIEnv mui, PE_IMAGE_RESOURCE_DATA_ENTRY* data)
{
    version(Trace)
        writefln(
            "\tPE_IMAGE_RESOURCE_DATA_ENTRY(DataRVA=%08x,Size=%08x,CodePage=%08x,Reserved=%08x)",
            data.DataRVA, data.Size, data.CodePage, data.Reserved);

    void* base = (cast(ubyte*) mui.root + (data.DataRVA - mui.rva));
    uint count = *cast(uint*) base;
    PE_IMAGE_RESOURCE_BLOCK_ENTRY* block =
        cast(PE_IMAGE_RESOURCE_BLOCK_ENTRY*)(base + uint.sizeof);

    for (uint i; i < count; ++i)
    {
        //writefln("BLOCK 0x%08x - 0x%08x -> 0x%08x",
        //         block.RangeLow, block.RangeHigh, block.RVA);

        PE_IMAGE_RESOURCE_STRING* str =
            cast(PE_IMAGE_RESOURCE_STRING*)(cast(ubyte*) base + (block.RVA));

        for (uint code = block.RangeLow; code <= block.RangeHigh; ++code)
        {
            final switch (str.type)
            {
            case 0: // ASCII
                uint asize = str.size - 4;
                char* aptr = (cast(char*)&str.type) + 2;

                while (aptr[asize - 1] == 0)
                {
                    --asize;
                }

                char[] astr = aptr[0 .. asize];

                //writef("%-4u (%u) %s", str.size, str.type, astr);
                //writeln(cast(ubyte[])astr);

                mui.messages ~= ErrorMessage(code, astr.idup);
                break;
            case 1: // UCS-2/UTF-16
                uint wsize = (str.size / 2) - 2;
                wchar* wptr = (cast(wchar*)&str.type) + 1;

                while (wptr[wsize - 1] == 0)
                {
                    --wsize;
                }

                wchar[] wstr = wptr[0 .. wsize];

                //writef("%-4u (%u) %s", str.size, str.type, wstr);

                char[] b;
                transcode(wstr, b);

                mui.messages ~= ErrorMessage(code, b);
                break;
            }

            str = cast(PE_IMAGE_RESOURCE_STRING*)((cast(ubyte*) str) + str.size);
        }

        ++block;
    }
}
