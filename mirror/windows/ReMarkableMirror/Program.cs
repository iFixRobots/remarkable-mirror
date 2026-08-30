using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace ReMarkableMirror;

public static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (AskPassBridge.IsRequested)
        {
            Environment.ExitCode = AskPassBridge.RunClient();
            return;
        }

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_applicationInitializationCallbackParams =>
        {
            var context = new DispatcherQueueSynchronizationContext(
                DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            new App();
        });
    }
}
