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
    private Ech0Settings settings;
    private ConnectionWorker? worker;
    private bool paused;

    public AgentApplicationContext()
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
        using var form = new SettingsForm(settings);
        if (form.ShowDialog() != DialogResult.OK)
        {
            if (!settings.IsConfigured)
            {
                SetState(AgentState.Disconnected, "Setup required");
            }
            return;
        }
        settings = SettingsStore.Load();
        StartWorker();
    }

    private async void StartWorker()
    {
        await StopWorkerAsync();
        worker = new ConnectionWorker(settings);
        worker.StateChanged += OnStateChanged;
        _ = worker.RunAsync();
    }

    private async Task StopWorkerAsync()
    {
        var current = worker;
        worker = null;
        if (current is not null)
        {
            current.StateChanged -= OnStateChanged;
            await current.DisposeAsync();
        }
    }

    private void OnStateChanged(AgentState state, string? detail)
    {
        if (dispatcher.InvokeRequired)
        {
            dispatcher.BeginInvoke(() => SetState(state, detail));
            return;
        }
        SetState(state, detail);
    }

    private void SetState(AgentState state, string? detail)
    {
        var label = state switch
        {
            AgentState.Connecting => "Connecting",
            AgentState.Idle => "Connected — waiting for BlackHole",
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
            AgentState.Idle or AgentState.Paused => waitingIcon,
            _ => disconnectedIcon,
        };
        tray.Text = $"Ech0: {label}"[..Math.Min(63, $"Ech0: {label}".Length)];
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
        tray.Visible = false;
        await StopWorkerAsync();
        tray.Dispose();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
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
