using Xunit;

namespace Ech0.Windows.Tests;

public sealed class AutomationControlTests
{
    [Fact]
    public void NormalStartupDoesNotEnableAutomationControl()
    {
        Assert.True(AutomationControlOptions.TryParse(["--background"], out var options));
        Assert.Null(options);
    }

    [Fact]
    public void ValidAutomationTokenIsNormalized()
    {
        Assert.True(AutomationControlOptions.TryParse(
            ["--background", "--automation-control", "ABCDEF0123456789ABCDEF0123456789"],
            out var options));

        Assert.Equal("abcdef0123456789abcdef0123456789", options!.Token);
        Assert.Equal(
            "Ech0WindowsAutomation-abcdef0123456789abcdef0123456789",
            options.PipeName);
    }

    [Theory]
    [InlineData("--automation-control")]
    [InlineData("--automation-control", "not-a-guid")]
    [InlineData(
        "--automation-control", "abcdef0123456789abcdef0123456789",
        "--automation-control", "0123456789abcdef0123456789abcdef")]
    public void InvalidAutomationArgumentsFailClosed(params string[] args)
    {
        Assert.False(AutomationControlOptions.TryParse(args, out var options));
        Assert.Null(options);
    }

    [Fact]
    public async Task ShutdownCommandIsDeliveredExactlyOnce()
    {
        var options = new AutomationControlOptions(Guid.NewGuid().ToString("N"));
        var shutdownCount = 0;
        await using var listener = new AutomationShutdownListener(
            options,
            () => Interlocked.Increment(ref shutdownCount));
        await listener.Ready;

        Assert.True(await AutomationShutdownListener.RequestShutdownAsync(
            options,
            TimeSpan.FromSeconds(2),
            TestContext.Current.CancellationToken));
        await WaitForAsync(
            () => Volatile.Read(ref shutdownCount) == 1,
            TestContext.Current.CancellationToken);
        Assert.False(await AutomationShutdownListener.RequestShutdownAsync(
            options,
            TimeSpan.FromMilliseconds(100),
            TestContext.Current.CancellationToken));
        Assert.Equal(1, Volatile.Read(ref shutdownCount));
    }

    [Fact]
    public async Task DifferentTokenCannotStopListener()
    {
        var options = new AutomationControlOptions(Guid.NewGuid().ToString("N"));
        var wrongOptions = new AutomationControlOptions(Guid.NewGuid().ToString("N"));
        var shutdownCount = 0;
        await using var listener = new AutomationShutdownListener(
            options,
            () => Interlocked.Increment(ref shutdownCount));
        await listener.Ready;

        Assert.False(await AutomationShutdownListener.RequestShutdownAsync(
            wrongOptions,
            TimeSpan.FromMilliseconds(100),
            TestContext.Current.CancellationToken));
        Assert.Equal(0, Volatile.Read(ref shutdownCount));
        Assert.True(await AutomationShutdownListener.RequestShutdownAsync(
            options,
            TimeSpan.FromSeconds(2),
            TestContext.Current.CancellationToken));
        await WaitForAsync(
            () => Volatile.Read(ref shutdownCount) == 1,
            TestContext.Current.CancellationToken);
    }

    private static async Task WaitForAsync(Func<bool> condition, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(2));
        while (!condition())
        {
            await Task.Delay(10, timeout.Token);
        }
    }
}
