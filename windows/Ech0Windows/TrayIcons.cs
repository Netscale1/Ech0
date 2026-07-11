using System.Reflection;

namespace Ech0.Windows;

internal static class TrayIcons
{
    public static Icon Load(string name)
    {
        var resourceName = $"Ech0.Windows.Resources.{name}";
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"Missing tray icon resource {resourceName}.");
        using var icon = new Icon(stream);
        return (Icon)icon.Clone();
    }
}
