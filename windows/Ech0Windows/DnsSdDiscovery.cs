using System.Net;
using System.Runtime.InteropServices;
using System.Threading.Channels;

namespace Ech0.Windows;

internal sealed record DiscoveredService(string HostName, int Port);

internal sealed class ServiceAvailabilityEvents
{
    private readonly Channel<byte> events = Channel.CreateBounded<byte>(
        new BoundedChannelOptions(1)
        {
            AllowSynchronousContinuations = false,
            FullMode = BoundedChannelFullMode.DropWrite,
            SingleReader = true,
            SingleWriter = false,
        });

    public void Notify() => events.Writer.TryWrite(0);

    public void Complete() => events.Writer.TryComplete();

    public async Task<bool> WaitAsync(CancellationToken cancellationToken)
    {
        try
        {
            _ = await events.Reader.ReadAsync(cancellationToken);
            return true;
        }
        catch (ChannelClosedException)
        {
            return false;
        }
    }
}

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

    public static ServiceWatcher? StartServiceWatcher()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10))
        {
            return null;
        }

        var watcher = new ServiceWatcher();
        return watcher.Start() ? watcher : null;
    }

    internal sealed class ServiceWatcher : IAsyncDisposable
    {
        private readonly ServiceAvailabilityEvents events = new();
        private readonly MdnsQueryCallback callback;
        private readonly IntPtr queryName;
        private MdnsQueryHandle handle;
        private int disposed;

        public ServiceWatcher()
        {
            callback = OnResult;
            queryName = Marshal.StringToHGlobalUni("_ech0._tcp.local");
        }

        public Task<bool> WaitAsync(CancellationToken cancellationToken) =>
            events.WaitAsync(cancellationToken);

        public bool Start()
        {
            var request = new MdnsQueryRequest
            {
                Version = 1,
                ReferenceCount = 0,
                Query = queryName,
                QueryType = DnsTypePtr,
                QueryOptions = 0,
                InterfaceIndex = 0,
                Callback = callback,
                QueryContext = IntPtr.Zero,
                AnswerReceived = 0,
                ResendCount = 0,
            };
            var status = DnsStartMulticastQuery(ref request, ref handle);
            if (status == 0)
            {
                return true;
            }

            events.Complete();
            Marshal.FreeHGlobal(queryName);
            disposed = 1;
            return false;
        }

        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0)
            {
                return;
            }

            events.Complete();
            _ = DnsStopMulticastQuery(ref handle);
            Marshal.FreeHGlobal(queryName);
            GC.KeepAlive(callback);
            await ValueTask.CompletedTask;
        }

        private void OnResult(IntPtr _, IntPtr __, IntPtr resultPointer)
        {
            if (resultPointer == IntPtr.Zero)
            {
                return;
            }
            var result = Marshal.PtrToStructure<DnsQueryResult>(resultPointer);
            var records = result.QueryRecords;
            try
            {
                if (result.QueryStatus != 0)
                {
                    events.Complete();
                    return;
                }
                for (var record = records; record != IntPtr.Zero; record = Marshal.ReadIntPtr(record, 0))
                {
                    var type = (ushort)Marshal.ReadInt16(record, IntPtr.Size * 2);
                    var timeToLive = (uint)Marshal.ReadInt32(record, 24);
                    if (type == DnsTypePtr && timeToLive > 0)
                    {
                        events.Notify();
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
            }
        }
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
                var hostName = Marshal.PtrToStringUni(instance.HostName)?.TrimEnd('.');
                completion.TrySetResult(
                    string.IsNullOrWhiteSpace(hostName)
                        ? null
                        : new DiscoveredService(hostName, instance.Port));
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

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    internal delegate void MdnsQueryCallback(
        IntPtr queryContext,
        IntPtr queryHandle,
        IntPtr queryResults);

    [StructLayout(LayoutKind.Sequential)]
    internal struct MdnsQueryRequest
    {
        public uint Version;
        public uint ReferenceCount;
        public IntPtr Query;
        public ushort QueryType;
        public ulong QueryOptions;
        public uint InterfaceIndex;
        public MdnsQueryCallback Callback;
        public IntPtr QueryContext;
        public int AnswerReceived;
        public uint ResendCount;
    }

    [StructLayout(LayoutKind.Explicit, Size = 544)]
    internal struct MdnsQueryHandle
    {
        [FieldOffset(512)] public ushort Type;
        [FieldOffset(520)] public IntPtr Subscription;
        [FieldOffset(528)] public IntPtr CallbackParameters;
        [FieldOffset(536)] public uint StateNameData0;
        [FieldOffset(540)] public uint StateNameData1;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DnsQueryResult
    {
        public uint Version;
        public uint QueryStatus;
        public ulong QueryOptions;
        public IntPtr QueryRecords;
        public IntPtr Reserved;
    }

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

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    private static extern uint DnsStartMulticastQuery(
        ref MdnsQueryRequest queryRequest,
        ref MdnsQueryHandle handle);

    [DllImport("dnsapi.dll")]
    private static extern uint DnsStopMulticastQuery(ref MdnsQueryHandle handle);

    [DllImport("dnsapi.dll")]
    private static extern void DnsServiceFreeInstance(IntPtr instance);

    [DllImport("dnsapi.dll")]
    private static extern void DnsRecordListFree(IntPtr records, int freeType);
}
