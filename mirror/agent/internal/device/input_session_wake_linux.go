//go:build linux

package device

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	inputSessionWakeLockPath    = "/sys/power/wake_lock"
	inputSessionWakeUnlockPath  = "/sys/power/wake_unlock"
	inputSessionWakeLockPrefix  = "rmmirror-input-"
	inputSessionWakeRenewEvery  = 20 * time.Second
	inputSessionWakeLockTimeout = 60 * time.Second
)

type inputSessionWakeWriter func(path string, value []byte) error

type inputSessionWakeTicker interface {
	Chan() <-chan time.Time
	Stop()
}

type inputSessionWakeTickerFactory func(time.Duration) inputSessionWakeTicker

type systemInputSessionWakeTicker struct {
	ticker *time.Ticker
}

func (ticker *systemInputSessionWakeTicker) Chan() <-chan time.Time {
	return ticker.ticker.C
}

func (ticker *systemInputSessionWakeTicker) Stop() {
	ticker.ticker.Stop()
}

func newSystemInputSessionWakeTicker(interval time.Duration) inputSessionWakeTicker {
	return &systemInputSessionWakeTicker{ticker: time.NewTicker(interval)}
}

type inputSessionWakeLock struct {
	write         inputSessionWakeWriter
	name          string
	renewEvery    time.Duration
	lockTimeout   time.Duration
	stop          chan struct{}
	done          chan struct{}
	failed        chan struct{}
	stopOnce      sync.Once
	failOnce      sync.Once
	lastRenewalMu sync.Mutex
	lastRenewal   error
}

func acquireInputSessionWakeLock() (*inputSessionWakeLock, error) {
	return acquireInputSessionWakeLockWith(
		writeInputSessionWakeValue,
		fmt.Sprintf("%s%d", inputSessionWakeLockPrefix, os.Getpid()),
		inputSessionWakeRenewEvery,
		inputSessionWakeLockTimeout,
	)
}

func acquireInputSessionWakeLockWith(
	write inputSessionWakeWriter,
	name string,
	renewEvery time.Duration,
	lockTimeout time.Duration,
) (*inputSessionWakeLock, error) {
	return acquireInputSessionWakeLockWithTicker(
		write,
		name,
		renewEvery,
		lockTimeout,
		newSystemInputSessionWakeTicker,
	)
}

func acquireInputSessionWakeLockWithTicker(
	write inputSessionWakeWriter,
	name string,
	renewEvery time.Duration,
	lockTimeout time.Duration,
	newTicker inputSessionWakeTickerFactory,
) (*inputSessionWakeLock, error) {
	if write == nil || name == "" || strings.ContainsAny(name, " \t\r\n") ||
		renewEvery <= 0 || lockTimeout <= renewEvery || newTicker == nil {
		return nil, codedError{code: "input_wake_lock_invalid"}
	}
	lease := &inputSessionWakeLock{
		write:       write,
		name:        name,
		renewEvery:  renewEvery,
		lockTimeout: lockTimeout,
		stop:        make(chan struct{}),
		done:        make(chan struct{}),
		failed:      make(chan struct{}),
	}
	if err := lease.renew(); err != nil {
		return nil, codedError{code: "input_wake_lock_failed"}
	}
	go lease.run(newTicker(renewEvery))
	return lease, nil
}

func (lease *inputSessionWakeLock) run(ticker inputSessionWakeTicker) {
	defer close(lease.done)
	defer ticker.Stop()
	for {
		select {
		case <-lease.stop:
			return
		case <-ticker.Chan():
			err := lease.renew()
			lease.lastRenewalMu.Lock()
			lease.lastRenewal = err
			lease.lastRenewalMu.Unlock()
			if err != nil {
				lease.failOnce.Do(func() { close(lease.failed) })
				return
			}
		}
	}
}

func (lease *inputSessionWakeLock) Failed() <-chan struct{} {
	return lease.failed
}

func (lease *inputSessionWakeLock) Err() error {
	if lease == nil {
		return nil
	}
	lease.lastRenewalMu.Lock()
	defer lease.lastRenewalMu.Unlock()
	if lease.lastRenewal != nil {
		return codedError{code: "input_wake_lock_failed"}
	}
	return nil
}

func (lease *inputSessionWakeLock) renew() error {
	timeout := strconv.FormatInt(lease.lockTimeout.Nanoseconds(), 10)
	value := []byte(lease.name + " " + timeout + "\n")
	return lease.write(inputSessionWakeLockPath, value)
}

func (lease *inputSessionWakeLock) Close() error {
	if lease == nil {
		return nil
	}
	lease.stopOnce.Do(func() { close(lease.stop) })
	<-lease.done

	renewErr := lease.Err()
	releaseErr := lease.write(
		inputSessionWakeUnlockPath,
		[]byte(lease.name+"\n"),
	)
	if releaseErr != nil {
		return codedError{code: "input_wake_unlock_failed"}
	}
	return renewErr
}

func writeInputSessionWakeValue(path string, value []byte) error {
	file, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	written, writeErr := file.Write(value)
	if writeErr == nil && written != len(value) {
		writeErr = io.ErrShortWrite
	}
	return errors.Join(writeErr, file.Close())
}
