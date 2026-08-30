namespace ReMarkableMirror;

/// <summary>
/// Archives this PC's pairing files for a tablet whose identity no longer
/// matches, so first-time setup can run again. Files are moved, never
/// deleted, and the dedicated private key is kept for reuse.
/// </summary>
public static class RetiredPairingArchive
{
    public static string ArchiveCurrentPairing()
    {
        var sshDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".ssh");
        var archiveDirectory = Path.Combine(
            sshDirectory,
            $"retired-pairing-{DateTime.Now:yyyyMMdd-HHmmss}");
        Directory.CreateDirectory(archiveDirectory);

        MoveIfPresent(DeviceProfileStore.GetDefaultProfilePath(), archiveDirectory);
        MoveIfPresent(
            Path.Combine(sshDirectory, "remarkable_chiappa_wake_token"),
            archiveDirectory);
        // The pinned identity moves last so a partial failure stays closed:
        // with the old known_hosts still in place, pairing keeps rejecting.
        MoveIfPresent(
            Path.Combine(sshDirectory, "remarkable_known_hosts"),
            archiveDirectory);
        return archiveDirectory;
    }

    private static void MoveIfPresent(string path, string archiveDirectory)
    {
        if (File.Exists(path))
        {
            File.Move(path, Path.Combine(archiveDirectory, Path.GetFileName(path)));
        }
    }
}
