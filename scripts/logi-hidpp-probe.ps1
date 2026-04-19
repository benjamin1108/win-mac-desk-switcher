param(
    [switch]$List,
    [switch]$Ping,
    [switch]$Library,
    [switch]$HostsInfo,
    [switch]$ChangeHost,
    [string]$Path,
    [int[]]$Devices = @(1, 2, 3, 4, 5, 6),
    [int]$TargetHostIndex = 1,
    [int]$TimeoutMs = 1200
)

$ErrorActionPreference = 'Stop'

$source = @'
using Microsoft.Win32.SafeHandles;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public static class LogiHidppProbe
{
    const int DIGCF_PRESENT = 0x00000002;
    const int DIGCF_DEVICEINTERFACE = 0x00000010;
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 0x00000001;
    const uint FILE_SHARE_WRITE = 0x00000002;
    const uint OPEN_EXISTING = 3;
    const uint FILE_FLAG_OVERLAPPED = 0x40000000;
    const int ERROR_IO_PENDING = 997;
    const uint WAIT_OBJECT_0 = 0x00000000;

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA
    {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDD_ATTRIBUTES
    {
        public int Size;
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDP_CAPS
    {
        public ushort Usage;
        public ushort UsagePage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
        public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps;
        public ushort NumberInputValueCaps;
        public ushort NumberInputDataIndices;
        public ushort NumberOutputButtonCaps;
        public ushort NumberOutputValueCaps;
        public ushort NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps;
        public ushort NumberFeatureValueCaps;
        public ushort NumberFeatureDataIndices;
    }

    public class Device
    {
        public string Path;
        public ushort VendorID;
        public ushort ProductID;
        public ushort UsagePage;
        public ushort Usage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        public override string ToString()
        {
            return string.Format("VID={0:X4} PID={1:X4} UsagePage=0x{2:X4} Usage=0x{3:X4} In={4} Out={5} Feature={6} Path={7}",
                VendorID, ProductID, UsagePage, Usage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength, Path);
        }
    }

    public class RequestResult
    {
        public bool Success;
        public bool TimedOut;
        public string Error;
        public byte[] Reply;
        public byte[] Data;

        public override string ToString()
        {
            if (Success)
            {
                return "ok data=" + ToHex(Data, Data == null ? 0 : Data.Length) + " reply=" + ToHex(Reply, Reply == null ? 0 : Reply.Length);
            }
            if (TimedOut) return "timeout";
            return Error == null ? "failed" : Error;
        }
    }

    [DllImport("hid.dll")]
    static extern void HidD_GetHidGuid(out Guid HidGuid);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid ClassGuid, IntPtr Enumerator, IntPtr hwndParent, int Flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr DeviceInfoSet, IntPtr DeviceInfoData, ref Guid InterfaceClassGuid, int MemberIndex, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData);

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr DeviceInfoSet, ref SP_DEVICE_INTERFACE_DATA DeviceInterfaceData, IntPtr DeviceInterfaceDetailData, int DeviceInterfaceDetailDataSize, out int RequiredSize, IntPtr DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle hFile, byte[] lpBuffer, int nNumberOfBytesToRead, out int lpNumberOfBytesRead, ref NativeOverlapped lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle hFile, byte[] lpBuffer, int nNumberOfBytesToWrite, out int lpNumberOfBytesWritten, ref NativeOverlapped lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetOverlappedResult(SafeFileHandle hFile, ref NativeOverlapped lpOverlapped, out int lpNumberOfBytesTransferred, bool bWait);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CancelIo(SafeFileHandle hFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateEvent(IntPtr lpEventAttributes, bool bManualReset, bool bInitialState, string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr hHandle, int dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_GetAttributes(SafeFileHandle HidDeviceObject, ref HIDD_ATTRIBUTES Attributes);

    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_GetPreparsedData(SafeFileHandle HidDeviceObject, out IntPtr PreparsedData);

    [DllImport("hid.dll", SetLastError = true)]
    static extern bool HidD_FreePreparsedData(IntPtr PreparsedData);

    [DllImport("hid.dll", SetLastError = true)]
    static extern int HidP_GetCaps(IntPtr PreparsedData, ref HIDP_CAPS Capabilities);

    public static Device[] Enumerate()
    {
        Guid hidGuid;
        HidD_GetHidGuid(out hidGuid);
        IntPtr infoSet = SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (infoSet == IntPtr.Zero || infoSet.ToInt64() == -1) return new Device[0];

        var devices = new List<Device>();
        try
        {
            for (int index = 0; ; index++)
            {
                var data = new SP_DEVICE_INTERFACE_DATA();
                data.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                if (!SetupDiEnumDeviceInterfaces(infoSet, IntPtr.Zero, ref hidGuid, index, ref data)) break;

                int requiredSize;
                SetupDiGetDeviceInterfaceDetail(infoSet, ref data, IntPtr.Zero, 0, out requiredSize, IntPtr.Zero);
                IntPtr detail = Marshal.AllocHGlobal(requiredSize);
                try
                {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(infoSet, ref data, detail, requiredSize, out requiredSize, IntPtr.Zero)) continue;
                    string path = Marshal.PtrToStringAuto(IntPtr.Add(detail, 4));
                    Device device;
                    if (TryReadDevice(path, out device)) devices.Add(device);
                }
                finally
                {
                    Marshal.FreeHGlobal(detail);
                }
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(infoSet);
        }
        return devices.ToArray();
    }

    static bool TryReadDevice(string path, out Device device)
    {
        device = null;
        using (SafeFileHandle handle = CreateFile(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero))
        {
            if (handle == null || handle.IsInvalid) return false;
            var attrs = new HIDD_ATTRIBUTES();
            attrs.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
            if (!HidD_GetAttributes(handle, ref attrs)) return false;

            var caps = new HIDP_CAPS();
            IntPtr preparsed;
            if (HidD_GetPreparsedData(handle, out preparsed))
            {
                try { HidP_GetCaps(preparsed, ref caps); }
                finally { HidD_FreePreparsedData(preparsed); }
            }

            device = new Device {
                Path = path,
                VendorID = attrs.VendorID,
                ProductID = attrs.ProductID,
                UsagePage = caps.UsagePage,
                Usage = caps.Usage,
                InputReportByteLength = caps.InputReportByteLength,
                OutputReportByteLength = caps.OutputReportByteLength,
                FeatureReportByteLength = caps.FeatureReportByteLength
            };
            return true;
        }
    }

    public static string Ping(string path, int devnumber, int timeoutMs)
    {
        Device dev;
        if (!TryReadDevice(path, out dev)) return "open-info-failed";

        using (SafeFileHandle handle = CreateFile(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero))
        {
            if (handle == null || handle.IsInvalid) return "open-rw-failed";
            Drain(handle, dev.InputReportByteLength);

            byte swid = 0x02;
            byte mark = (byte)(Environment.TickCount & 0xFF);
            byte reportId = dev.OutputReportByteLength >= 20 ? (byte)0x11 : (byte)0x10;
            byte[] payload = new byte[] { reportId, (byte)devnumber, 0x00, (byte)(0x10 | swid), 0x00, 0x00, mark };
            int outLen = dev.OutputReportByteLength > payload.Length ? dev.OutputReportByteLength : payload.Length;
            byte[] output = new byte[outLen];
            Array.Copy(payload, output, payload.Length);
            if (!WriteWithTimeout(handle, output, 500)) return "write-timeout-or-failed";

            DateTime end = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (DateTime.UtcNow < end)
            {
                byte[] reply = ReadWithTimeout(handle, dev.InputReportByteLength > 0 ? dev.InputReportByteLength : 32, Math.Min(250, Math.Max(1, (int)(end - DateTime.UtcNow).TotalMilliseconds)));
                if (reply == null) continue;

                if (reply.Length >= 7 && (reply[0] == 0x10 || reply[0] == 0x11) && (reply[1] == (byte)devnumber || reply[1] == (byte)(devnumber ^ 0xFF)))
                {
                    if (reply[2] == 0x00 && reply[3] == (byte)(0x10 | swid) && reply[6] == mark)
                    {
                        return string.Format("online HID++ {0}.{1} reply={2}", reply[4], reply[5], ToHex(reply, 7));
                    }
                    if (reply[2] == 0x8F && reply[3] == 0x00 && reply[4] == (byte)(0x10 | swid))
                    {
                        if (reply[5] == 0x01) return "online HID++ 1.0 invalid-subid";
                        if (reply[5] == 0x07 || reply[5] == 0x08) return "offline-or-unreachable error=0x" + reply[5].ToString("X2");
                        if (reply[5] == 0x05) return "no-such-device error=0x05";
                        return "error=0x" + reply[5].ToString("X2") + " reply=" + ToHex(reply, 7);
                    }
                }
            }
            return "timeout";
        }
    }

    public static RequestResult FeatureRequest(string path, int devnumber, int featureIndex, int functionId, byte[] parameters, int timeoutMs)
    {
        Device dev;
        if (!TryReadDevice(path, out dev)) return Fail("open-info-failed");

        using (SafeFileHandle handle = CreateFile(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero))
        {
            if (handle == null || handle.IsInvalid) return Fail("open-rw-failed");
            Drain(handle, dev.InputReportByteLength);

            byte swid = 0x02;
            byte reportId = dev.OutputReportByteLength >= 20 ? (byte)0x11 : (byte)0x10;
            int outLen = dev.OutputReportByteLength > 0 ? dev.OutputReportByteLength : (reportId == 0x11 ? 20 : 7);
            byte[] output = new byte[outLen];
            output[0] = reportId;
            output[1] = (byte)devnumber;
            output[2] = (byte)(featureIndex & 0xFF);
            output[3] = (byte)((functionId & 0xF0) | swid);
            if (parameters != null)
            {
                int count = Math.Min(parameters.Length, output.Length - 4);
                Array.Copy(parameters, 0, output, 4, count);
            }

            if (!WriteWithTimeout(handle, output, 500)) return Fail("write-timeout-or-failed");

            DateTime end = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (DateTime.UtcNow < end)
            {
                byte[] reply = ReadWithTimeout(handle, dev.InputReportByteLength > 0 ? dev.InputReportByteLength : 32, Math.Min(250, Math.Max(1, (int)(end - DateTime.UtcNow).TotalMilliseconds)));
                if (reply == null) continue;

                if (reply.Length >= 4 && (reply[0] == 0x10 || reply[0] == 0x11) && (reply[1] == (byte)devnumber || reply[1] == (byte)(devnumber ^ 0xFF)))
                {
                    if (reply[2] == (byte)(featureIndex & 0xFF) && reply[3] == (byte)((functionId & 0xF0) | swid))
                    {
                        int dataLen = Math.Max(0, reply.Length - 4);
                        byte[] data = new byte[dataLen];
                        if (dataLen > 0) Array.Copy(reply, 4, data, 0, dataLen);
                        return new RequestResult { Success = true, Reply = reply, Data = data };
                    }
                    if (reply.Length >= 6 && reply[2] == 0x8F && reply[3] == (byte)(featureIndex & 0xFF) && reply[4] == (byte)((functionId & 0xF0) | swid))
                    {
                        return Fail("hidpp-error=0x" + reply[5].ToString("X2") + " reply=" + ToHex(reply, reply.Length));
                    }
                }
            }
            return new RequestResult { Success = false, TimedOut = true };
        }
    }

    public static int LookupFeatureIndex(string path, int devnumber, int featureId, int timeoutMs)
    {
        byte[] parameters = new byte[] { (byte)((featureId >> 8) & 0xFF), (byte)(featureId & 0xFF) };
        RequestResult result = FeatureRequest(path, devnumber, 0x00, 0x00, parameters, timeoutMs);
        if (!result.Success || result.Data == null || result.Data.Length < 1) return -1;
        return result.Data[0];
    }

    public static string HostsInfo(string path, int devnumber, int timeoutMs)
    {
        int featureIndex = LookupFeatureIndex(path, devnumber, 0x1815, timeoutMs);
        if (featureIndex < 0) return "不支持 HOSTS_INFO 或没有回复";

        RequestResult result = FeatureRequest(path, devnumber, featureIndex, 0x00, new byte[0], timeoutMs);
        if (!result.Success) return result.ToString();
        if (result.Data == null || result.Data.Length < 4) return "成功 数据=" + ToHex(result.Data, result.Data == null ? 0 : result.Data.Length);

        return string.Format("HOSTS_INFO featureIndex=0x{0:X2} flags=0x{1:X2} 主机数量={2} 当前hostIndex={3} 物理信道={4} 数据={5}",
            featureIndex, result.Data[0], result.Data[2], result.Data[3], result.Data[3] + 1, ToHex(result.Data, result.Data.Length));
    }

    public static string ChangeHost(string path, int devnumber, int targetHostIndex, int timeoutMs)
    {
        int featureIndex = LookupFeatureIndex(path, devnumber, 0x1814, timeoutMs);
        if (featureIndex < 0) return "不支持 CHANGE_HOST 或没有回复";

        RequestResult result = FeatureRequest(path, devnumber, featureIndex, 0x10, new byte[] { (byte)targetHostIndex }, timeoutMs);
        if (result.Success)
        {
            return string.Format("已发送 CHANGE_HOST featureIndex=0x{0:X2} 目标hostIndex={1} 物理信道={2}; 回复={3}",
                featureIndex, targetHostIndex, targetHostIndex + 1, ToHex(result.Reply, result.Reply == null ? 0 : result.Reply.Length));
        }
        if (result.TimedOut)
        {
            return string.Format("已发送 CHANGE_HOST featureIndex=0x{0:X2} 目标hostIndex={1} 物理信道={2}; 超时前未收到回复",
                featureIndex, targetHostIndex, targetHostIndex + 1);
        }
        return result.ToString();
    }

    static RequestResult Fail(string error)
    {
        return new RequestResult { Success = false, Error = error };
    }

    static void Drain(SafeFileHandle handle, ushort inputLength)
    {
        for (int i = 0; i < 8; i++)
        {
            byte[] data = ReadWithTimeout(handle, inputLength > 0 ? inputLength : 32, 1);
            if (data == null) return;
        }
    }

    static byte[] ReadWithTimeout(SafeFileHandle handle, int length, int timeoutMs)
    {
        byte[] buffer = new byte[length];
        int read;
        var overlapped = new NativeOverlapped();
        overlapped.EventHandle = CreateEvent(IntPtr.Zero, true, false, null);
        if (overlapped.EventHandle == IntPtr.Zero) return null;
        try {
            bool ok = ReadFile(handle, buffer, buffer.Length, out read, ref overlapped);
            if (!ok) {
                int error = Marshal.GetLastWin32Error();
                if (error != ERROR_IO_PENDING) return null;
                uint wait = WaitForSingleObject(overlapped.EventHandle, timeoutMs);
                if (wait != WAIT_OBJECT_0) {
                    CancelIo(handle);
                    return null;
                }
                if (!GetOverlappedResult(handle, ref overlapped, out read, false)) return null;
            }
        } finally {
            CloseHandle(overlapped.EventHandle);
        }
        if (read <= 0) return null;
        if (read == buffer.Length) return buffer;
        byte[] actual = new byte[read];
        Array.Copy(buffer, actual, read);
        return actual;
    }

    static bool WriteWithTimeout(SafeFileHandle handle, byte[] buffer, int timeoutMs)
    {
        int written;
        var overlapped = new NativeOverlapped();
        overlapped.EventHandle = CreateEvent(IntPtr.Zero, true, false, null);
        if (overlapped.EventHandle == IntPtr.Zero) return false;
        try {
            bool ok = WriteFile(handle, buffer, buffer.Length, out written, ref overlapped);
            if (!ok) {
                int error = Marshal.GetLastWin32Error();
                if (error != ERROR_IO_PENDING) return false;
                uint wait = WaitForSingleObject(overlapped.EventHandle, timeoutMs);
                if (wait != WAIT_OBJECT_0) {
                    CancelIo(handle);
                    return false;
                }
                if (!GetOverlappedResult(handle, ref overlapped, out written, false)) return false;
            }
            return written == buffer.Length;
        } finally {
            CloseHandle(overlapped.EventHandle);
        }
    }

    public static string ToHex(byte[] data, int max)
    {
        int count = Math.Min(data.Length, max);
        string[] parts = new string[count];
        for (int i = 0; i < count; i++) parts[i] = data[i].ToString("X2");
        return string.Join(" ", parts);
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp

if ($Library) {
    return
}

if ($List -or (-not $Ping -and -not $HostsInfo -and -not $ChangeHost)) {
    [LogiHidppProbe]::Enumerate() |
        Where-Object { $_.VendorID -eq 0x046D } |
        ForEach-Object { $_.ToString() }
}

if ($Ping -or $HostsInfo -or $ChangeHost) {
    if (-not $Path) {
        $candidates = [LogiHidppProbe]::Enumerate() | Where-Object {
            $_.VendorID -eq 0x046D -and $_.ProductID -eq 0xC548 -and
            ($_.UsagePage -ge 0xFF00 -or $_.OutputReportByteLength -ge 7)
        } | Sort-Object OutputReportByteLength -Descending
        if (-not $candidates) {
            throw '没有找到 Logitech C548 HID++ 候选路径。请用 -List 查看设备。'
        }
        $Path = $candidates[0].Path
        Write-Host "使用候选路径: $Path"
    }
}

if ($Ping) {
    foreach ($device in $Devices) {
        $result = [LogiHidppProbe]::Ping($Path, $device, $TimeoutMs)
        Write-Host ("设备 {0}: {1}" -f $device, $result)
    }
}

if ($HostsInfo) {
    foreach ($device in $Devices) {
        $result = [LogiHidppProbe]::HostsInfo($Path, $device, $TimeoutMs)
        Write-Host ("设备 {0}: {1}" -f $device, $result)
    }
}

if ($ChangeHost) {
    foreach ($device in $Devices) {
        $result = [LogiHidppProbe]::ChangeHost($Path, $device, $TargetHostIndex, $TimeoutMs)
        Write-Host ("设备 {0}: {1}" -f $device, $result)
    }
}
