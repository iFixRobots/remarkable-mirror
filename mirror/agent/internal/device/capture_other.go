//go:build !linux

package device

import (
	"runtime"
	"time"
)

func CaptureCapabilities() Capabilities {
	return Capabilities{
		Schema:     "rmmirror.capabilities/v1",
		CapturedAt: time.Now().UTC().Format(time.RFC3339Nano),
		Status:     "unsupported",
		Device: Device{
			Architecture: runtime.GOARCH,
		},
		Errors: []ObservationError{{Component: "platform", Code: "linux_required"}},
	}
}
