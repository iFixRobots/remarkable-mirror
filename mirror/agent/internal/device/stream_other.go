//go:build !linux

package device

import (
	"io"
	"time"
)

func StreamFrames(writer io.Writer, interval time.Duration) error {
	return codedError{code: "linux_required"}
}
