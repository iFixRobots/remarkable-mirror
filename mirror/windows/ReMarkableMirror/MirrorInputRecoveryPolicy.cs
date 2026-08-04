using System.Diagnostics;

namespace ReMarkableMirror;

/// <summary>
/// Gates every interactive publication and bounds automatic input recovery to
/// one extra handoff per route generation. Established-session loss must couple
/// to display recovery; pre-publication setup failure must first prove cleanup.
/// </summary>
internal sealed class MirrorInputRecoveryPolicy
{
    private readonly object _gate = new();
    private long _scheduledGeneration;
    private long _scheduledTimestamp;
    private long _recentFrameFailureGeneration;
    private long _recentFrameFailureTimestamp;
    private long _consumedGeneration;
    private long _requiredPublicationGeneration;

    public void BeginGeneration(long generationId)
    {
        ValidateGeneration(generationId);
        lock (_gate)
        {
            _scheduledGeneration = 0;
            _scheduledTimestamp = 0;
            _recentFrameFailureGeneration = 0;
            _recentFrameFailureTimestamp = 0;
            _consumedGeneration = 0;
            // A Mirror route is interactive by definition. Its first Live
            // publication is gated on a running input session just like a
            // recovery publication is.
            _requiredPublicationGeneration = generationId;
        }
    }

    public void RecordFrameInterruption(long generationId, long timestamp)
    {
        ValidateGeneration(generationId);
        lock (_gate)
        {
            _recentFrameFailureGeneration = generationId;
            _recentFrameFailureTimestamp = timestamp;
        }
    }

    public MirrorInputRecoveryDisposition RecordPublishedSessionLoss(
        long generationId,
        long timestamp,
        TimeSpan maximumAge,
        bool allowAutomaticRecovery)
    {
        ValidateGeneration(generationId);
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumAge, TimeSpan.Zero);
        lock (_gate)
        {
            // Losing a session that was already published always revokes the
            // Live promise until controls and a fresh frame coexist again.
            _requiredPublicationGeneration = generationId;
            if (!allowAutomaticRecovery || _consumedGeneration == generationId)
            {
                return MirrorInputRecoveryDisposition.None;
            }

            // Spend the one-shot budget before either observer can reset a
            // preparation epoch or perform remote work.
            _consumedGeneration = generationId;
            if (_recentFrameFailureGeneration == generationId)
            {
                var frameFailureTimestamp = _recentFrameFailureTimestamp;
                _recentFrameFailureGeneration = 0;
                _recentFrameFailureTimestamp = 0;
                if (Stopwatch.GetElapsedTime(frameFailureTimestamp, timestamp) <= maximumAge)
                {
                    _scheduledGeneration = 0;
                    _scheduledTimestamp = 0;
                    return MirrorInputRecoveryDisposition.BeginNow;
                }
            }

            // Input was observed first. A nearby frame interruption must consume
            // this marker before the retry latch can be cleared.
            _scheduledGeneration = generationId;
            _scheduledTimestamp = timestamp;
            return MirrorInputRecoveryDisposition.AwaitingFrameInterruption;
        }
    }

    public bool TryConsumeScheduled(
        long generationId,
        long timestamp,
        TimeSpan maximumAge)
    {
        ValidateGeneration(generationId);
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumAge, TimeSpan.Zero);
        lock (_gate)
        {
            if (_scheduledGeneration != generationId)
            {
                return false;
            }

            var scheduledTimestamp = _scheduledTimestamp;
            _scheduledGeneration = 0;
            _scheduledTimestamp = 0;
            if (Stopwatch.GetElapsedTime(scheduledTimestamp, timestamp) > maximumAge)
            {
                return false;
            }

            return true;
        }
    }

    public bool TryReserveStoppedSessionRecovery(long generationId)
    {
        ValidateGeneration(generationId);
        lock (_gate)
        {
            if (_consumedGeneration == generationId)
            {
                return false;
            }

            // Display recovery found the stopped established session first.
            // Reserve the same one-shot budget before disposing or restarting.
            _consumedGeneration = generationId;
            _scheduledGeneration = 0;
            _scheduledTimestamp = 0;
            _requiredPublicationGeneration = generationId;
            return true;
        }
    }

    public bool TryReserveSetupFailureRecovery(long generationId)
    {
        ValidateGeneration(generationId);
        lock (_gate)
        {
            if (_consumedGeneration == generationId)
            {
                return false;
            }

            // A transient failure before publication may spend the same one-shot
            // budget. The host will rebuild both preparation barriers so the
            // next attempt first proves physical restoration again.
            _consumedGeneration = generationId;
            _scheduledGeneration = 0;
            _scheduledTimestamp = 0;
            _recentFrameFailureGeneration = 0;
            _recentFrameFailureTimestamp = 0;
            _requiredPublicationGeneration = generationId;
            return true;
        }
    }

    public bool RequiresInputPublication(long generationId)
    {
        ValidateGeneration(generationId);
        lock (_gate)
        {
            return _requiredPublicationGeneration == generationId;
        }
    }

    public void MarkRecoveryComplete(long generationId)
    {
        ValidateGeneration(generationId);
        lock (_gate)
        {
            if (_requiredPublicationGeneration == generationId)
            {
                _requiredPublicationGeneration = 0;
            }
        }
    }

    public void AbandonGeneration(long generationId)
    {
        ValidateGeneration(generationId);
        lock (_gate)
        {
            if (_scheduledGeneration == generationId)
            {
                _scheduledGeneration = 0;
                _scheduledTimestamp = 0;
            }
            if (_recentFrameFailureGeneration == generationId)
            {
                _recentFrameFailureGeneration = 0;
                _recentFrameFailureTimestamp = 0;
            }
            if (_requiredPublicationGeneration == generationId)
            {
                _requiredPublicationGeneration = 0;
            }
        }
    }

    public void RearmGeneration(long generationId)
    {
        ValidateGeneration(generationId);
        lock (_gate)
        {
            if (_scheduledGeneration == generationId)
            {
                _scheduledGeneration = 0;
                _scheduledTimestamp = 0;
            }
            if (_recentFrameFailureGeneration == generationId)
            {
                _recentFrameFailureGeneration = 0;
                _recentFrameFailureTimestamp = 0;
            }
            if (_consumedGeneration == generationId)
            {
                _consumedGeneration = 0;
            }
            // Explicit Retry starts a fresh interactive publication attempt.
            _requiredPublicationGeneration = generationId;
        }
    }

    public void Reset()
    {
        lock (_gate)
        {
            _scheduledGeneration = 0;
            _scheduledTimestamp = 0;
            _recentFrameFailureGeneration = 0;
            _recentFrameFailureTimestamp = 0;
            _consumedGeneration = 0;
            _requiredPublicationGeneration = 0;
        }
    }

    private static void ValidateGeneration(long generationId) =>
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(generationId, 0);
}

internal enum MirrorInputRecoveryDisposition
{
    None,
    AwaitingFrameInterruption,
    BeginNow,
}
