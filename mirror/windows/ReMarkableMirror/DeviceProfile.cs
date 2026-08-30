#nullable enable

using System;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ReMarkableMirror;

/// <summary>
/// Non-secret pairing metadata for one reMarkable tablet.
/// The wake bearer remains only in the file referenced by <see cref="TokenFileReference"/>.
/// </summary>
public sealed record DeviceProfile(
    [property: JsonPropertyName("schema")] string Schema,
    [property: JsonPropertyName("sshHostKeyAlias")] string SshHostKeyAlias,
    [property: JsonPropertyName("sshFingerprint")] string SshFingerprint,
    [property: JsonPropertyName("lastVerifiedWifiHost")] string LastVerifiedWifiHost,
    [property: JsonPropertyName("pairedWindowsInterfaceId")] string PairedWindowsInterfaceId,
    [property: JsonPropertyName("pairedWindowsNetworkIdentity")] string PairedWindowsNetworkIdentity,
    [property: JsonPropertyName("filesTarget")] DeviceProfileFilesTarget FilesTarget,
    [property: JsonPropertyName("tokenFileReference")] string TokenFileReference,
    [property: JsonPropertyName("lastVerified")] DeviceProfileVerification LastVerified)
{
    public const string CurrentSchema = "rmmirror.device-profile/v1";

    /// <summary>
    /// A USB-only profile stores no Wi-Fi route or paired Windows network.
    /// The Wi-Fi pairing fields are recorded as a complete group or not at all.
    /// </summary>
    [JsonIgnore]
    public bool HasWifiPairing => !string.IsNullOrEmpty(LastVerifiedWifiHost);
}

public sealed record DeviceProfileFilesTarget(
    [property: JsonPropertyName("host")] string Host,
    [property: JsonPropertyName("port")] int Port);

public sealed record DeviceProfileVerification(
    [property: JsonPropertyName("verifiedAtUtc")] DateTimeOffset VerifiedAtUtc,
    [property: JsonPropertyName("bootId")] string BootId,
    [property: JsonPropertyName("activeRoot")] string ActiveRoot,
    [property: JsonPropertyName("osVersion")] string OsVersion,
    [property: JsonPropertyName("kernelRelease")] string KernelRelease,
    [property: JsonPropertyName("wakeCapabilitySchema")] string WakeCapabilitySchema,
    [property: JsonPropertyName("companionVersion")] string CompanionVersion);

[JsonSourceGenerationOptions(
    AllowTrailingCommas = false,
    GenerationMode = JsonSourceGenerationMode.Metadata | JsonSourceGenerationMode.Serialization,
    MaxDepth = 8,
    PropertyNameCaseInsensitive = false,
    ReadCommentHandling = JsonCommentHandling.Disallow,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    WriteIndented = true)]
[JsonSerializable(typeof(DeviceProfile))]
internal sealed partial class DeviceProfileJsonContext : JsonSerializerContext
{
}
