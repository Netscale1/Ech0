using System.IO.Pipes;
using System.Text;

namespace Ech0.Windows;

internal sealed record AutomationControlOptions(string Token)
{
    private const string Flag = "--automation-control";

    public string PipeName => $"Ech0WindowsAutomation-{Token}";

    public static bool TryParse(string[] args, out AutomationControlOptions? options)
    {
        options = null;
        var flagIndex = Array.IndexOf(args, Flag);
        if (flagIndex < 0)
        {
            return true;
        }
        if (flagIndex + 1 >= args.Length || Array.LastIndexOf(args, Flag) != flagIndex)
        {
            return false;
        }
        if (!Guid.TryParseExact(args[flagIndex + 1], "N", out var token))
        {
            return false;
        }

        options = new AutomationControlOptions(token.ToString("N"));
        return true;
    }
}

internal sealed class AutomationShutdownListener : IAsyncDisposable, IDisposable
{
    private const string ShutdownCommand = "shutdown";
    private readonly CancellationTokenSource stop = new();
    private readonly Action shutdownRequested;
    private readonly Task runTask;
    private int disposed;

    public Task Ready { get; }

    public AutomationShutdownListener(AutomationControlOptions options, Action shutdownRequested)
    {
        this.shutdownRequested = shutdownRequested;
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Ready = ready.Task;
        runTask = RunAsync(options.PipeName, ready, stop.Token);
    }

    public static async Task<bool> RequestShutdownAsync(
        AutomationControlOptions options,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        try
        {
            await using var pipe = new NamedPipeClientStream(
                ".",
                options.PipeName,
                PipeDirection.Out,
                PipeOptions.Asynchronous);
            await pipe.ConnectAsync(timeoutSource.Token);
            await using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true)
            {
                AutoFlush = true,
            };
            await writer.WriteLineAsync(ShutdownCommand.AsMemory(), timeoutSource.Token);
            return true;
        }
        catch (OperationCanceledException) when (timeoutSource.IsCancellationRequested)
        {
            return false;
        }
        catch (IOException)
        {
            return false;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }
        await stop.CancelAsync();
        await runTask;
        stop.Dispose();
    }

    public void Dispose() => DisposeAsync().AsTask().GetAwaiter().GetResult();

    private async Task RunAsync(
        string pipeName,
        TaskCompletionSource ready,
        CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                await using var pipe = new NamedPipeServerStream(
                    pipeName,
                    PipeDirection.In,
                    1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                ready.TrySetResult();
                await pipe.WaitForConnectionAsync(cancellationToken);
                using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
                var command = await reader.ReadLineAsync(cancellationToken);
                if (command == ShutdownCommand)
                {
                    shutdownRequested();
                    return;
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (IOException) when (cancellationToken.IsCancellationRequested)
        {
        }
        finally
        {
            ready.TrySetResult();
        }
    }
}
