namespace Ech0.Windows;

internal static class Log
{
    private static readonly object Gate = new();
    private static readonly string DirectoryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Ech0",
        "logs");
    public static string CurrentPath => Path.Combine(DirectoryPath, "ech0.log");

    public static void Write(string eventName, string? detail = null)
    {
        _ = TryWrite(() =>
        {
            lock (Gate)
            {
                Directory.CreateDirectory(DirectoryPath);
                RotateIfNeeded();
                var safeDetail = detail?.Replace('\r', ' ').Replace('\n', ' ');
                File.AppendAllText(CurrentPath, $"{DateTimeOffset.Now:O}\t{eventName}\t{safeDetail}{Environment.NewLine}");
            }
        });
    }

    internal static bool TryWrite(Action operation)
    {
        try
        {
            operation();
            return true;
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or System.Security.SecurityException)
        {
            return false;
        }
    }

    private static void RotateIfNeeded()
    {
        if (!File.Exists(CurrentPath) || new FileInfo(CurrentPath).Length < 1_000_000)
        {
            return;
        }
        for (var index = 3; index >= 1; index--)
        {
            var source = index == 1 ? CurrentPath : Path.Combine(DirectoryPath, $"ech0.{index - 1}.log");
            var destination = Path.Combine(DirectoryPath, $"ech0.{index}.log");
            if (File.Exists(source))
            {
                File.Move(source, destination, true);
            }
        }
    }
}
