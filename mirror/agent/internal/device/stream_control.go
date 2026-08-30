package device

import (
	"context"
	"io"
	"sync"
	"time"
)

const (
	minimumFrameStreamHeartbeatTimeout = 5 * time.Second
	maximumFrameStreamHeartbeatTimeout = 2 * time.Minute
)

type streamHeartbeatEvent struct {
	err error
}

// StreamFramesWithLease owns one frame stream and the stdin lifetime signal for
// the same SSH session. A zero heartbeat timeout preserves the unleased CLI
// behavior while still honoring stdin EOF and parent cancellation.
func StreamFramesWithLease(
	ctx context.Context,
	heartbeatReader io.Reader,
	writer io.Writer,
	interval time.Duration,
	heartbeatTimeout time.Duration,
) error {
	if heartbeatTimeout < 0 ||
		(heartbeatTimeout > 0 && heartbeatTimeout < minimumFrameStreamHeartbeatTimeout) ||
		heartbeatTimeout > maximumFrameStreamHeartbeatTimeout {
		return codedError{code: "invalid_heartbeat_timeout"}
	}

	return runFrameStreamLease(
		ctx,
		heartbeatReader,
		heartbeatTimeout,
		func(streamContext context.Context) error {
			return StreamFrames(streamContext, writer, interval)
		},
	)
}

// runFrameStreamLease deliberately does not join stream after the session
// owner disappears. StreamFrames can be blocked in an operating-system write;
// returning lets main terminate the process and therefore that blocked worker.
func runFrameStreamLease(
	ctx context.Context,
	heartbeatReader io.Reader,
	heartbeatTimeout time.Duration,
	stream func(context.Context) error,
) error {
	if ctx == nil {
		ctx = context.Background()
	}
	if ctx.Err() != nil {
		return nil
	}

	streamContext, cancelStream := context.WithCancel(ctx)
	defer cancelStream()

	heartbeats, stopHeartbeats := readStreamHeartbeats(heartbeatReader)
	defer stopHeartbeats()

	streamResult := make(chan error, 1)
	go func() {
		streamResult <- stream(streamContext)
	}()

	var heartbeatTimer *time.Timer
	var heartbeatExpired <-chan time.Time
	if heartbeatTimeout > 0 {
		heartbeatTimer = time.NewTimer(heartbeatTimeout)
		heartbeatExpired = heartbeatTimer.C
		defer heartbeatTimer.Stop()
	}

	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-streamResult:
			if ctx.Err() != nil {
				return nil
			}
			return err
		case heartbeat, ok := <-heartbeats:
			if !ok || heartbeat.err != nil {
				return nil
			}
			if heartbeatTimer != nil {
				resetStreamHeartbeatTimer(heartbeatTimer, heartbeatTimeout)
			}
		case <-heartbeatExpired:
			return codedError{code: "heartbeat_timeout"}
		}
	}
}

func readStreamHeartbeats(reader io.Reader) (<-chan streamHeartbeatEvent, func()) {
	events := make(chan streamHeartbeatEvent, 1)
	done := make(chan struct{})
	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			close(done)
		})
	}
	if reader == nil {
		return nil, stop
	}

	send := func(event streamHeartbeatEvent) bool {
		select {
		case events <- event:
			return true
		case <-done:
			return false
		}
	}
	go func() {
		defer close(events)
		buffer := make([]byte, 64)
		for {
			bytesRead, err := reader.Read(buffer)
			if bytesRead > 0 && !send(streamHeartbeatEvent{}) {
				return
			}
			if err != nil {
				_ = send(streamHeartbeatEvent{err: err})
				return
			}
		}
	}()
	return events, stop
}

func resetStreamHeartbeatTimer(timer *time.Timer, timeout time.Duration) {
	if !timer.Stop() {
		select {
		case <-timer.C:
		default:
		}
	}
	timer.Reset(timeout)
}

func waitForStreamInterval(ctx context.Context, duration time.Duration) bool {
	if ctx.Err() != nil {
		return false
	}
	if duration <= 0 {
		return true
	}

	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
