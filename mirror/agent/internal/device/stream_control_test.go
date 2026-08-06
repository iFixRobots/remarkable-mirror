package device

import (
	"context"
	"io"
	"testing"
	"time"
)

func TestRunFrameStreamLeaseKeepsStaticStreamAliveWithPulses(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	heartbeatReader, heartbeatWriter := io.Pipe()
	defer heartbeatReader.Close()
	defer heartbeatWriter.Close()

	streamStarted := make(chan struct{})
	streamCanceled := make(chan struct{})
	result := make(chan error, 1)
	go func() {
		result <- runFrameStreamLease(
			ctx,
			heartbeatReader,
			400*time.Millisecond,
			func(streamContext context.Context) error {
				close(streamStarted)
				<-streamContext.Done()
				close(streamCanceled)
				return nil
			},
		)
	}()

	<-streamStarted
	time.Sleep(200 * time.Millisecond)
	if _, err := heartbeatWriter.Write([]byte{'\n'}); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}

	select {
	case err := <-result:
		t.Fatalf("static stream ended after a heartbeat: %v", err)
	case <-time.After(250 * time.Millisecond):
	}

	cancel()
	if err := waitForFrameStreamLeaseResult(t, result); err != nil {
		t.Fatalf("runFrameStreamLease returned %v", err)
	}
	waitForFrameStreamCancellation(t, streamCanceled)
}

func TestRunFrameStreamLeaseExpiresWithoutHeartbeat(t *testing.T) {
	heartbeatReader, heartbeatWriter := io.Pipe()
	defer heartbeatReader.Close()
	defer heartbeatWriter.Close()

	streamCanceled := make(chan struct{})
	result := make(chan error, 1)
	go func() {
		result <- runFrameStreamLease(
			context.Background(),
			heartbeatReader,
			25*time.Millisecond,
			func(streamContext context.Context) error {
				<-streamContext.Done()
				close(streamCanceled)
				return nil
			},
		)
	}()

	if err := waitForFrameStreamLeaseResult(t, result); ErrorCode(err) != "heartbeat_timeout" {
		t.Fatalf("ErrorCode(%v) = %q, want heartbeat_timeout", err, ErrorCode(err))
	}
	waitForFrameStreamCancellation(t, streamCanceled)
}

func TestRunFrameStreamLeaseDoesNotWaitForBlockedStream(t *testing.T) {
	heartbeatReader, heartbeatWriter := io.Pipe()
	defer heartbeatReader.Close()
	defer heartbeatWriter.Close()

	streamStarted := make(chan struct{})
	releaseStream := make(chan struct{})
	defer close(releaseStream)
	result := make(chan error, 1)
	go func() {
		result <- runFrameStreamLease(
			context.Background(),
			heartbeatReader,
			25*time.Millisecond,
			func(context.Context) error {
				close(streamStarted)
				<-releaseStream
				return nil
			},
		)
	}()

	<-streamStarted
	if err := waitForFrameStreamLeaseResult(t, result); ErrorCode(err) != "heartbeat_timeout" {
		t.Fatalf("ErrorCode(%v) = %q, want heartbeat_timeout", err, ErrorCode(err))
	}
}

func TestRunFrameStreamLeaseStopsOnEOF(t *testing.T) {
	heartbeatReader, heartbeatWriter := io.Pipe()
	defer heartbeatReader.Close()

	streamCanceled := make(chan struct{})
	result := make(chan error, 1)
	go func() {
		result <- runFrameStreamLease(
			context.Background(),
			heartbeatReader,
			0,
			func(streamContext context.Context) error {
				<-streamContext.Done()
				close(streamCanceled)
				return nil
			},
		)
	}()

	if err := heartbeatWriter.Close(); err != nil {
		t.Fatalf("close heartbeat writer: %v", err)
	}
	if err := waitForFrameStreamLeaseResult(t, result); err != nil {
		t.Fatalf("runFrameStreamLease returned %v", err)
	}
	waitForFrameStreamCancellation(t, streamCanceled)
}

func TestRunFrameStreamLeaseStopsOnParentCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	heartbeatReader, heartbeatWriter := io.Pipe()
	defer heartbeatReader.Close()
	defer heartbeatWriter.Close()

	streamStarted := make(chan struct{})
	streamCanceled := make(chan struct{})
	result := make(chan error, 1)
	go func() {
		result <- runFrameStreamLease(
			ctx,
			heartbeatReader,
			0,
			func(streamContext context.Context) error {
				close(streamStarted)
				<-streamContext.Done()
				close(streamCanceled)
				return nil
			},
		)
	}()

	<-streamStarted
	cancel()
	if err := waitForFrameStreamLeaseResult(t, result); err != nil {
		t.Fatalf("runFrameStreamLease returned %v", err)
	}
	waitForFrameStreamCancellation(t, streamCanceled)
}

func TestStreamFramesWithLeaseRejectsInvalidHeartbeatTimeout(t *testing.T) {
	err := StreamFramesWithLease(
		context.Background(),
		nil,
		io.Discard,
		40*time.Millisecond,
		time.Second,
	)
	if ErrorCode(err) != "invalid_heartbeat_timeout" {
		t.Fatalf("ErrorCode(%v) = %q, want invalid_heartbeat_timeout", err, ErrorCode(err))
	}
}

func TestWaitForStreamIntervalStopsOnCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan bool, 1)
	go func() {
		result <- waitForStreamInterval(ctx, 10*time.Second)
	}()

	cancel()
	select {
	case continued := <-result:
		if continued {
			t.Fatal("stream interval continued after cancellation")
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("stream interval did not stop promptly after cancellation")
	}
}

func TestWaitForStreamIntervalChecksCanceledContextWithoutDelay(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if waitForStreamInterval(ctx, 0) {
		t.Fatal("canceled stream continued with no remaining interval")
	}
}

func waitForFrameStreamLeaseResult(t *testing.T, result <-chan error) error {
	t.Helper()
	select {
	case err := <-result:
		return err
	case <-time.After(time.Second):
		t.Fatal("frame stream lease did not finish promptly")
		return nil
	}
}

func waitForFrameStreamCancellation(t *testing.T, canceled <-chan struct{}) {
	t.Helper()
	select {
	case <-canceled:
	case <-time.After(time.Second):
		t.Fatal("frame stream worker did not observe cancellation")
	}
}
