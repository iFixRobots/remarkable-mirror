//go:build linux

package transportwake

import (
	"net"
	"syscall"
	"time"
)

func wakeListenConfig(address string, keepAlive time.Duration) net.ListenConfig {
	config := net.ListenConfig{KeepAlive: keepAlive}
	host, _, err := net.SplitHostPort(address)
	if err != nil || host != directCableRecoveryListener.Addr().String() {
		return config
	}
	config.Control = func(_, _ string, connection syscall.RawConn) error {
		var socketError error
		if err := connection.Control(func(descriptor uintptr) {
			socketError = syscall.SetsockoptString(
				int(descriptor),
				syscall.SOL_SOCKET,
				syscall.SO_BINDTODEVICE,
				DefaultWakeUSBDevice,
			)
		}); err != nil {
			return err
		}
		return socketError
	}
	return config
}
