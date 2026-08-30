//go:build !linux

package device

import (
	"context"
	"io"
	"time"
)

func newInputBackend() (inputBackend, error) {
	return nil, codedError{code: "linux_required"}
}

func serveManagedInput(context.Context, string, time.Duration, bool, io.Reader, io.Writer) error {
	return codedError{code: "linux_required"}
}

func RunInputWatchdog(string, string, bool) error {
	return codedError{code: "linux_required"}
}

func WaitForPhysicalInputRestored(string, time.Duration) error {
	return codedError{code: "linux_required"}
}
