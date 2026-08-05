package device

import (
	"context"
	"testing"
	"time"
)

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
