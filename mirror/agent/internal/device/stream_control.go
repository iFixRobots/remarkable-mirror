package device

import (
	"context"
	"time"
)

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
