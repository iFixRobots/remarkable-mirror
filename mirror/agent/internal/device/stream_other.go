//go:build !linux

package device

import (
	"context"
	"io"
	"time"
)

func StreamFrames(ctx context.Context, writer io.Writer, interval time.Duration) error {
	return codedError{code: "linux_required"}
}
