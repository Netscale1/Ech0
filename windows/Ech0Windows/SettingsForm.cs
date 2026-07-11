using NAudio.CoreAudioApi;

namespace Ech0.Windows;

internal sealed class SettingsForm : Form
{
    private readonly TextBox host = new() { Dock = DockStyle.Fill };
    private readonly NumericUpDown port = new() { Minimum = 1, Maximum = 65_535, Value = 48_484, Dock = DockStyle.Fill };
    private readonly TextBox token = new() { MaxLength = 6, Dock = DockStyle.Fill };
    private readonly CheckBox launchAtLogin = new() { Text = "Start Ech0 with Windows", Checked = true, AutoSize = true };
    private readonly ComboBox inputDevice = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    private readonly Label discoveryStatus = new() { Text = "", AutoSize = true };
    private readonly Button discover = new() { Text = "Find Mac automatically", AutoSize = true };
    private readonly Button save = new() { Text = "Save and connect", AutoSize = true };

    public SettingsForm(Ech0Settings settings)
    {
        Text = "Ech0 Windows Settings";
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(16);

        host.Text = settings.Host;
        port.Value = Math.Clamp(settings.Port, 1, 65_535);
        token.Text = settings.PairingToken;
        launchAtLogin.Checked = settings.LaunchAtLogin;
        LoadInputDevices(settings.InputDeviceId);

        var layout = new TableLayoutPanel
        {
            AutoSize = true,
            ColumnCount = 2,
            Dock = DockStyle.Fill,
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 300));
        AddRow(layout, "Mac host", host);
        AddRow(layout, "Port", port);
        AddRow(layout, "Pairing code", token);
        AddRow(layout, "Windows microphone", inputDevice);
        layout.Controls.Add(discover, 1, 4);
        layout.Controls.Add(discoveryStatus, 1, 5);
        layout.Controls.Add(launchAtLogin, 1, 6);
        layout.Controls.Add(save, 1, 7);
        Controls.Add(layout);

        discover.Click += async (_, _) => await DiscoverAsync();
        save.Click += (_, _) => Save(settings);
        Shown += async (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(host.Text))
            {
                await DiscoverAsync();
            }
        };
    }

    private async Task DiscoverAsync()
    {
        discover.Enabled = false;
        discoveryStatus.Text = "Searching on the local network...";
        try
        {
            var result = await DnsSdDiscovery.FindFirstAsync(TimeSpan.FromSeconds(5), CancellationToken.None);
            if (result is null)
            {
                discoveryStatus.Text = "Mac not found. Enter its IP address manually.";
                return;
            }
            host.Text = result.HostName;
            port.Value = result.Port;
            discoveryStatus.Text = $"Found {result.InstanceName}";
        }
        catch (Exception exception)
        {
            discoveryStatus.Text = $"Discovery unavailable: {exception.GetType().Name}";
        }
        finally
        {
            discover.Enabled = true;
        }
    }

    private void Save(Ech0Settings settings)
    {
        if (string.IsNullOrWhiteSpace(host.Text) || token.Text.Length != 6 || !token.Text.All(char.IsDigit))
        {
            MessageBox.Show(this, "Enter a Mac host and the six-digit pairing code.", "Ech0", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        settings.Host = host.Text.Trim();
        settings.Port = (int)port.Value;
        settings.PairingToken = token.Text;
        settings.LaunchAtLogin = launchAtLogin.Checked;
        settings.InputDeviceId = (inputDevice.SelectedItem as InputDeviceChoice)?.Id ?? "";
        SettingsStore.Save(settings);
        AutoStartManager.Configure(settings.LaunchAtLogin);
        DialogResult = DialogResult.OK;
        Close();
    }

    private static void AddRow(TableLayoutPanel layout, string label, Control control)
    {
        var row = layout.RowCount++;
        layout.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left }, 0, row);
        layout.Controls.Add(control, 1, row);
    }

    private void LoadInputDevices(string selectedId)
    {
        inputDevice.Items.Add(new InputDeviceChoice("", "Windows default input"));
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active | DeviceState.Unplugged))
            {
                inputDevice.Items.Add(new InputDeviceChoice(device.ID, device.FriendlyName));
            }
        }
        catch (Exception exception)
        {
            Log.Write("device_enumeration_failed", exception.GetType().Name);
        }
        var selected = inputDevice.Items
            .Cast<InputDeviceChoice>()
            .FirstOrDefault(choice => choice.Id == selectedId);
        inputDevice.SelectedItem = selected ?? inputDevice.Items[0];
    }

    private sealed record InputDeviceChoice(string Id, string Label)
    {
        public override string ToString() => Label;
    }
}
