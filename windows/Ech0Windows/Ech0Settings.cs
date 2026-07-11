using System.Security.Cryptography;
using System.Text.Json;

namespace Ech0.Windows;

internal sealed class Ech0Settings
{
    public string Host { get; set; } = "";
    public int Port { get; set; } = 48_484;
    public string DeviceName { get; set; } = Environment.MachineName;
    public string InputDeviceId { get; set; } = "";
    public string SenderId { get; set; } = Guid.NewGuid().ToString("D");
    public string ProtectedTrustedSecret { get; set; } = "";
    public string ProtectedPairingToken { get; set; } = "";
    public bool LaunchAtLogin { get; set; } = true;

    public bool IsConfigured => !string.IsNullOrWhiteSpace(Host) && !string.IsNullOrWhiteSpace(ProtectedPairingToken);

    public string TrustedSecret
    {
        get
        {
            if (string.IsNullOrEmpty(ProtectedTrustedSecret))
            {
                var secret = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
                ProtectedTrustedSecret = SettingsStore.Protect(secret);
                return secret;
            }
            return SettingsStore.Unprotect(ProtectedTrustedSecret);
        }
    }

    public string PairingToken
    {
        get => string.IsNullOrEmpty(ProtectedPairingToken) ? "" : SettingsStore.Unprotect(ProtectedPairingToken);
        set => ProtectedPairingToken = SettingsStore.Protect(value);
    }
}

internal static class SettingsStore
{
    private static readonly string DirectoryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Ech0");
    private static readonly string FilePath = Path.Combine(DirectoryPath, "settings.json");
    private static readonly byte[] Entropy = "Ech0Windows-v1"u8.ToArray();

    public static Ech0Settings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                return JsonSerializer.Deserialize<Ech0Settings>(File.ReadAllText(FilePath)) ?? new Ech0Settings();
            }
        }
        catch (Exception exception)
        {
            Log.Write("settings_load_failed", exception.GetType().Name);
        }
        return new Ech0Settings();
    }

    public static void Save(Ech0Settings settings)
    {
        Directory.CreateDirectory(DirectoryPath);
        _ = settings.TrustedSecret;
        var temporary = FilePath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, FilePath, true);
    }

    public static string Protect(string value)
    {
        var bytes = ProtectedData.Protect(
            System.Text.Encoding.UTF8.GetBytes(value),
            Entropy,
            DataProtectionScope.CurrentUser);
        return Convert.ToBase64String(bytes);
    }

    public static string Unprotect(string value)
    {
        var bytes = ProtectedData.Unprotect(Convert.FromBase64String(value), Entropy, DataProtectionScope.CurrentUser);
        return System.Text.Encoding.UTF8.GetString(bytes);
    }
}
