#nullable enable

using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Security;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace ReMarkableMirror;

/// <summary>
/// Persists one strictly validated, non-secret device profile under LocalAppData.
/// </summary>
public sealed class DeviceProfileStore
{
    private const int MaximumProfileBytes = 16 * 1024;
    private const int MaximumKnownHostsBytes = 64 * 1024;
    private const int MaximumKnownHostKeyBytes = 16 * 1024;
    private const string ExpectedHostKeyType = "ssh-ed25519";
    private const string ApplicationDirectoryName = "ReMarkableMirror";
    private const string ProfileFileName = "device-profile.json";

    private readonly string _profilePath;
    private readonly string _knownHostsPath;

    public DeviceProfileStore()
        : this(GetDefaultProfilePath(), GetDefaultKnownHostsPath())
    {
    }

    // Kept non-public so product code cannot accidentally move pairing state out of LocalAppData.
    internal DeviceProfileStore(string profilePath)
        : this(profilePath, GetDefaultKnownHostsPath())
    {
    }

    internal DeviceProfileStore(string profilePath, string knownHostsPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profilePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(knownHostsPath);
        _profilePath = Path.GetFullPath(profilePath);
        _knownHostsPath = Path.GetFullPath(knownHostsPath);
    }

    public static string GetDefaultProfilePath()
    {
        var localAppData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData,
            Environment.SpecialFolderOption.DoNotVerify);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new InvalidOperationException("LocalAppData is unavailable.");
        }

        return Path.Combine(localAppData, ApplicationDirectoryName, ProfileFileName);
    }

    private static string GetDefaultKnownHostsPath()
    {
        var userProfile = Environment.GetFolderPath(
            Environment.SpecialFolder.UserProfile,
            Environment.SpecialFolderOption.DoNotVerify);
        if (string.IsNullOrWhiteSpace(userProfile))
        {
            throw new InvalidOperationException("The Windows user profile is unavailable.");
        }

        return Path.Combine(userProfile, ".ssh", "remarkable_known_hosts");
    }

    public DeviceProfileLoadResult Load()
    {
        if (!OperatingSystem.IsWindows())
        {
            return new DeviceProfileLoadResult(DeviceProfileLoadStatus.Unavailable, null);
        }

        try
        {
            var file = new FileInfo(_profilePath);
            if (!file.Exists)
            {
                return new DeviceProfileLoadResult(DeviceProfileLoadStatus.NotFound, null);
            }
            if ((file.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                return new DeviceProfileLoadResult(DeviceProfileLoadStatus.InsecurePermissions, null);
            }
            if (!HasCurrentUserOnlyAcl(file))
            {
                return new DeviceProfileLoadResult(DeviceProfileLoadStatus.InsecurePermissions, null);
            }
            if (file.Length is <= 0 or > MaximumProfileBytes)
            {
                return new DeviceProfileLoadResult(DeviceProfileLoadStatus.Corrupt, null);
            }

            using var stream = new FileStream(
                _profilePath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read | FileShare.Delete,
                bufferSize: 4096,
                FileOptions.SequentialScan);
            var profile = JsonSerializer.Deserialize(
                stream,
                DeviceProfileJsonContext.Default.DeviceProfile);
            if (profile is null)
            {
                return new DeviceProfileLoadResult(DeviceProfileLoadStatus.Corrupt, null);
            }
            if (!string.Equals(profile.Schema, DeviceProfile.CurrentSchema, StringComparison.Ordinal))
            {
                return new DeviceProfileLoadResult(DeviceProfileLoadStatus.UnsupportedVersion, null);
            }
            if (!IsValid(profile))
            {
                return new DeviceProfileLoadResult(DeviceProfileLoadStatus.Corrupt, null);
            }
            if (!MatchesPinnedSshIdentity(profile))
            {
                return new DeviceProfileLoadResult(
                    DeviceProfileLoadStatus.PinnedIdentityMismatch,
                    null);
            }

            return new DeviceProfileLoadResult(DeviceProfileLoadStatus.Ready, profile);
        }
        catch (UnauthorizedAccessException)
        {
            return new DeviceProfileLoadResult(DeviceProfileLoadStatus.AccessDenied, null);
        }
        catch (JsonException)
        {
            return new DeviceProfileLoadResult(DeviceProfileLoadStatus.Corrupt, null);
        }
        catch (Exception exception) when (exception is
            IOException or
            SecurityException or
            ArgumentException or
            NotSupportedException)
        {
            return new DeviceProfileLoadResult(DeviceProfileLoadStatus.Unavailable, null);
        }
    }

    public void Save(DeviceProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("The device profile uses Windows ACLs.");
        }
        if (!string.Equals(profile.Schema, DeviceProfile.CurrentSchema, StringComparison.Ordinal) ||
            !IsValid(profile))
        {
            throw new ArgumentException("The device profile is invalid.", nameof(profile));
        }

        var directoryPath = Path.GetDirectoryName(_profilePath);
        if (string.IsNullOrWhiteSpace(directoryPath))
        {
            throw new InvalidOperationException("The device profile path has no parent directory.");
        }

        Directory.CreateDirectory(directoryPath);
        var directory = new DirectoryInfo(directoryPath);
        if ((directory.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new IOException("The device profile directory cannot be a reparse point.");
        }
        ApplyCurrentUserOnlyAcl(directory);

        var temporaryPath = Path.Combine(
            directoryPath,
            $".{ProfileFileName}.{Guid.NewGuid():N}.tmp");

        try
        {
            using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                bufferSize: 4096,
                FileOptions.WriteThrough))
            {
                ApplyCurrentUserOnlyAcl(new FileInfo(temporaryPath));
                JsonSerializer.Serialize(
                    stream,
                    profile,
                    DeviceProfileJsonContext.Default.DeviceProfile);
                stream.Flush(flushToDisk: true);
                if (stream.Length is <= 0 or > MaximumProfileBytes)
                {
                    throw new InvalidDataException("The serialized device profile has an invalid size.");
                }
            }

            PublishAtomically(temporaryPath);
            ApplyCurrentUserOnlyAcl(new FileInfo(_profilePath));
        }
        finally
        {
            try
            {
                File.Delete(temporaryPath);
            }
            catch (IOException)
            {
                // A successfully published temporary file no longer exists. A failed cleanup
                // leaves only a current-user-only same-directory temporary file.
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private void PublishAtomically(string temporaryPath)
    {
        var destination = new FileInfo(_profilePath);
        if (destination.Exists)
        {
            if ((destination.Attributes & FileAttributes.ReparsePoint) != 0 ||
                !HasCurrentUserOnlyAcl(destination))
            {
                throw new UnauthorizedAccessException("Refusing to replace an insecure device profile path.");
            }

            File.Replace(temporaryPath, _profilePath, destinationBackupFileName: null);
            return;
        }

        File.Move(temporaryPath, _profilePath);
    }

    private static bool IsValid(DeviceProfile profile)
    {
        return IsSafeHostKeyAlias(profile.SshHostKeyAlias) &&
            IsSha256Fingerprint(profile.SshFingerprint) &&
            IsSafeNetworkHost(profile.LastVerifiedWifiHost) &&
            Guid.TryParse(profile.PairedWindowsInterfaceId, out _) &&
            IsSafeOpaqueIdentifier(profile.PairedWindowsNetworkIdentity, 256) &&
            profile.FilesTarget is not null &&
            IsSafeNetworkHost(profile.FilesTarget.Host) &&
            profile.FilesTarget.Port is >= 1 and <= 65535 &&
            IsAbsoluteTokenReference(profile.TokenFileReference) &&
            profile.LastVerified is not null &&
            profile.LastVerified.VerifiedAtUtc != default &&
            profile.LastVerified.VerifiedAtUtc.Offset == TimeSpan.Zero &&
            Guid.TryParseExact(profile.LastVerified.BootId, "D", out _) &&
            IsSafeUnixPath(profile.LastVerified.ActiveRoot) &&
            IsSafeOpaqueIdentifier(profile.LastVerified.OsVersion, 256) &&
            IsSafeOpaqueIdentifier(profile.LastVerified.KernelRelease, 256) &&
            IsSafeCapabilityValue(profile.LastVerified.WakeCapabilitySchema) &&
            IsSafeCapabilityValue(profile.LastVerified.CompanionVersion);
    }

    private static bool IsSafeHostKeyAlias(string? value) =>
        IsSafeAsciiToken(value, 255, allowSlash: false);

    private bool MatchesPinnedSshIdentity(DeviceProfile profile)
    {
        try
        {
            var knownHosts = new FileInfo(_knownHostsPath);
            if (!knownHosts.Exists ||
                knownHosts.Length is <= 0 or > MaximumKnownHostsBytes ||
                (knownHosts.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                return false;
            }

            var applicableKeys = 0;
            foreach (var line in File.ReadLines(_knownHostsPath, Encoding.UTF8))
            {
                if (line.Length > MaximumProfileBytes)
                {
                    return false;
                }

                var trimmed = line.Trim();
                if (trimmed.Length == 0 || trimmed.StartsWith('#'))
                {
                    continue;
                }

                var fields = trimmed.Split(
                    (char[]?)null,
                    StringSplitOptions.RemoveEmptyEntries);
                if (fields.Length == 0)
                {
                    continue;
                }

                var hasMarker = fields[0].StartsWith('@');
                var hostFieldIndex = hasMarker ? 1 : 0;
                if (fields.Length <= hostFieldIndex)
                {
                    continue;
                }
                if (!KnownHostListMatchesAlias(
                        fields[hostFieldIndex],
                        profile.SshHostKeyAlias))
                {
                    continue;
                }

                applicableKeys++;
                var keyTypeIndex = hostFieldIndex + 1;
                var keyBlobIndex = hostFieldIndex + 2;
                if (applicableKeys != 1 ||
                    hasMarker ||
                    fields.Length <= keyBlobIndex ||
                    !string.Equals(
                        fields[keyTypeIndex],
                        ExpectedHostKeyType,
                        StringComparison.Ordinal))
                {
                    return false;
                }

                byte[] keyBlob;
                try
                {
                    keyBlob = Convert.FromBase64String(fields[keyBlobIndex]);
                }
                catch (FormatException)
                {
                    return false;
                }
                if (keyBlob.Length is <= 0 or > MaximumKnownHostKeyBytes)
                {
                    return false;
                }

                var fingerprint = "SHA256:" +
                    Convert.ToBase64String(SHA256.HashData(keyBlob)).TrimEnd('=');
                if (!string.Equals(
                        fingerprint,
                        profile.SshFingerprint,
                        StringComparison.Ordinal))
                {
                    return false;
                }
            }

            return applicableKeys == 1;
        }
        catch (Exception exception) when (exception is
            IOException or
            UnauthorizedAccessException or
            SecurityException or
            ArgumentException or
            NotSupportedException)
        {
        }

        return false;
    }

    private static bool KnownHostListMatchesAlias(string hostList, string alias)
    {
        var positiveMatch = false;
        foreach (var entry in hostList.Split(',', StringSplitOptions.RemoveEmptyEntries))
        {
            var negated = entry.StartsWith('!');
            var candidate = negated ? entry[1..] : entry;
            if (!KnownHostEntryMatchesAlias(candidate, alias))
            {
                continue;
            }
            if (negated)
            {
                return false;
            }
            positiveMatch = true;
        }

        return positiveMatch;
    }

    private static bool KnownHostEntryMatchesAlias(string entry, string alias)
    {
        if (!entry.StartsWith("|1|", StringComparison.Ordinal))
        {
            return MatchesHostPattern(entry, alias) ||
                MatchesHostPattern(entry, $"[{alias}]:22");
        }

        var components = entry.Split('|');
        if (components.Length != 4 ||
            !string.Equals(components[1], "1", StringComparison.Ordinal))
        {
            return false;
        }

        try
        {
            var salt = Convert.FromBase64String(components[2]);
            var expected = Convert.FromBase64String(components[3]);
            if (salt.Length == 0 || expected.Length != 20)
            {
                return false;
            }

            // OpenSSH known_hosts format 1 is defined as HMAC-SHA1 over the host token.
            using var hmac = new HMACSHA1(salt);
            var aliasHash = hmac.ComputeHash(Encoding.UTF8.GetBytes(alias));
            if (CryptographicOperations.FixedTimeEquals(aliasHash, expected))
            {
                return true;
            }

            var portQualifiedAlias = $"[{alias}]:22";
            var qualifiedHash = hmac.ComputeHash(Encoding.UTF8.GetBytes(portQualifiedAlias));
            return CryptographicOperations.FixedTimeEquals(qualifiedHash, expected);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static bool MatchesHostPattern(string pattern, string value)
    {
        var patternIndex = 0;
        var valueIndex = 0;
        var starIndex = -1;
        var starValueIndex = -1;

        while (valueIndex < value.Length)
        {
            if (patternIndex < pattern.Length &&
                (pattern[patternIndex] == '?' ||
                 char.ToUpperInvariant(pattern[patternIndex]) ==
                 char.ToUpperInvariant(value[valueIndex])))
            {
                patternIndex++;
                valueIndex++;
                continue;
            }

            if (patternIndex < pattern.Length && pattern[patternIndex] == '*')
            {
                starIndex = patternIndex++;
                starValueIndex = valueIndex;
                continue;
            }

            if (starIndex >= 0)
            {
                patternIndex = starIndex + 1;
                valueIndex = ++starValueIndex;
                continue;
            }

            return false;
        }

        while (patternIndex < pattern.Length && pattern[patternIndex] == '*')
        {
            patternIndex++;
        }
        return patternIndex == pattern.Length;
    }

    private static bool IsSafeNetworkHost(string? value)
    {
        if (!IsSafeAsciiToken(value, 255, allowSlash: false))
        {
            return false;
        }

        return IPAddress.TryParse(value, out _) ||
            Uri.CheckHostName(value) is UriHostNameType.Dns;
    }

    private static bool IsSha256Fingerprint(string? value)
    {
        const string prefix = "SHA256:";
        if (value is null || !value.StartsWith(prefix, StringComparison.Ordinal))
        {
            return false;
        }

        var encoded = value[prefix.Length..];
        if (encoded.Length != 43 || encoded.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) || character is '+' or '/')))
        {
            return false;
        }

        try
        {
            return Convert.FromBase64String(encoded + "=").Length == 32;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static bool IsAbsoluteTokenReference(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 1024 || !Path.IsPathFullyQualified(value))
        {
            return false;
        }

        try
        {
            return string.Equals(value, Path.GetFullPath(value), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is
            ArgumentException or
            NotSupportedException or
            PathTooLongException)
        {
            return false;
        }
    }

    private static bool IsSafeUnixPath(string? value) =>
        value is not null &&
        value.Length is >= 2 and <= 256 &&
        value[0] == '/' &&
        !value.Any(character => char.IsControl(character) || char.IsWhiteSpace(character));

    private static bool IsSafeCapabilityValue(string? value) =>
        IsSafeAsciiToken(value, 256, allowSlash: true);

    private static bool IsSafeOpaqueIdentifier(string? value, int maximumLength) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= maximumLength &&
        !value.Any(character => char.IsControl(character));

    private static bool IsSafeAsciiToken(string? value, int maximumLength, bool allowSlash)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > maximumLength)
        {
            return false;
        }

        return value.All(character =>
            char.IsAsciiLetterOrDigit(character) ||
            character is '.' or '_' or '-' or ':' or '+' or '=' ||
            (allowSlash && character == '/'));
    }

    private static void ApplyCurrentUserOnlyAcl(FileSystemInfo fileSystemInfo)
    {
        var sid = WindowsIdentity.GetCurrent().User ??
            throw new InvalidOperationException("Could not determine the current Windows user SID.");

        if (fileSystemInfo is DirectoryInfo directory)
        {
            var security = new DirectorySecurity();
            security.SetOwner(sid);
            security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
            security.AddAccessRule(new FileSystemAccessRule(
                sid,
                FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None,
                AccessControlType.Allow));
            FileSystemAclExtensions.SetAccessControl(directory, security);
            return;
        }

        var fileSecurity = new FileSecurity();
        fileSecurity.SetOwner(sid);
        fileSecurity.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        fileSecurity.AddAccessRule(new FileSystemAccessRule(
            sid,
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        FileSystemAclExtensions.SetAccessControl((FileInfo)fileSystemInfo, fileSecurity);
    }

    internal static bool HasCurrentUserOnlyAcl(FileInfo file)
    {
        var sid = WindowsIdentity.GetCurrent().User;
        if (sid is null)
        {
            return false;
        }

        var security = FileSystemAclExtensions.GetAccessControl(file);
        if (!security.AreAccessRulesProtected || !sid.Equals(security.GetOwner(typeof(SecurityIdentifier))))
        {
            return false;
        }

        var rules = security.GetAccessRules(
            includeExplicit: true,
            includeInherited: false,
            targetType: typeof(SecurityIdentifier));
        var matchingRules = 0;
        foreach (FileSystemAccessRule rule in rules)
        {
            if (rule.AccessControlType != AccessControlType.Allow ||
                !sid.Equals(rule.IdentityReference) ||
                (rule.FileSystemRights & FileSystemRights.FullControl) != FileSystemRights.FullControl)
            {
                return false;
            }
            matchingRules++;
        }

        return matchingRules == 1;
    }
}

public enum DeviceProfileLoadStatus
{
    Ready,
    NotFound,
    UnsupportedVersion,
    Corrupt,
    PinnedIdentityMismatch,
    InsecurePermissions,
    AccessDenied,
    Unavailable,
}

public sealed record DeviceProfileLoadResult(
    DeviceProfileLoadStatus Status,
    DeviceProfile? Profile);
