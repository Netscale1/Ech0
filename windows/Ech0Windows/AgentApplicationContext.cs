using System.Diagnostics;

namespace Ech0.Windows;

internal sealed class AgentApplicationContext : ApplicationContext
{
    private readonly NotifyIcon tray = new();
    private readonly ToolStripMenuItem stateItem = new("Starting") { Enabled = false };
    private readonly ToolStripMenuItem deviceItem = new("Microphone: closed") { Enabled = false };
    private readonly ToolStripMenuItem pauseItem = new("Pause automatic capture");
    private readonly Control dispatcher = new();
    private readonly Icon disconnectedIcon = TrayIcons.Load("Ech0Disconnected.ico");
    private readonly Icon waitingIcon = TrayIcons.Load("Ech0Waiting.ico");
    private readonly Icon unavailableIcon = TrayIcons.Load("Ech0Unavailable.ico");
    private readonly Icon capturingIcon = TrayIcons.Load("Ech0Capturing.ico");
    private readonly SemaphoreSlim workerLifecycleGate = new(1, 1);
    private AutomationShutdownListener? automationControl;
    private Ech0Settings settings;
    private ConnectionWorker? worker;
    private bool paused;
    private bool isExiting;
    private AgentState currentState = AgentState.Disconnected;

    public AgentApplicationContext(AutomationControlOptions? automationControlOptions = null)
    {
        settings = SettingsStore.Load();
        dispatcher.CreateControl();
        var menu = new ContextMenuStrip();
        menu.Items.Add(stateItem);
        menu.Items.Add(deviceItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(pauseItem);
        menu.Items.Add("Settings", null, (_, _) => ShowSettings());
        menu.Items.Add("Open logs", null, (_, _) => OpenLogs());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, async (_, _) => await ExitAsync());
        pauseItem.Click += (_, _) => TogglePause();

        tray.ContextMenuStrip = menu;
        tray.Icon = disconnectedIcon;
        tray.Text = "Ech0: starting";
        tray.Visible = true;
        tray.DoubleClick += (_, _) => ShowSettings();

        if (automationControlOptions is not null)
        {
            automationControl = new AutomationShutdownListener(
                automationControlOptions,
                RequestAutomationExit);
        }

        if (!settings.IsConfigured)
        {
            ShowSettings();
        }
        else
        {
            StartWorker();
        }
    }

    private void ShowSettings()
    {
        using var form = new SettingsForm(settings, currentState, StopWorkerAsync);
        if (form.ShowDialog() != DialogResult.OK)
        {
            settings = SettingsStore.Load();
            if (!settings.IsConfigured)
            {
                SetState(AgentState.PairingRequired, null);
            }
            else if (worker is null)
            {
                StartWorker();
            }
            return;
        }
        settings = SettingsStore.Load();
        if (settings.IsConfigured)
        {
            StartWorker();
        }
        else
        {
            SetState(AgentState.PairingRequired, null);
        }
    }

    private void StartWorker() => _ = StartWorkerAsync();

    private async Task StartWorkerAsync()
    {
        await workerLifecycleGate.WaitAsync();
        try
        {
            if (isExiting)
            {
                return;
            }

            await StopWorkerUnlockedAsync();
            var nextWorker = new ConnectionWorker(settings, paused);
            worker = nextWorker;
            nextWorker.StateChanged += OnStateChanged;
            _ = nextWorker.RunAsync();
        }
        catch (Exception exception)
        {
            Log.Write("worker_start_failed", exception.GetType().Name);
            SetState(AgentState.Disconnected, exception.GetType().Name);
        }
        finally
        {
            workerLifecycleGate.Release();
        }
    }

    private async Task StopWorkerAsync()
    {
        await workerLifecycleGate.WaitAsync();
        try
        {
            await StopWorkerUnlockedAsync();
        }
        finally
        {
            workerLifecycleGate.Release();
        }
    }

    private async Task StopWorkerUnlockedAsync()
    {
        var current = worker;
        worker = null;
        if (current is not null)
        {
            current.StateChanged -= OnStateChanged;
            await current.DisposeAsync();
        }
    }

    private void OnStateChanged(ConnectionWorker source, AgentState state, string? detail)
    {
        if (!ReferenceEquals(worker, source))
        {
            return;
        }
        if (dispatcher.InvokeRequired)
        {
            dispatcher.BeginInvoke(() =>
            {
                if (ReferenceEquals(worker, source))
                {
                    SetState(state, detail);
                }
            });
            return;
        }
        SetState(state, detail);
    }

    private void SetState(AgentState state, string? detail)
    {
        var previousState = currentState;
        currentState = state;
        var label = state switch
        {
            AgentState.Connecting => "Connecting",
            AgentState.PairingRequired => "Pairing required",
            AgentState.Idle => "Connected — waiting for microphone demand",
            AgentState.DemandWaitingForDevice => "Microphone unavailable",
            AgentState.Capturing => "Transmitting microphone",
            AgentState.Paused => "Automatic capture paused",
            _ => "Disconnected",
        };
        stateItem.Text = detail is null ? label : $"{label}: {detail}";
        deviceItem.Text = state == AgentState.Capturing
            ? $"Microphone: {detail ?? worker?.CurrentDeviceName ?? "active"}"
            : "Microphone: closed";
        tray.Icon = state switch
        {
            AgentState.Capturing => capturingIcon,
            AgentState.DemandWaitingForDevice => unavailableIcon,
            AgentState.PairingRequired => unavailableIcon,
            AgentState.Idle or AgentState.Paused => waitingIcon,
            _ => disconnectedIcon,
        };
        tray.Text = $"Ech0: {label}"[..Math.Min(63, $"Ech0: {label}".Length)];
        if (state == AgentState.PairingRequired && previousState != AgentState.PairingRequired)
        {
            tray.BalloonTipTitle = "Ech0 pairing required";
            tray.BalloonTipText = "Open Ech0 Settings and enter the current code shown on the Mac.";
            tray.BalloonTipIcon = ToolTipIcon.Warning;
            tray.ShowBalloonTip(5_000);
        }
    }

    private void TogglePause()
    {
        paused = !paused;
        pauseItem.Text = paused ? "Resume automatic capture" : "Pause automatic capture";
        worker?.SetPaused(paused);
    }

    private static void OpenLogs()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Log.CurrentPath)!);
        if (!File.Exists(Log.CurrentPath))
        {
            File.WriteAllText(Log.CurrentPath, "");
        }
        Process.Start(new ProcessStartInfo("notepad.exe", $"\"{Log.CurrentPath}\"") { UseShellExecute = true });
    }

    private async Task ExitAsync()
    {
        if (isExiting)
        {
            return;
        }
        isExiting = true;
        tray.Visible = false;
        await StopWorkerAsync();
        if (automationControl is not null)
        {
            await automationControl.DisposeAsync();
            automationControl = null;
        }
        tray.Dispose();
        ExitThread();
    }

    private void RequestAutomationExit()
    {
        if (!dispatcher.IsDisposed)
        {
            dispatcher.BeginInvoke(new Action(() => _ = ExitAsync()));
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            automationControl?.Dispose();
            automationControl = null;
            tray.Dispose();
            dispatcher.Dispose();
            disconnectedIcon.Dispose();
            waitingIcon.Dispose();
            unavailableIcon.Dispose();
            capturingIcon.Dispose();
        }
        base.Dispose(disposing);
    }
}
