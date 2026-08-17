using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Ech0.Windows;

internal enum PairingState
{
    Unpaired,
    PairingPending,
    Trusted,
}

internal sealed class Ech0Settings
{
    public string Host { get; set; } = "";
    public int Port { get; set; } = 48_484;
    public string DeviceName { get; set; } = Environment.MachineName;
    public string InputDeviceId { get; set; } = "";
    public string SenderId { get; set; } = Guid.NewGuid().ToString("D");
    public string ProtectedTrustedSecret { get; set; } = "";
    public string ProtectedPairingToken { get; set; } = "";
    public string ReceiverId { get; set; } = "";
    public string ReceiverName { get; set; } = "";
    public string ReceiverKeyHash { get; set; } = "";
    public bool TrustConfirmed { get; set; }
    public bool LaunchAtLogin { get; set; } = true;

    [JsonIgnore]
    public PairingState PairingState => TrustConfirmed
        && !string.IsNullOrWhiteSpace(ReceiverId)
        && !string.IsNullOrWhiteSpace(ReceiverKeyHash)
        ? PairingState.Trusted
        : !string.IsNullOrWhiteSpace(ProtectedPairingToken)
            ? PairingState.PairingPending
            : PairingState.Unpaired;

    [JsonIgnore]
    public bool IsConfigured => !string.IsNullOrWhiteSpace(Host) && PairingState != PairingState.Unpaired;

    [JsonIgnore]
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

    [JsonIgnore]
    public string PairingToken
    {
        get => string.IsNullOrEmpty(ProtectedPairingToken) ? "" : SettingsStore.Unprotect(ProtectedPairingToken);
        set => ProtectedPairingToken = string.IsNullOrEmpty(value) ? "" : SettingsStore.Protect(value);
    }

    public bool TryCompleteTrust(ServerHello hello)
    {
        if (hello.TrustEstablished != true
            || string.IsNullOrWhiteSpace(hello.ReceiverId)
            || string.IsNullOrWhiteSpace(hello.ReceiverKeyHash))
        {
            return false;
        }

        var receiverName = string.IsNullOrWhiteSpace(hello.ReceiverName) ? Host : hello.ReceiverName;
        var changed = !TrustConfirmed
            || ReceiverId != hello.ReceiverId
            || ReceiverName != receiverName
            || ReceiverKeyHash != hello.ReceiverKeyHash
            || !string.IsNullOrEmpty(ProtectedPairingToken);
        ReceiverId = hello.ReceiverId;
        ReceiverName = receiverName;
        ReceiverKeyHash = hello.ReceiverKeyHash;
        TrustConfirmed = true;
        PairingToken = "";
        return changed;
    }

    public Ech0Settings CreatePairingCandidate(string host, int port, string pairingToken)
    {
        var preserveLegacyIdentity = TrustConfirmed
            && !string.IsNullOrWhiteSpace(ReceiverId)
            && string.IsNullOrWhiteSpace(ReceiverKeyHash)
            && string.Equals(Host, host, StringComparison.OrdinalIgnoreCase)
            && Port == port
            && !string.IsNullOrWhiteSpace(SenderId)
            && !string.IsNullOrWhiteSpace(ProtectedTrustedSecret);
        var candidate = new Ech0Settings
        {
            Host = host,
            Port = port,
            DeviceName = DeviceName,
            InputDeviceId = InputDeviceId,
            SenderId = preserveLegacyIdentity ? SenderId : Guid.NewGuid().ToString("D"),
            ProtectedTrustedSecret = preserveLegacyIdentity ? ProtectedTrustedSecret : "",
            LaunchAtLogin = LaunchAtLogin,
        };
        _ = candidate.TrustedSecret;
        candidate.PairingToken = pairingToken;
        return candidate;
    }

    public void ResetAssociation()
    {
        Host = "";
        Port = 48_484;
        ReceiverId = "";
        ReceiverName = "";
        ReceiverKeyHash = "";
        TrustConfirmed = false;
        PairingToken = "";
        SenderId = Guid.NewGuid().ToString("D");
        ProtectedTrustedSecret = "";
        _ = TrustedSecret;
    }

    public void MarkPairingRequired()
    {
        TrustConfirmed = false;
        PairingToken = "";
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
        AtomicSettingsFile.Write(
            FilePath,
            () =>
            {
                _ = settings.TrustedSecret;
                return JsonSerializer.Serialize(
                    settings,
                    new JsonSerializerOptions { WriteIndented = true });
            });
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

internal static class AtomicSettingsFile
{
    private static readonly object WriteGate = new();

    public static void Write(string filePath, Func<string> contentFactory)
    {
        lock (WriteGate)
        {
            var directory = Path.GetDirectoryName(filePath)
                ?? throw new InvalidOperationException("Settings path has no parent directory.");
            Directory.CreateDirectory(directory);
            var temporary = $"{filePath}.{Guid.NewGuid():N}.tmp";
            try
            {
                File.WriteAllText(temporary, contentFactory());
                File.Move(temporary, filePath, true);
            }
            finally
            {
                if (File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
        }
    }
}
