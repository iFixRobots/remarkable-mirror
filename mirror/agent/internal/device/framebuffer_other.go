//go:build !linux

package device

import "io"

func WriteVisibleFrame(writer io.Writer, format string) error {
	return codedError{code: "linux_required"}
}
