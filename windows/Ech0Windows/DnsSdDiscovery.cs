using System.Net;
using System.Runtime.InteropServices;

namespace Ech0.Windows;

internal sealed record DiscoveredService(string InstanceName, string HostName, int Port);

internal static class DnsSdDiscovery
{
    private const uint ErrorCancelled = 1223;
    private const uint DnsRequestPending = 9506;
    private const ushort DnsTypePtr = 12;

    public static async Task<DiscoveredService?> FindFirstAsync(TimeSpan timeout, CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10))
        {
            return null;
        }

        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        var serviceName = await BrowseFirstNameAsync(timeoutSource.Token);
        return serviceName is null ? null : await ResolveAsync(serviceName, timeoutSource.Token);
    }

    public static async Task<bool> WaitForServiceAsync(
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10))
        {
            return false;
        }

        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        return await BrowseFirstNameAsync(timeoutSource.Token) is not null;
    }

    private static async Task<string?> BrowseFirstNameAsync(CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        BrowseCallback callback = (status, _, records) =>
        {
            try
            {
                if (status == ErrorCancelled)
                {
                    return;
                }
                if (status != 0)
                {
                    completion.TrySetResult(null);
                    return;
                }
                for (var record = records; record != IntPtr.Zero; record = Marshal.ReadIntPtr(record, 0))
                {
                    if ((ushort)Marshal.ReadInt16(record, IntPtr.Size * 2) != DnsTypePtr)
                    {
                        continue;
                    }
                    var targetPointer = Marshal.ReadIntPtr(record, 32);
                    var name = Marshal.PtrToStringUni(targetPointer);
                    if (!string.IsNullOrWhiteSpace(name))
                    {
                        completion.TrySetResult(name);
                        break;
                    }
                }
            }
            finally
            {
                if (records != IntPtr.Zero)
                {
                    DnsRecordListFree(records, 1);
                }
                if (status == ErrorCancelled)
                {
                    stopped.TrySetResult();
                }
            }
        };
        var queryName = Marshal.StringToHGlobalUni("_ech0._tcp.local");
        var request = new DnsServiceBrowseRequest
        {
            Version = 1,
            InterfaceIndex = 0,
            QueryName = queryName,
            Callback = callback,
            QueryContext = IntPtr.Zero,
        };
        var cancel = new DnsServiceCancel();
        try
        {
            var status = DnsServiceBrowse(ref request, ref cancel);
            if (status != DnsRequestPending)
            {
                return null;
            }
            using var registration = cancellationToken.Register(() => completion.TrySetResult(null));
            return await completion.Task;
        }
        finally
        {
            if (cancel.Reserved != IntPtr.Zero)
            {
                var status = DnsServiceBrowseCancel(ref cancel);
                if (status == 0)
                {
                    await stopped.Task;
                }
            }
            Marshal.FreeHGlobal(queryName);
            GC.KeepAlive(callback);
        }
    }

    private static async Task<DiscoveredService?> ResolveAsync(string instanceName, CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<DiscoveredService?>(TaskCreationOptions.RunContinuationsAsynchronously);
        ResolveCallback callback = (status, _, instancePointer) =>
        {
            if (status != 0 || instancePointer == IntPtr.Zero)
            {
                completion.TrySetResult(null);
                return;
            }
            try
            {
                var instance = Marshal.PtrToStructure<DnsServiceInstance>(instancePointer);
                var resolvedName = Marshal.PtrToStringUni(instance.InstanceName) ?? instanceName;
                var hostName = Marshal.PtrToStringUni(instance.HostName)?.TrimEnd('.');
                completion.TrySetResult(
                    string.IsNullOrWhiteSpace(hostName)
                        ? null
                        : new DiscoveredService(resolvedName, hostName, instance.Port));
            }
            finally
            {
                DnsServiceFreeInstance(instancePointer);
            }
        };
        var queryName = Marshal.StringToHGlobalUni(instanceName);
        var request = new DnsServiceResolveRequest
        {
            Version = 1,
            InterfaceIndex = 0,
            QueryName = queryName,
            Callback = callback,
            QueryContext = IntPtr.Zero,
        };
        var cancel = new DnsServiceCancel();
        try
        {
            var status = DnsServiceResolve(ref request, ref cancel);
            if (status != DnsRequestPending)
            {
                return null;
            }
            using var registration = cancellationToken.Register(() => completion.TrySetResult(null));
            return await completion.Task;
        }
        finally
        {
            if (cancel.Reserved != IntPtr.Zero)
            {
                DnsServiceResolveCancel(ref cancel);
            }
            Marshal.FreeHGlobal(queryName);
            GC.KeepAlive(callback);
        }
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void BrowseCallback(uint status, IntPtr queryContext, IntPtr records);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void ResolveCallback(uint status, IntPtr queryContext, IntPtr instance);

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceBrowseRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr QueryName;
        public BrowseCallback Callback;
        public IntPtr QueryContext;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceResolveRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr QueryName;
        public ResolveCallback Callback;
        public IntPtr QueryContext;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceCancel
    {
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceInstance
    {
        public IntPtr InstanceName;
        public IntPtr HostName;
        public IntPtr Ip4Address;
        public IntPtr Ip6Address;
        public ushort Port;
        public ushort Priority;
        public ushort Weight;
        public uint PropertyCount;
        public IntPtr Keys;
        public IntPtr Values;
        public uint InterfaceIndex;
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    private static extern uint DnsServiceBrowse(ref DnsServiceBrowseRequest request, ref DnsServiceCancel cancel);

    [DllImport("dnsapi.dll")]
    private static extern uint DnsServiceBrowseCancel(ref DnsServiceCancel cancel);

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    private static extern uint DnsServiceResolve(ref DnsServiceResolveRequest request, ref DnsServiceCancel cancel);

    [DllImport("dnsapi.dll")]
    private static extern uint DnsServiceResolveCancel(ref DnsServiceCancel cancel);

    [DllImport("dnsapi.dll")]
    private static extern void DnsServiceFreeInstance(IntPtr instance);

    [DllImport("dnsapi.dll")]
    private static extern void DnsRecordListFree(IntPtr records, int freeType);
}
