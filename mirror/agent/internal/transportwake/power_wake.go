package transportwake

import (
	"context"
	"errors"
	"time"
)

const (
	wakeEventSyn  = 0x00
	wakeEventKey  = 0x01
	wakeSynReport = 0x00
	wakeKeyPower  = 0x74
)

type wakeInputEvent struct {
	Type  uint16
	Code  uint16
	Value int32
}

type powerDevice interface {
	WriteEvents([]wakeInputEvent) error
	Destroy() error
}

type powerDeviceFactory interface {
	Create() (powerDevice, error)
}

type transientPowerWaker struct {
	factory       powerDeviceFactory
	discoveryWait time.Duration
	deliveryWait  time.Duration
}

func newTransientPowerWaker(
	factory powerDeviceFactory,
	discoveryWait time.Duration,
	deliveryWait time.Duration,
) *transientPowerWaker {
	return &transientPowerWaker{
		factory:       factory,
		discoveryWait: discoveryWait,
		deliveryWait:  deliveryWait,
	}
}

func (waker *transientPowerWaker) Wake(ctx context.Context) (resultErr error) {
	device, err := waker.factory.Create()
	if err != nil {
		return err
	}
	defer func() {
		resultErr = errors.Join(resultErr, device.Destroy())
	}()

	if err := waitForContext(ctx, waker.discoveryWait); err != nil {
		return err
	}
	events := []wakeInputEvent{
		{Type: wakeEventKey, Code: wakeKeyPower, Value: 1},
		{Type: wakeEventSyn, Code: wakeSynReport, Value: 0},
		{Type: wakeEventKey, Code: wakeKeyPower, Value: 0},
		{Type: wakeEventSyn, Code: wakeSynReport, Value: 0},
	}
	if err := device.WriteEvents(events); err != nil {
		return err
	}
	return waitForContext(ctx, waker.deliveryWait)
}

func waitForContext(ctx context.Context, duration time.Duration) error {
	if duration <= 0 {
		return nil
	}
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
