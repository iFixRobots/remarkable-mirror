//go:build !linux

package device

import "context"

func StartXoviActivation(_ context.Context, attempt string) (XoviActivationStatus, error) {
	if err := validateXoviAttempt(attempt); err != nil {
		return XoviActivationStatus{}, err
	}
	return XoviActivationStatus{}, codedError{code: "linux_required"}
}

func ReadXoviActivationStatus() (XoviActivationStatus, error) {
	return XoviActivationStatus{}, codedError{code: "linux_required"}
}
