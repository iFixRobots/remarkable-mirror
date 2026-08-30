//go:build !linux

package transportwake

import "errors"

type unsupportedPowerDeviceFactory struct{}

func newPowerDeviceFactory() powerDeviceFactory {
	return unsupportedPowerDeviceFactory{}
}

func (unsupportedPowerDeviceFactory) Create() (powerDevice, error) {
	return nil, errors.New("transient wake input is available only on Linux")
}
