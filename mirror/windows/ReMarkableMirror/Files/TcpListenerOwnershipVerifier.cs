using System;
using System.ComponentModel;
using System.Net;
using System.Runtime.InteropServices;

namespace ReMarkableMirror.Files;

internal enum TcpListenerOwnership
{
    NotListening,
    ExpectedProcess,
    UnexpectedProcess,
}

internal static class TcpListenerOwnershipVerifier
{
    private const uint MibTcpStateListen = 2;
    private static readonly uint LoopbackAddress =
        BitConverter.ToUInt32(IPAddress.Loopback.GetAddressBytes());

    public static TcpListenerOwnership GetOwnership(int localPort, int expectedProcessId)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(localPort);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(localPort, ushort.MaxValue);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(expectedProcessId);

        const uint noError = 0;
        const uint errorInsufficientBuffer = 122;
        const int errorInvalidData = 13;
        const int addressFamilyInterNetwork = 2;

        var bufferSize = 0;
        var result = GetExtendedTcpTable(
            IntPtr.Zero,
            ref bufferSize,
            order: false,
            addressFamilyInterNetwork,
            TcpTableClass.OwnerPidListener,
            reserved: 0);
        if (result != noError && result != errorInsufficientBuffer)
        {
            throw new Win32Exception(unchecked((int)result));
        }

        if (bufferSize == 0)
        {
            return TcpListenerOwnership.NotListening;
        }

        for (var attempt = 0; attempt < 2; attempt++)
        {
            var buffer = Marshal.AllocHGlobal(bufferSize);
            try
            {
                var returnedSize = bufferSize;
                result = GetExtendedTcpTable(
                    buffer,
                    ref returnedSize,
                    order: false,
                    addressFamilyInterNetwork,
                    TcpTableClass.OwnerPidListener,
                    reserved: 0);
                if (result == errorInsufficientBuffer)
                {
                    bufferSize = returnedSize;
                    continue;
                }

                if (result != noError)
                {
                    throw new Win32Exception(unchecked((int)result));
                }

                var rowOffset = Marshal.OffsetOf<MibTcpTableOwnerPid>(
                    nameof(MibTcpTableOwnerPid.FirstRow)).ToInt32();
                var rowSize = Marshal.SizeOf<MibTcpRowOwnerPid>();
                var rowCount = unchecked((uint)Marshal.ReadInt32(buffer));
                var requiredBytes = rowOffset + ((long)rowCount * rowSize);
                if (rowOffset < sizeof(uint) ||
                    rowCount > int.MaxValue ||
                    requiredBytes > returnedSize ||
                    requiredBytes > bufferSize)
                {
                    throw new Win32Exception(errorInvalidData);
                }

                var expectedOwnerFound = false;
                for (var rowIndex = 0; rowIndex < (int)rowCount; rowIndex++)
                {
                    var rowPointer = IntPtr.Add(
                        buffer,
                        checked(rowOffset + (rowIndex * rowSize)));
                    var row = Marshal.PtrToStructure<MibTcpRowOwnerPid>(rowPointer);
                    if (row.State != MibTcpStateListen ||
                        GetHostPort(row.LocalPort) != localPort ||
                        (row.LocalAddress != LoopbackAddress && row.LocalAddress != 0))
                    {
                        continue;
                    }

                    if (row.OwningProcessId != unchecked((uint)expectedProcessId))
                    {
                        return TcpListenerOwnership.UnexpectedProcess;
                    }

                    expectedOwnerFound = true;
                }

                return expectedOwnerFound
                    ? TcpListenerOwnership.ExpectedProcess
                    : TcpListenerOwnership.NotListening;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        throw new Win32Exception(unchecked((int)errorInsufficientBuffer));
    }

    private static int GetHostPort(uint networkPort) =>
        unchecked((ushort)IPAddress.NetworkToHostOrder((short)networkPort));

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern uint GetExtendedTcpTable(
        IntPtr tcpTable,
        ref int size,
        [MarshalAs(UnmanagedType.Bool)] bool order,
        int addressFamily,
        TcpTableClass tableClass,
        uint reserved);

    private enum TcpTableClass
    {
        OwnerPidListener = 3,
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MibTcpRowOwnerPid
    {
        public uint State;
        public uint LocalAddress;
        public uint LocalPort;
        public uint RemoteAddress;
        public uint RemotePort;
        public uint OwningProcessId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MibTcpTableOwnerPid
    {
        public uint NumberOfEntries;
        public MibTcpRowOwnerPid FirstRow;
    }
}
