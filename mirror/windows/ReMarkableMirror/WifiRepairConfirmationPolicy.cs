namespace ReMarkableMirror;

/// <summary>
/// Prevents one transitional Wi-Fi capability result from being presented as
/// a durable tablet repair requirement. Direct USB setup failures do not pass
/// through this policy.
/// </summary>
internal sealed class WifiRepairConfirmationPolicy
{
    private const int RequiredConsecutiveMatches = 2;
    private int _consecutiveMatches;

    public bool Record(bool identityAuthenticated, bool tabletPrerequisiteMismatch)
    {
        if (!identityAuthenticated || !tabletPrerequisiteMismatch)
        {
            Reset();
            return false;
        }

        _consecutiveMatches = Math.Min(
            _consecutiveMatches + 1,
            RequiredConsecutiveMatches);
        return _consecutiveMatches >= RequiredConsecutiveMatches;
    }

    public void Reset() => _consecutiveMatches = 0;
}
