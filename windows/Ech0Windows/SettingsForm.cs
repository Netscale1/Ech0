using NAudio.CoreAudioApi;

namespace Ech0.Windows;

internal sealed class SettingsForm : Form
{
    private readonly Ech0Settings settings;
    private readonly AgentState currentState;
    private readonly Func<Task> suspendConnection;
    private readonly TextBox host = new() { Dock = DockStyle.Fill };
    private readonly NumericUpDown port = new() { Minimum = 1, Maximum = 65_535, Value = 48_484, Dock = DockStyle.Fill };
    private readonly TextBox token = new()
    {
        MaxLength = 40,
        CharacterCasing = CharacterCasing.Upper,
        Dock = DockStyle.Fill,
    };
    private readonly CheckBox launchAtLogin = new() { Text = "Start Ech0 with Windows", Checked = true, AutoSize = true };
    private readonly ComboBox inputDevice = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    private readonly Label discoveryStatus = new() { Text = "", AutoSize = true };
    private readonly Button discover = new() { Text = "Find Mac automatically", AutoSize = true };
    private readonly Button pair = new() { Text = "Pair", AutoSize = true };
    private readonly CancellationTokenSource formLifetime = new();
    private bool changingMac;
    private bool formLifetimeDisposed;

    public SettingsForm(Ech0Settings settings, AgentState currentState, Func<Task> suspendConnection)
    {
        this.settings = settings;
        this.currentState = currentState;
        this.suspendConnection = suspendConnection;

        Text = "Ech0 Windows Settings";
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(18);

        launchAtLogin.Checked = settings.LaunchAtLogin;
        LoadInputDevices(settings.InputDeviceId);
        ShowCurrentMode();
    }

    protected override void OnFormClosed(FormClosedEventArgs eventArgs)
    {
        formLifetime.Cancel();
        base.OnFormClosed(eventArgs);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing && !formLifetimeDisposed)
        {
            formLifetimeDisposed = true;
            formLifetime.Cancel();
            formLifetime.Dispose();
        }
        base.Dispose(disposing);
    }

    private void ShowCurrentMode()
    {
        Controls.Clear();
        if (settings.PairingState == PairingState.Trusted && !changingMac)
        {
            Controls.Add(BuildTrustedPanel());
        }
        else
        {
            Controls.Add(BuildPairingPanel());
        }
    }

    private Control BuildTrustedPanel()
    {
        var layout = CreateLayout();
        var connected = currentState is AgentState.Idle
            or AgentState.Capturing
            or AgentState.Paused
            or AgentState.DemandWaitingForDevice;
        var status = connected ? "Connected · Trusted" : "Trusted · not reachable";
        AddRow(layout, "Mac", new Label { Text = settings.ReceiverName, AutoSize = true });
        AddRow(layout, "Status", new Label { Text = status, AutoSize = true });
        AddRow(layout, "Address", new Label { Text = $"{settings.Host}:{settings.Port}", AutoSize = true });
        AddRow(layout, "Receiver ID", new Label { Text = Abbreviate(settings.ReceiverId), AutoSize = true });
        AddRow(layout, "Windows microphone", inputDevice);
        layout.Controls.Add(launchAtLogin, 1, layout.RowCount++);

        var actions = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight };
        var save = new Button { Text = "Save", AutoSize = true };
        var change = new Button { Text = "Change Mac…", AutoSize = true };
        var reset = new Button { Text = "Reset pairing…", AutoSize = true };
        save.Click += (_, _) => SaveTrustedPreferences();
        change.Click += async (_, _) => await BeginChangeMacAsync();
        reset.Click += async (_, _) => await ResetPairingAsync();
        actions.Controls.Add(save);
        actions.Controls.Add(change);
        actions.Controls.Add(reset);
        layout.Controls.Add(actions, 1, layout.RowCount++);
        return layout;
    }

    private Control BuildPairingPanel()
    {
        host.Text = changingMac ? "" : settings.Host;
        port.Value = changingMac ? 48_484 : Math.Clamp(settings.Port, 1, 65_535);
        token.Text = "";
        discoveryStatus.Text = changingMac
            ? "The current trusted Mac remains saved until the new pairing succeeds."
            : "The security code is only used for this first encrypted pairing.";

        var layout = CreateLayout();
        var title = new Label
        {
            Text = changingMac ? "Pair a different Mac" : "Pair this Windows PC",
            Font = new Font(Font, FontStyle.Bold),
            AutoSize = true,
        };
        layout.Controls.Add(title, 0, layout.RowCount);
        layout.SetColumnSpan(title, 2);
        layout.RowCount++;
        AddRow(layout, "Mac host", host);
        AddRow(layout, "Port", port);
        AddRow(layout, "Code for a new device", token);
        AddRow(layout, "Windows microphone", inputDevice);
        layout.Controls.Add(discover, 1, layout.RowCount++);
        layout.Controls.Add(discoveryStatus, 1, layout.RowCount++);
        layout.Controls.Add(launchAtLogin, 1, layout.RowCount++);

        var actions = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight };
        pair.Click -= PairClick;
        pair.Click += PairClick;
        actions.Controls.Add(pair);
        if (changingMac)
        {
            var cancel = new Button { Text = "Cancel", AutoSize = true };
            cancel.Click += (_, _) => { DialogResult = DialogResult.Cancel; Close(); };
            actions.Controls.Add(cancel);
        }
        layout.Controls.Add(actions, 1, layout.RowCount++);

        discover.Click -= DiscoverClick;
        discover.Click += DiscoverClick;
        Shown -= DiscoverWhenEmpty;
        Shown += DiscoverWhenEmpty;
        return layout;
    }

    private async void PairClick(object? sender, EventArgs eventArgs) => await PairAsync();
    private async void DiscoverClick(object? sender, EventArgs eventArgs) => await DiscoverAsync();
    private async void DiscoverWhenEmpty(object? sender, EventArgs eventArgs)
    {
        if (string.IsNullOrWhiteSpace(host.Text))
        {
            await DiscoverAsync();
        }
    }

    private async Task BeginChangeMacAsync()
    {
        try
        {
            await suspendConnection().WaitAsync(formLifetime.Token);
            changingMac = true;
            ShowCurrentMode();
        }
        catch (OperationCanceledException) when (formLifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            Log.Write("change_mac_failed", exception.GetType().Name);
            if (!IsDisposed && !Disposing)
            {
                MessageBox.Show(this, "Ech0 could not suspend the current connection.", "Ech0", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }

    private async Task ResetPairingAsync()
    {
        var answer = MessageBox.Show(
            this,
            "This removes the trusted relationship from this PC. You will need the current code shown on the Mac to pair again.",
            "Reset Ech0 pairing",
            MessageBoxButtons.OKCancel,
            MessageBoxIcon.Warning);
        if (answer != DialogResult.OK)
        {
            return;
        }

        try
        {
            await suspendConnection().WaitAsync(formLifetime.Token);
            settings.ResetAssociation();
            SettingsStore.Save(settings);
            changingMac = false;
            ShowCurrentMode();
        }
        catch (OperationCanceledException) when (formLifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            Log.Write("reset_pairing_failed", exception.GetType().Name);
            if (!IsDisposed && !Disposing)
            {
                MessageBox.Show(this, "Ech0 could not reset pairing.", "Ech0", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }

    private async Task PairAsync()
    {
        var pairingCode = PairingCode.Normalize(token.Text);
        if (string.IsNullOrWhiteSpace(host.Text) || pairingCode is null)
        {
            MessageBox.Show(this, "Enter a Mac host and its current security code.", "Ech0", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        pair.Enabled = false;
        discover.Enabled = false;
        discoveryStatus.Text = "Pairing securely on the local network…";
        try
        {
            await suspendConnection().WaitAsync(formLifetime.Token);
            var candidate = settings.CreatePairingCandidate(
                host.Text.Trim(),
                (int)port.Value,
                pairingCode);
            candidate.InputDeviceId = SelectedInputDeviceId();
            candidate.LaunchAtLogin = launchAtLogin.Checked;
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
                formLifetime.Token);
            timeout.CancelAfter(TimeSpan.FromSeconds(8));
            var hello = await PairingProbe.PairAsync(candidate, timeout.Token);
            if (!candidate.TryCompleteTrust(hello))
            {
                throw new InvalidOperationException("The Mac did not confirm the trusted relationship.");
            }
            SettingsStore.Save(candidate);
            AutoStartManager.Configure(candidate.LaunchAtLogin);
            DialogResult = DialogResult.OK;
            Close();
        }
        catch (OperationCanceledException) when (formLifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            Log.Write("pairing_failed", exception.GetType().Name);
            if (IsDisposed || Disposing)
            {
                return;
            }
            discoveryStatus.Text = exception is PairingRequiredException
                ? "The code was rejected. Generate or copy the current code from the Mac."
                : $"Pairing failed: {exception.GetType().Name}";
            pair.Enabled = true;
            discover.Enabled = true;
        }
    }

    private async Task DiscoverAsync()
    {
        discover.Enabled = false;
        pair.Enabled = false;
        discoveryStatus.Text = "Searching on the local network…";
        try
        {
            var result = await DnsSdDiscovery.FindFirstAsync(
                TimeSpan.FromSeconds(5),
                formLifetime.Token);
            if (result is null)
            {
                discoveryStatus.Text = "Mac not found. Enter its IP address manually.";
                return;
            }
            host.Text = result.HostName;
            port.Value = result.Port;
            discoveryStatus.Text = $"Found {result.InstanceName}";
        }
        catch (OperationCanceledException) when (formLifetime.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            if (!IsDisposed && !Disposing)
            {
                discoveryStatus.Text = $"Discovery unavailable: {exception.GetType().Name}";
            }
        }
        finally
        {
            if (!IsDisposed && !Disposing)
            {
                discover.Enabled = true;
                pair.Enabled = true;
            }
        }
    }

    private void SaveTrustedPreferences()
    {
        try
        {
            settings.InputDeviceId = SelectedInputDeviceId();
            settings.LaunchAtLogin = launchAtLogin.Checked;
            SettingsStore.Save(settings);
            AutoStartManager.Configure(settings.LaunchAtLogin);
            DialogResult = DialogResult.OK;
            Close();
        }
        catch (Exception exception)
        {
            Log.Write("settings_save_failed", exception.GetType().Name);
            MessageBox.Show(this, "Ech0 could not save these settings.", "Ech0", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private string SelectedInputDeviceId()
        => (inputDevice.SelectedItem as InputDeviceChoice)?.Id ?? "";

    private static TableLayoutPanel CreateLayout()
    {
        var layout = new TableLayoutPanel { AutoSize = true, ColumnCount = 2, Dock = DockStyle.Fill };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 320));
        return layout;
    }

    private static void AddRow(TableLayoutPanel layout, string label, Control control)
    {
        var row = layout.RowCount++;
        layout.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left }, 0, row);
        layout.Controls.Add(control, 1, row);
    }

    private static string Abbreviate(string value)
        => value.Length <= 12 ? value : $"{value[..8]}…{value[^4..]}";

    private void LoadInputDevices(string selectedId)
    {
        inputDevice.Items.Clear();
        inputDevice.Items.Add(new InputDeviceChoice("", "Windows default input"));
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active | DeviceState.Unplugged))
            {
                using (device)
                {
                    inputDevice.Items.Add(new InputDeviceChoice(device.ID, device.FriendlyName));
                }
            }
        }
        catch (Exception exception)
        {
            Log.Write("device_enumeration_failed", exception.GetType().Name);
        }
        var selected = inputDevice.Items.Cast<InputDeviceChoice>().FirstOrDefault(choice => choice.Id == selectedId);
        inputDevice.SelectedItem = selected ?? inputDevice.Items[0];
    }

    private sealed record InputDeviceChoice(string Id, string Label)
    {
        public override string ToString() => Label;
    }
}
