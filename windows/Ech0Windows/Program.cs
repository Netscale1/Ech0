namespace Ech0.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        using var mutex = new Mutex(true, "Local\\Ech0WindowsAgent", out var ownsMutex);
        if (!ownsMutex)
        {
            return;
        }
        Application.Run(new AgentApplicationContext());
    }
}
