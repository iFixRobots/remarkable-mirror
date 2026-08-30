//go:build !linux

package transportwake

import (
	"net"
	"time"
)

func wakeListenConfig(_ string, keepAlive time.Duration) net.ListenConfig {
	return net.ListenConfig{KeepAlive: keepAlive}
}
