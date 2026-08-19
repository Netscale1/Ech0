namespace Ech0.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (!AutomationControlOptions.TryParse(args, out var automationControl))
        {
            return 2;
        }

        ApplicationConfiguration.Initialize();
        using var mutex = new Mutex(true, "Local\\Ech0WindowsAgent", out var ownsMutex);
        if (!ownsMutex)
        {
            return 0;
        }
        using var context = new AgentApplicationContext(automationControl);
        Application.Run(context);
        return 0;
    }
}
