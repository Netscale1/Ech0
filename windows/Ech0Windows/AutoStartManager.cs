using Microsoft.Win32;

namespace Ech0.Windows;

internal static class AutoStartManager
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Ech0Windows";
    public static string InstallDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Ech0");
    public static string InstalledExecutablePath => Path.Combine(InstallDirectory, "Ech0Windows.exe");

    public static void Configure(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (!enabled)
        {
            key.DeleteValue(ValueName, false);
            return;
        }

        Directory.CreateDirectory(InstallDirectory);
        var currentExecutable = Environment.ProcessPath
            ?? throw new InvalidOperationException("Cannot determine the executable path.");
        if (!Path.GetFullPath(currentExecutable).Equals(Path.GetFullPath(InstalledExecutablePath), StringComparison.OrdinalIgnoreCase))
        {
            File.Copy(currentExecutable, InstalledExecutablePath, true);
        }
        key.SetValue(ValueName, $"\"{InstalledExecutablePath}\" --background", RegistryValueKind.String);
    }
}
