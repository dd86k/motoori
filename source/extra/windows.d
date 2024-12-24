module extra.windows;

struct WindowsFacility
{
    /// Facility base code
    ushort id;
    /// Facility alias name
    const(char)[] name;
    /// Facility description
    const(char)[] description;
}

//
// HRESULT facility functions
//

immutable(WindowsFacility)[] getWindowsHResultFacilities()
{
    return hresult_facilities;
}

// Get HRESULT Facility ID by error code
ushort hresultFacilityIDByCode(uint code)
{
    return (code >> 16) & 2047; // 11 bits
}

// Get HRESULT facility by its ID
WindowsFacility hresultFacilityById(ushort id)
{
    foreach (ref immutable(WindowsFacility) facility; hresult_facilities)
    {
        if (id == facility.id)
            return facility;
    }
    static immutable WindowsFacility empty;
    return cast()empty;
}

// Get HRESULT facility by error code
WindowsFacility hresultFacilityByCode(uint code)
{
    return hresultFacilityById(hresultFacilityIDByCode(code));
}

//
// NTSTATUS facility functions
//

// Get NTSTATUS facility list
immutable(WindowsFacility)[] getWindowsNtstatusFacilities()
{
    return ntstatus_facilities;
}

// Get NTSTATUS facility if by error code
ushort ntstatusFacilityIDByCode(uint code)
{
    if (code & 0x2000_0000) // C bit (Customer)
        return 0;
    return (code >> 16) & 4095; // 12 bits
}

// Get NTSTATUS facility by its ID
WindowsFacility ntstatusFacilityById(ushort id)
{
    foreach (ref immutable(WindowsFacility) facility; ntstatus_facilities)
    {
        if (id == facility.id)
            return facility;
    }
    static immutable WindowsFacility empty;
    return cast()empty;
}

// Get NTSTATUS facility by an error code
WindowsFacility ntstatusFacilityByCode(uint code)
{
    return ntstatusFacilityById(ntstatusFacilityIDByCode(code));
}

private:

// HRESULT
//  3        2         1
// 10987654321098765432109876543210
// SRCNX|-Facility||----Error----|
// S: Severity. If set, indicates a failure result. If clear,
//    indicates a success result.
// R: Reserved. If the N bit is clear, this bit MUST be set to 0.
//    If the N bit is set, this bit is defined by the NTSTATUS
//    numbering space (as specified in section 2.3).
// C: Customer. This bit specifies if the value is
//    customer-defined or Microsoft-defined. The bit is set for
//    customer-defined values and clear for Microsoft-defined values.
// N: If set, indicates that the error code is an NTSTATUS value (as
//    specified in section 2.3), except that this bit is set.
// X: Reserved. SHOULD be set to 0.

// HRESULT facilities
enum : ushort
{
    FACILITY_NULL	= 0,
    FACILITY_RPC	= 1,
    FACILITY_DISPATCH	= 2,
    FACILITY_STORAGE	= 3,
    FACILITY_ITF	= 4,
    FACILITY_WIN32	= 7,
    FACILITY_WINDOWS	= 8,
    FACILITY_SECURITY	= 9,
    FACILITY_CONTROL	= 10,
    FACILITY_CERT	= 11,
    FACILITY_INTERNET	= 12,
    FACILITY_MEDIASERVER	= 13,
    FACILITY_MSMQ	= 14,
    FACILITY_SETUPAPI	= 15,
    FACILITY_SCARD	= 16,
    FACILITY_COMPLUS	= 17,
    FACILITY_AAF	= 18,
    FACILITY_URT	= 19,
    FACILITY_ACS	= 20,
    FACILITY_DPLAY	= 21,
    FACILITY_UMI	= 22,
    FACILITY_SXS	= 23,
    FACILITY_WINDOWS_CE	= 24,
    FACILITY_HTTP	= 25,
    FACILITY_USERMODE_COMMONLOG	= 26,
    FACILITY_USERMODE_FILTER_MANAGER	= 31,
    FACILITY_BACKGROUNDCOPY	= 32,
    FACILITY_CONFIGURATION	= 33,
    FACILITY_STATE_MANAGEMENT	= 34,
    FACILITY_METADIRECTORY	= 35,
    FACILITY_WINDOWSUPDATE	= 36,
    FACILITY_DIRECTORYSERVICE	= 37,
    FACILITY_GRAPHICS	= 38,
    FACILITY_SHELL	= 39,
    FACILITY_TPM_SERVICES	= 40,
    FACILITY_TPM_SOFTWARE	= 41,
    FACILITY_PLA	= 48,
    FACILITY_FVE	= 49,
    FACILITY_FWP	= 50,
    FACILITY_WINRM	= 51,
    FACILITY_NDIS	= 52,
    FACILITY_USERMODE_HYPERVISOR	= 53,
    FACILITY_CMI	= 54,
    FACILITY_USERMODE_VIRTUALIZATION	= 55,
    FACILITY_USERMODE_VOLMGR	= 56,
    FACILITY_BCD	= 57,
    FACILITY_USERMODE_VHD	= 58,
    FACILITY_SDIAG	= 60,
    FACILITY_WEBSERVICES	= 61,
    FACILITY_WINDOWS_DEFENDER	= 80,
    FACILITY_OPC	= 81,
}
immutable WindowsFacility[] hresult_facilities = [
    {
        FACILITY_NULL,
        FACILITY_NULL.stringof,
        "Default"
    },
    {
        FACILITY_RPC,
        FACILITY_RPC.stringof,
        "RPC subsystem"
    },
    {
        FACILITY_DISPATCH,
        FACILITY_DISPATCH.stringof,
        "COM Dispatch"
    },
    {
        FACILITY_STORAGE,
        FACILITY_STORAGE.stringof,
        "OLE Storage"
    },
    {
        FACILITY_ITF,
        FACILITY_ITF.stringof,
        "COM/OLE Interface management"
    },
    {
        FACILITY_WIN32,
        FACILITY_WIN32.stringof,
        "Win32"
    },
    {
        FACILITY_WINDOWS,
        FACILITY_WINDOWS.stringof,
        "Windows"
    },
    {
        FACILITY_SECURITY,
        FACILITY_SECURITY.stringof,
        "Security API"
    },
    {
        FACILITY_CONTROL,
        FACILITY_CONTROL.stringof,
        "Control mechanism"
    },
    {
        FACILITY_CERT,
        FACILITY_CERT.stringof,
        "Certificate"
    },
    {
        FACILITY_INTERNET,
        FACILITY_INTERNET.stringof,
        "Wininet"
    },
    {
        FACILITY_MEDIASERVER,
        FACILITY_MEDIASERVER.stringof,
        "Windows Media Server"
    },
    {
        FACILITY_MSMQ,
        FACILITY_MSMQ.stringof,
        "Microsoft Message Queue"
    },
    {
        FACILITY_SETUPAPI,
        FACILITY_SETUPAPI.stringof,
        "Setup API"
    },
    {
        FACILITY_SCARD,
        FACILITY_SCARD.stringof,
        "Smart-card subsystem"
    },
    {
        FACILITY_COMPLUS,
        FACILITY_COMPLUS.stringof,
        "COM+"
    },
    {
        FACILITY_AAF,
        FACILITY_AAF.stringof,
        "Microsoft agent"
    },
    {
        FACILITY_URT,
        FACILITY_URT.stringof,
        ".NET CLR"
    },
    {
        FACILITY_ACS,
        FACILITY_ACS.stringof,
        "Audit Collection Service"
    },
    {
        FACILITY_DPLAY,
        FACILITY_DPLAY.stringof,
        "Direct Play"
    },
    {
        FACILITY_UMI,
        FACILITY_UMI.stringof,
        "Ubiquitous Memory-introspection service"
    },
    {
        FACILITY_SXS,
        FACILITY_SXS.stringof,
        "Side-by-side (sxs) servicing"
    },
    {
        FACILITY_WINDOWS_CE,
        FACILITY_WINDOWS_CE.stringof,
        "Windows CE"
    },
    {
        FACILITY_HTTP,
        FACILITY_HTTP.stringof,
        "HTTP"
    },
    {
        FACILITY_USERMODE_COMMONLOG,
        FACILITY_USERMODE_COMMONLOG.stringof,
        "Common Logging"
    },
    {
        FACILITY_USERMODE_FILTER_MANAGER,
        FACILITY_USERMODE_FILTER_MANAGER.stringof,
        "User Mode Filter Manager"
    },
    {
        FACILITY_BACKGROUNDCOPY,
        FACILITY_BACKGROUNDCOPY.stringof,
        "Background Copy"
    },
    {
        FACILITY_CONFIGURATION,
        FACILITY_CONFIGURATION.stringof,
        "Configuration Services"
    },
    {
        FACILITY_STATE_MANAGEMENT,
        FACILITY_STATE_MANAGEMENT.stringof,
        "State Management Services"
    },
    {
        FACILITY_METADIRECTORY,
        FACILITY_METADIRECTORY.stringof,
        "Microsoft Identity Server"
    },
    {
        FACILITY_WINDOWSUPDATE,
        FACILITY_WINDOWSUPDATE.stringof,
        "Windows update"
    },
    {
        FACILITY_DIRECTORYSERVICE,
        FACILITY_DIRECTORYSERVICE.stringof,
        "Active Directory"
    },
    {
        FACILITY_GRAPHICS,
        FACILITY_GRAPHICS.stringof,
        "Graphics drivers"
    },
    {
        FACILITY_SHELL,
        FACILITY_SHELL.stringof,
        "User shell"
    },
    {
        FACILITY_TPM_SERVICES,
        FACILITY_TPM_SERVICES.stringof,
        "Trusted Platform Module services"
    },
    {
        FACILITY_TPM_SOFTWARE,
        FACILITY_TPM_SOFTWARE.stringof,
        "Trusted Platform Module applications"
    },
    {
        FACILITY_PLA,
        FACILITY_PLA.stringof,
        "Performance Logs and Alerts"
    },
    {
        FACILITY_FVE,
        FACILITY_FVE.stringof,
        "Full Volume Encryption"
    },
    {
        FACILITY_FWP,
        FACILITY_FWP.stringof,
        "Firewall Platform"
    },
    {
        FACILITY_WINRM,
        FACILITY_WINRM.stringof,
        "Windows Resource Manager"
    },
    {
        FACILITY_NDIS,
        FACILITY_NDIS.stringof,
        "Network Driver Interface"
    },
    {
        FACILITY_USERMODE_HYPERVISOR,
        FACILITY_USERMODE_HYPERVISOR.stringof,
        "Usermode Hypervisor components"
    },
    {
        FACILITY_CMI,
        FACILITY_CMI.stringof,
        "Configuration Management Infrastructure"
    },
    {
        FACILITY_USERMODE_VIRTUALIZATION,
        FACILITY_USERMODE_VIRTUALIZATION.stringof,
        "User Mode Virtualization Subsystem"
    },
    {
        FACILITY_USERMODE_VOLMGR,
        FACILITY_USERMODE_VOLMGR.stringof,
        "User Mode Volume Manager"
    },
    {
        FACILITY_BCD,
        FACILITY_BCD.stringof,
        "Boot Configuration Database"
    },
    {
        FACILITY_USERMODE_VHD,
        FACILITY_USERMODE_VHD.stringof,
        "User Mode Virtual Hard Disk"
    },
    {
        FACILITY_SDIAG,
        FACILITY_SDIAG.stringof,
        "System Diagnostics"
    },
    {
        FACILITY_WEBSERVICES,
        FACILITY_WEBSERVICES.stringof,
        "Web Services"
    },
    {
        FACILITY_WINDOWS_DEFENDER,
        FACILITY_WINDOWS_DEFENDER.stringof,
        "Windows Defender"
    },
    {
        FACILITY_OPC,
        FACILITY_OPC.stringof,
        "Open Connectivity service"
    }
];

// NTSTATUS facilities
enum : ushort
{
    FACILITY_DEBUGGER = 0x001,
    FACILITY_RPC_RUNTIME	= 0x002,
    FACILITY_RPC_STUBS	= 0x003,
    FACILITY_IO_ERROR_CODE	= 0x004,
    FACILITY_NTWIN32	= 0x007,
    FACILITY_NTSSPI	= 0x009,
    FACILITY_TERMINAL_SERVER	= 0x00A,
    FACILTIY_MUI_ERROR_CODE	= 0x00B,
    FACILITY_USB_ERROR_CODE	= 0x010,
    FACILITY_HID_ERROR_CODE	= 0x011,
    FACILITY_FIREWIRE_ERROR_CODE	= 0x012,
    FACILITY_CLUSTER_ERROR_CODE	= 0x013,
    FACILITY_ACPI_ERROR_CODE	= 0x014,
    FACILITY_SXS_ERROR_CODE	= 0x015,
    FACILITY_TRANSACTION	= 0x019,
    FACILITY_COMMONLOG	= 0x01A,
    FACILITY_VIDEO	= 0x01B,
    FACILITY_FILTER_MANAGER	= 0x01C,
    FACILITY_MONITOR	= 0x01D,
    FACILITY_GRAPHICS_KERNEL	= 0x01E,
    FACILITY_DRIVER_FRAMEWORK	= 0x020,
    FACILITY_FVE_ERROR_CODE	= 0x021,
    FACILITY_FWP_ERROR_CODE	= 0x022,
    FACILITY_NDIS_ERROR_CODE	= 0x023,
    FACILITY_HYPERVISOR	= 0x035,
    FACILITY_IPSEC	= 0x036,
    //FACILITY_MAXIMUM_VALUE	= 0x037,
}

immutable WindowsFacility[] ntstatus_facilities = [
    {
        FACILITY_DEBUGGER,
        FACILITY_DEBUGGER.stringof,
        "Windows Debugger"
    },
    {
        FACILITY_RPC_RUNTIME,
        FACILITY_RPC_RUNTIME.stringof,
        "Windows Remote Procedure Call Runtime"
    },
    {
        FACILITY_RPC_STUBS,
        FACILITY_RPC_STUBS.stringof,
        "Windows Remote Procedure Call Stub"
    },
    {
        FACILITY_IO_ERROR_CODE,
        FACILITY_IO_ERROR_CODE.stringof,
        "Input/Output"
    },
    {
        FACILITY_NTWIN32,
        FACILITY_NTWIN32.stringof,
        "WindowsNT Win32"
    },
    {
        FACILITY_NTSSPI,
        FACILITY_NTSSPI.stringof,
        "Security Support Provider Interface (SSPI)"
    },
    {
        FACILITY_TERMINAL_SERVER,
        FACILITY_TERMINAL_SERVER.stringof,
        "Windows Terminal Server"
    },
    {
        FACILTIY_MUI_ERROR_CODE,
        FACILTIY_MUI_ERROR_CODE.stringof,
        "Multilingual User Interface"
    },
    {
        FACILITY_USB_ERROR_CODE,
        FACILITY_USB_ERROR_CODE.stringof,
        "Universal Serial Bus"
    },
    {
        FACILITY_HID_ERROR_CODE,
        FACILITY_HID_ERROR_CODE.stringof,
        "Humand Interface Device"
    },
    {
        FACILITY_FIREWIRE_ERROR_CODE,
        FACILITY_FIREWIRE_ERROR_CODE.stringof,
        "IEEE 1394 FireWire"
    },
    {
        FACILITY_CLUSTER_ERROR_CODE,
        FACILITY_CLUSTER_ERROR_CODE.stringof,
        ""
    },
    {
        FACILITY_ACPI_ERROR_CODE,
        FACILITY_ACPI_ERROR_CODE.stringof,
        "Advanced Configuration and Power Interface"
    },
    {
        FACILITY_SXS_ERROR_CODE,
        FACILITY_SXS_ERROR_CODE.stringof,
        "Windows Side-by-Side"
    },
    {
        FACILITY_TRANSACTION,
        FACILITY_TRANSACTION.stringof,
        "Windows Kernel Transaction Manager (KTM)"
    },
    {
        FACILITY_COMMONLOG,
        FACILITY_COMMONLOG.stringof,
        "Windows Common Log File System (CLFS)"
    },
    {
        FACILITY_VIDEO,
        FACILITY_VIDEO.stringof,
        "Windows Media Foundation"
    },
    {
        FACILITY_FILTER_MANAGER,
        FACILITY_FILTER_MANAGER.stringof,
        "Windows Filter Manager (FltMgr.sys)"
    },
    {
        FACILITY_MONITOR,
        FACILITY_MONITOR.stringof,
        "Windows Monitor File"
    },
    {
        FACILITY_GRAPHICS_KERNEL,
        FACILITY_GRAPHICS_KERNEL.stringof,
        "Windows DirectX Graphics Kernel"
    },
    {
        FACILITY_DRIVER_FRAMEWORK,
        FACILITY_DRIVER_FRAMEWORK.stringof,
        "Windows Driver Framework (WDF)"
    },
    {
        FACILITY_FVE_ERROR_CODE,
        FACILITY_FVE_ERROR_CODE.stringof,
        "Windows Full Volume Encryption"
    },
    {
        FACILITY_FWP_ERROR_CODE,
        FACILITY_FWP_ERROR_CODE.stringof,
        "Windows Filtering Platform (WFP)"
    },
    {
        FACILITY_NDIS_ERROR_CODE,
        FACILITY_NDIS_ERROR_CODE.stringof,
        "Windows Network Driver Interface Specification"
    },
    {
        FACILITY_HYPERVISOR,
        FACILITY_HYPERVISOR.stringof,
        "Windows Hyper-V"
    },
    {
        FACILITY_IPSEC,
        FACILITY_IPSEC.stringof,
        "Windows IPSec"
    },
];