module extract.source.windows;

version (Windows):

import std.stdio, std.encoding, std.string, std.file,
       std.datetime.systime, std.datetime.stopwatch;
import std.process : execute, environment;
import std.json;
import core.sys.windows.windows;
import extract.resource.pe32;
import extract.utils;

//TODO: Consider adding a starting block parameter preference (uint[])
//      Because a lot of MUIs don't necessarily have error messages in them.
//      Or array of ranges.
struct Module
{
    string name;
    string description;
}

// List from henry++'s errlookup
immutable Module[] modules = [
    {"activeds.dll", "Active Directory Router Layer DLL"},
    {"adtschema.dll", "Security Audit"},
    {"appmgr.dll", "Software Installation Snapin Extension"},
    {"asferror.dll", "Advanced Streaming Format Error Definitions"},
    {"auditcse.dll", "Windows Audit Settings CSE"},
    {"bdeunlock.exe", "BitLocker Unlock"},
    {"bisrv.dll", "Background Tasks Infrastructure Service (BITS)"},
    {"blbevents.dll", "Blb Publisher"},
    {"blbres.dll", "Backup Engine Service"},
    {"ci.dll", "Code Integrity"},
    {"clipc.dll", "Client Licensing Platform (CLiP) Client"},
    {"clipsvc.dll", "Client License Service"},
    {"combase.dll", "Component Object Model (COM)"},
    {"comres.dll", "Component Object Model+ (COM+) Library"},
    {"coreuicomponents.dll", "Core UI Components"},
    {"crypt32.dll", "Cryptography API"},
    {"cryptxml.dll", "XML DigSig API"},
    {"cscsvc.dll", "CSC Service API"},
    {"csrsrv.dll", "Client Server Runtime Process"},
    {"das.dll", "Device Association Service"},
    {"ddputils.dll", "Data Deduplication Library"},
    {"defragsvc.dll", "Microsoft Drive Optimizer"},
    {"deviceaccess.dll", "Device Broker And Policy COM Server"},
    {"dhcpcore.dll", "DHCP v4"},
    {"dhcpcore6.dll", "DHCP v6"},
    {"dhcpsapi.dll", "DHCP Server API"},
    {"dism.exe", "DISM Imagine Servicing Utility"},
    {"dismapi.dll", "DISM API Framework"},
    {"dmutil.dll", "Disk Manager Library API"},
    {"dnsapi.dll", "DNS Client API"},
    {"dsreg.dll", "Active Directory Device Registration"},
    {"dwm.exe", "Desktop Window Manager API"},
    {"eapphost.dll", "EAPHost Peer API"},
    {"eapsvc.dll", "EAPHost API"},
    {"efscore.dll", "EFS Core API"},
    {"ehstorapi.dll", "Enhanced Storage API"},
    {"ehstorauthn.exe", "Enhanced Storage Authentification API"},
    //	Only BLOCK range 0xB00003EC - 0xB00003EE seems interesting
    {"fcon.dll", "Feature Configuration API"},
    {"fdeploy.dll", "Folder Redirection API"},
    {"fveapi.dll", "BitLocker Encryption API"},
    {"fvewiz.dll", "BitLocker Encryption Wizard API"},
    {"gpsvc.dll", "Group Policy Client API"},
    {"idlisten.dll", "Identity Listener API"},
    {"imapi2.dll", "Image Mastering API v2"},
    {"imapi2fs.dll", "Imagine Mastering File System Imaging API v2"},
    {"iphlpapi.dll", "IP Helper API"},
    {"iphlpsvc.dll", "IP Helper Service API"},
    {"ipnathlp.dll", "NAT Helper API"},
    {"iscsidsc.dll", "iSCSI Discovery API"},
    {"kerberos.dll", "Kerberos Security API"},
    {"kernel32.dll", "Windows (User-Mode)"},
    {"loadperf.dll", "Performance Counter API"},
    {"lsasrv.dll", "Performance Counter API"},
    {"mf.dll", "Media Foundation API"},
    {"mferror.dll", "Media Foundation Error API"},
    {"mprmsg.dll", "Multi-Protocol Router API"},
    {"mpssvc.dll", "Protection Service API"},
    {"msaudite.dll", "Security Audit Events API"},
    {"msimsg.dll", "Windows Installer API"},
    {"msmpeg2enc.dll", "Microsoft MPEG-2 Encoder API"},
    {"msobjs.dll", "System objects"},
    {"mstscax.dll", "Remote Desktop Client API"},
    {"mswsock.dll", "Windows Sockets Service API v2"},
    {"msxml3r.dll", "Microsoft XML API v3"},
    {"msxml6r.dll", "Microsoft XML API v6"},
    {"netdiagfx.dll", "Network Diagnostic Framework API"},
    {"netevent.dll", "Network Events API"},
    {"netmsg.dll", "Network Messages API"},
    {"ntdll.dll", "Windows (Kernel-Mode)"},
    {"ntoskrnl.exe", "Blue Screen Of Death (BSOD)"},
    {"ntprint.dll", "Spooler API"},
    {"ntshrui.dll", "Network Share"},
    {"ole32.dll", "Object Linking and Embedding (OLE)"},
    {"p2p.dll", "Peer-to-Peer Grouping API"},
    {"pdh.dll", "Performance Data Helper API"},
    {"perfos.dll", "System Performance Objects API"},
    {"profsvc.dll", "ProfSvc"},
    {"pshed.dll", "Platform Specific Hardware Error Messages"},
    {"qmgr.dll", "Background Tasks Infrastructure Service (BITS) API"},
    {"quartz.dll", "DirectShow Runtime"},
    {"radardt.dll", "Resource Exhaustion Detector"},
    {"rdpendp.dll", "RDP Audio Endpoint"},
    {"reagent.dll", "Windows Recovery Agent"},
    {"reseteng.dll", "Windows Reset Engine"},
    {"rpcrt4.dll", "Remote Procedural Call (RPC)"},
    {"rtm.dll", "Routing Table Manager"},
    {"samsrv.dll", "SAM Server API"},
    {"schedsvc.dll", "Task Scheduler Service API"},
    {"scripto.dll", "Microsoft ScriptO"},
    {"slc.dll", "Software Licensing Client API"},
    {"slcext.dll", "Software Licensing Client Extension API"},
    {"spp.dll", "Shared Protection Point Library API"},
    {"srcore.dll", "System Restore Core Library API"},
    {"srm.dll", "File Server Resource Manager Common Library API"},
    {"storagewmi.dll", "WMI Provider for Storage Management"},
    {"syncreg.dll", "Synchronization Framework Registration"},
    {"twinui.dll", "Twin UI"},
    {"vdsutil.dll", "Virtual Disk Service Utility"},
    {"w32time.dll", "Windows Time Service"},
    {"wcmsvc.dll", "Windows Connection Manager Service"},
    {"webservices.dll", "Windows Web Services"},
    {"websocket.dll", "Web Socket API"},
    {"winbio.dll", "Biometric API"},
    {"winhttp.dll", "WinHTTP Service"},
    {"wininet.dll", "WinInet Service"},
    {"wmerror.dll", "Windows Media Error"},
    {"wsock32.dll", "Socket Library"},
    {"wuaueng.dll", "Windows Update"},
];

/// Description of headers
immutable Module[] headers = [
    {"adoint.h", "ADO Guids."},
    {"AdsErr.h", "Error codes for Active Directory"},
    {"asferr.h", "Definition of ASF HRESULT codes"},
    {"BitsMsg.h", "Error code definitions for the background file copier"},
    {"bthdef.h", "This module contains the Bluetooth common structures and definitions"},
    {"bugcodes.h", "This module contains the definition of the system bug check codes."},
    {"cderr.h", "Common dialog error return codes"},
    {"cfgmgr32.h", "This module contains the user APIs for the Configuration Manager," ~
            " along with any public data structures needed to call these APIs."},
    {"d3d.h", "Direct3D include file"},
    {"d3d9.h", "Direct3D include file"},
    {"d3d9helper.h", "Direct3D helper include file"},
    {"daogetrw.h", "GetRows interface"},
    {"dciddi.h", "Definitions for MS/Intel-defined DCI interface"},
    {"ddeml.h", "DDEML API header file "},
    {"ddraw.h", "DirectDraw include file"},
    {"DhcpSSdk.h", "Header for writing a DHCP Callout DLL."},
    {"dinput.h", "DirectInput include file"},
    {"dinputd.h", "DirectInput include file for device driver implementors"},
    {"dlnaerror.h", "Definitions for DLNA errors."},
    {"dmerror.h", "Error codes returned by DirectMusic API's"},
    {"drt.h", "Win32 APIs and structures for the Microsoft Distributed Routing Table. "},
    {"dsound.h", "DirectSound include file"},
    {"EapHostError.h", "Scenario-specific error codes, reported by EapHost and EAP (Extensible Authentification Protocol) Method DLLs."},
    {"ehstormsg.h", "This file contains the message definitions for Enhanced Storage APIs."},
    {"esent.h", "This module defines the types and constants that are exposed through the ESE API."},
    {"FhErrors.h", "This module contains the definitions of the error codes returned by File History APIs and components."},
    {"fltdefs.h", "Definitions for the WIN32 filter APIs"},
    {"hidpi.h", "Public Interface to the HID parsing library."},
    {"IIScnfg.h", "Contains public Metadata IDs used by IIS."},
    {"imapi2error", "Error Messages used throughout IMAPIv2"},
    {"Ime.h", "Procedure declarations, constant definitions and macros for the IME component."},
    {"IntShCut.h", "Internet Shortcut interface definitions."},
    {"IPExport.h", "This file contains public definitions exported to transport layer and application software."},
    {"iscsierr.h", "Constant definitions for the IScsi discover error codes"},
    {"lmerr.h", "Network error definitions"},
    {"LMErrlog.h", "This module defines the API function prototypes and data structures" ~
            " for the following groups of NT API functions: NetErrorLog"},
    {"LMSvc.h", "This file contains structures, function prototypes, and definitions for the NetService API."},
    {"LpmApi.h", "Include file for Local Policy Module. This module defines the LPM structures and types."},
    {"lzexpand.h", "Public interface to LZEXP?.LIB."},
    {"MciAvi.h", "Multimedia Systems Media Control Interface AVI driver external header file"},
    {"MDMRegistration.h", "This file contains structures, function signatures for 3rd Party" ~
            "management software that intends to interact with Windows MDE (Mobile Device Enrollment)"},
    {"Mdmsg.h", "This file is generated by the MC tool from the MDMSG.MC message file."},
    {"mediaerr.h", "Shell error codes"},
    {"Mferror.h", "Definitions for MediaFoundation events."},
    {"Mpeg2Error.h", "Interface specific HRESULT error codes for MPEG-2 tables."},
    {"MprError.h", "Router specific error codes"},
    {"Mq.h", "Master include file for Message Queuing applications"},
    {"msime.h", "Japanese specific definitions of IFECommon, IFELanguage, IFEDictionary, and Per IME Interfaces."},
    {"MsiQuery.h", "Interface to running installer for custom actions and tools"},
    {"nb30.h", "This module contains the definitions for portable NetBIOS 3.0 support."},
    {"netevent.h", "Definitions for network events."},
    {"NetSh.h", "This file contains definitions which are needed by all NetSh helper DLLs."},
    {"nserror.h", "Definitions for Windows Media events."},
    {"ntdddisk.h", "This is the include file that defines all constants and types for accessing the Disk device."},
    {"NtDsAPI.h", "This file contains structures, function prototypes," ~
            "and definitions for public NTDS APIs other than directory interfaces like LDAP."},
    {"NtDsBMsg.h", "Windows NT Directory Service Backup/Restore API error codes"},
    {"ntiologc.h", "Constant definitions for the I/O error code log values."},
    {"ntstatus.h", "Constant definitions for the NTSTATUS values."},
    {"odbcinst.h", "Prototypes for ODBCCP32.DLL"},
    {"ole.h", "Object Linking and Embedding functions, types, and definitions"},
    {"OleCtl.h", "OLE Control interfaces"},
    {"OleDlg.h", "Include file for the OLE common dialogs. The following dialog implementations are provided: " ~
            "Insert Object Dialog, " ~
            "Convert Object Dialog, " ~
            "Paste Special Dialog, " ~
            "Change Icon Dialog, " ~
            "Edit Links Dialog, " ~
            "Update Links Dialog, " ~
            "Change Source Dialog, " ~
            "Busy Dialog, " ~
            "User Error Message Dialog, " ~
            "and Object Properties Dialog"
    },
    {"p2p.h", "Win32 APIs and structures for the Microsoft Peer To Peer infrastructure."},
    {"PatchApi.h", "Interface for creating and applying patches to files."},
    {"pbdaerrors.h", "Interface specific HRESULT error codes for PBDA."},
    {"qossp.h", "QoS definitions for NDIS components. This module defines the type of objects that can go into the " ~
            "ProviderSpecific buffer in the QOS structure."},
    {"RasError.h", "Remote Acess Service specific error codes"},
    {"Reconcil.h", "OLE reconciliation interface definitions."},
    {"Routprot.h", "Include file for Routing Protocol inteface to Router Managers"},
    {"rtcerr.h", "Error Messages for RTC Core API"},
    {"sberrors.h", "Session Broker TSV Internal Error Codes"},
    {"scesvc.h", "Wrapper APIs for services"},
    {"schannel.h", "Public Definitions for SCHANNEL Security Provider"},
    {"SetupAPI.h", "Public header file for Windows NT Setup and Device Installer services Dll."},
    {"shellapi.h", "SHELL.DLL functions, types, and definitions"},
    {"sherrors.h", "Shell API error code values"},
    {"slerror.h", "Error code definitions for the Software Licensing"},
    {"Snmp.h", "Definitions for SNMP development."},
    {"sperror.h", "This header file contains the custom error codes specific to SAPI5"},
    {"stierr.h", "This module contains the user mode still image APIs error and status codes"},
    {"synchronizationerrors.h", "Error Messages for Microsoft Synchronization Platform"},
    {"Tapi.h", "Telephony Application Programming Interface (TAPI)"},
    {"Tapi3Err.h", "Error Notifications for TAPI 3.0"},
    {"TCError.h", "Traffic Control external API specific error codes"},
    {"TextServ.h", "Define interfaces between the Text Services component and the host"},
    {"tpcerror.h", "Microsoft Tablet PC API Error Code definitions"},
    {"usb.h", "Structures and APIs for USB drivers."},
    {"usp10.h", "USP - Unicode Complex Script processor"},
    {"vdserr.h", "Constant definitions for the Virtual Disk Service error messages."},
    {"Vfw.h", "Video for windows include file for WIN32"},
    {"vsserror.h", "This file contains the message definitions for common VSS errors. " ~
            "They are a subset of message definitions of vssadmin.exe."},
    {"wcmerrors.h", "Definitions for Windows Config Management error code and error message"},
    {"WdsCpMsg.h", "Windows Deployment Services Content Provider (WDSCP) Facility Messages"},
    {"WdsTptMgmtMsg.h", "Windows Deployment Services Transport Server"},
    {"WerApi.h", "This file contains the function prototypes for Windows Error Reporting (WER)"},
    {"WiaDef.h", "Wndows Image Acquisition (WIA) constant definitions"},
    {"winbio_err.h", "Definitions of error codes used by Windows Biometric Framework components."},
    {"wincrypt.h", "Cryptographic API Prototypes and Definitions"},
    {"WindowsSearchErrors.h", "Windows Search and Indexer"},
    {"winerror.h", "Error code definitions for the Win32 API functions"},
    {"WinFax.h", "This module contains the WIN32 FAX APIs."},
    {"winhttp.h", "Contains manifests, macros, types and prototypes for Windows HTTP Services"},
    {"WinInet.h", "Contains manifests, macros, types and prototypes for Microsoft Windows Internet Extensions"},
    {"winioctl.h", "This module defines the 32-Bit Windows Device I/O control codes."},
    {"Winldap.h", "This module is the header file for the 32 bit LDAP client API for Windows NT and Windows 95."},
    {"WinSock2.h", "definitions to be used with the WinSock 2 DLL and WinSock 2 applications."},
    {"winspool.h", "Header file for Print APIs"},
    {"wpc.h", "This file defines the Windows Parental Controls interfaces and events"},
    {"wsbapperror.h", "This module contains the specific error codes returned by " ~
            "the COM interfaces implemented by the application to integrate with Windows Server Backup"},
    {"wsmerror.h", "Define WSMAN (Web Services for Management) specific error codes"},
    {"wuerror.h", "Error code definitions for Windows Update."},
    {"xapo.h", "Cross-platform Audio Processing Object interfaces"},
    {"xaudio2.h", "Declarations for the XAudio2 game audio API."},
];

string locatemui(string mod, string locale = "en-US")
{
    import std.algorithm.iteration : splitter;
    import std.file : exists;
    import std.path : pathSeparator, buildNormalizedPath;

    string PATH = environment["PATH"];

    foreach (path; PATH.splitter(pathSeparator))
    {
        if (exists(path) == false)
            continue;

        string full = buildNormalizedPath(path, locale, mod ~ ".mui"); // .dll.mui form

        if (exists(full))
            return full;

        string orig = buildNormalizedPath(path, mod); // .dll form

        if (exists(orig))
            return orig;
    }

    return null;
}

// Process output of Err_6.4.5.exe /:outputtoCSV into a JSON
private struct WinHeaderSym
{
    string id;
    string name;
    string desc;
}
private struct WinHeader
{
    string name;
    string desc;
    WinHeaderSym[] symbolics;
}
void processWindowsHeaders(string outdir, string err_csv_path)
{
    // Open file and read header out
    File fcsv;
    fcsv.open(err_csv_path, "r");
    cast(void)fcsv.readln();
    
    mkchdir(outdir);
    mkchdir("windows");
    
    // First pass is to merge header descriptions
    WinHeader[string] winheaders;
    foreach (ref immutable(Module) header; headers)
    {
        WinHeader winheader;
        winheader.name = header.name;
        winheader.desc = header.description;
        winheaders[ toLower(header.name) ] = winheader;
    }
    // Second pass is to add symbolic names to their header
    for (string line; (line = fcsv.readln().stripRight()) !is null;)
    {
        scope string[] items = line.split(',');
        
        // HexID,SymbolicName,Description,Source
        WinHeaderSym sym;
        sym.id   = items[0];
        sym.name = items[1];
        sym.desc = items[2];
        string source       = items[3]; // purely a key here
        
        if (sym.desc != `"N/A"`)
        {
            // Remove start and end quotes for description
            sym.desc = sym.desc[1..$-1];
            
            // And remove C-like commands
            if (startsWith(sym.desc, `/*`))
                sym.desc = sym.desc[2..$-2];
            else if (startsWith(sym.desc, `//`))
                sym.desc = sym.desc[2..$];
            sym.desc = cleanDescription(sym.desc);
        }
        else // Not available
        {
            sym.desc = null;
        }
        
        string key = toLower( source );
        if (WinHeader *winheader = source in winheaders)
        {
            (*winheader).symbolics ~= sym;
        }
        else // create entry with no description
        {
            WinHeader winheader;
            winheader.name = source;
            winheader.symbolics ~= sym;
            
            winheaders[ key ] = winheader;
        }
    }
    
    
    // Finally, save of that to JSON using a less error-prone method
    JSONValue jheaders = JSONValue(JSONValue[].init); // for older D compilers
    foreach (WinHeader header; winheaders)
    {
        // TODO: Consider skipping headers with no effective symbolics
        //       if (header.symbolics.length == 0) continue;
        
        JSONValue jsymbolics = JSONValue(JSONValue[].init); // for older D compilers
        foreach (WinHeaderSym sym; header.symbolics)
        {
            JSONValue jsym;
            jsym["id"] = sym.id;
            jsym["name"] = sym.name;
            jsym["description"] = sym.desc;
            jsymbolics.array ~= jsym;
        }
        
        JSONValue jheader;
        jheader["name"] = header.name;
        jheader["description"] = header.desc;
        jheader["symbolics"] = jsymbolics;
        jheaders.array ~= jheader;
    }
    
    JSONValue j;
    j["version"] = 2;
    j["headers"] = jheaders;
    
    writefile("headers.json", j.toString());
    
    chdir("..");
    chdir("..");
}

// Read list of known MUIs and extract messages from them
void processWindowsModules(string outdir)
{
    mkchdir(outdir);
    mkchdir("windows");
    
    JSONValue j;
    JSONValue jmodules = JSONValue(JSONValue[].init); // for older D compilers;
    foreach (ref immutable(Module) mod; modules)
    {
        string mui = locatemui(mod.name);
        if (mui is null)
        {
            stderr.writeln("warning: module '", mod.name, "' not found");
            continue;
        }
        
        JSONValue jmessages = JSONValue(JSONValue[].init);
        char[32] buf = void;
        try foreach (ErrorMessage msg; loadmuimsgs(mui))
        {
            JSONValue jmessage;
            jmessage["code"] = sformat(buf[],"%#x", msg.id);
            jmessage["message"] = cleanDescription( cast(string)msg.message );
            jmessages.array ~= jmessage;
        }
        catch (Exception ex)
        {
            stderr.writeln("warning: exception with '", mod.name, "': ", ex.msg);
            continue;
        }
            
        JSONValue jmodule;
        jmodule["name"] = mod.name;
        jmodule["description"] = mod.description;
        jmodule["messages"] = jmessages;
        jmodules.array ~= jmodule;
    }
    j["modules"] = jmodules;
    j["version"] = 1;
    
    writefile("modules.json", j.toString());
    
    chdir("..");
    chdir("..");
}

private:

string cleanDescription(string str)
{
    return str
        // Parse FormatMessage format
        .replace("%r%0", "")    // odd edge case i forgot about
        .replace("%n", "\n")
        .replace("%r", "")      // already have %n for newlines
        .replace("%t", " ")     // removing htabs keeps message cleaner
        .replace("%%", "%")
        .replace("%b", "")      // removing bells keeps message cleaner
        .replace("%.", ".")
        .replace("%!", "!")
        .replace("%0", "")      // removing null(?) keeps message cleaner
        // Parse HTML entities
        .replace("&#10;", " ")  // linefeed ('\n')
        .replace("&#44;", ",")  // comma (',')
        .replace("&quot;", `"`) // quote ('"')
        .replace("&apos;", "'") // apostrophe ('\'')
        .replace("&lt;", "<")   // less than
        .replace("&gt;", ">")   // greater than
        .replace("&amp;", "&")  // amperand
        // Finalize
        .strip()
    ;
}

// get error message from windows function
const(char)[] errorMessage(uint code)
{
    enum MSGBUF = 2 * 1024;
    wchar[MSGBUF] buffer = void;

    uint len = FormatMessageW(
        FORMAT_MESSAGE_FROM_SYSTEM, // dwFlags
        null, // lpSourve
        code, // dwMessageId
        0, // dwLanguageId
        buffer.ptr, // lpBuffer
        MSGBUF, // nSize
        null); // Arguments

    if (len == 0)
        return "FormatMessageW Error";
    
    const(char)[] msg;
    transcode(buffer[0 .. len], msg);
    return msg.strip;
}
