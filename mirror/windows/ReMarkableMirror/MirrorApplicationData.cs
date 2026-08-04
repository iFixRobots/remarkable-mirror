using Windows.Storage;

namespace ReMarkableMirror;

internal static class MirrorApplicationData
{
    private const string Publisher = "iFixRobots";
    private const string Product = "reMarkable Mirror";
    private static readonly Lazy<ApplicationDataFolders> Folders = new(
        ResolveFolders,
        LazyThreadSafetyMode.ExecutionAndPublication);

    public static StorageFolder LocalFolder => Folders.Value.LocalFolder;

    public static StorageFolder TemporaryFolder => Folders.Value.TemporaryFolder;

    private static ApplicationDataFolders ResolveFolders()
    {
#if REMARKABLE_MIRROR_PORTABLE
        var localPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Publisher,
            Product);
        var temporaryPath = Path.Combine(
            Path.GetTempPath(),
            Publisher,
            Product);
        Directory.CreateDirectory(localPath);
        Directory.CreateDirectory(temporaryPath);
        return new(
            StorageFolder.GetFolderFromPathAsync(localPath).AsTask().GetAwaiter().GetResult(),
            StorageFolder.GetFolderFromPathAsync(temporaryPath).AsTask().GetAwaiter().GetResult());
#else
        var packagedApplicationData = Windows.Storage.ApplicationData.Current;
        return new(
            packagedApplicationData.LocalFolder,
            packagedApplicationData.TemporaryFolder);
#endif
    }

    private sealed record ApplicationDataFolders(
        StorageFolder LocalFolder,
        StorageFolder TemporaryFolder);
}
