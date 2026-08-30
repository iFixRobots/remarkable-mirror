package transportwake

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"
)

type fakePowerDeviceFactory struct {
	device *fakePowerDevice
	err    error
	calls  int
}

func (factory *fakePowerDeviceFactory) Create() (powerDevice, error) {
	factory.calls++
	if factory.err != nil {
		return nil, factory.err
	}
	return factory.device, nil
}

type fakePowerDevice struct {
	writes       [][]wakeInputEvent
	writeErr     error
	destroyErr   error
	destroyCalls int
}

func (device *fakePowerDevice) WriteEvents(events []wakeInputEvent) error {
	device.writes = append(device.writes, append([]wakeInputEvent(nil), events...))
	return device.writeErr
}

func (device *fakePowerDevice) Destroy() error {
	device.destroyCalls++
	return device.destroyErr
}

func TestTransientPowerWakerWritesOneCompleteClickThenDestroysDevice(t *testing.T) {
	device := &fakePowerDevice{}
	factory := &fakePowerDeviceFactory{device: device}
	waker := newTransientPowerWaker(factory, 0, 0)

	if err := waker.Wake(context.Background()); err != nil {
		t.Fatalf("Wake returned %v", err)
	}
	wantEvents := []wakeInputEvent{
		{Type: wakeEventKey, Code: wakeKeyPower, Value: 1},
		{Type: wakeEventSyn, Code: wakeSynReport, Value: 0},
		{Type: wakeEventKey, Code: wakeKeyPower, Value: 0},
		{Type: wakeEventSyn, Code: wakeSynReport, Value: 0},
	}
	if factory.calls != 1 {
		t.Fatalf("device creations = %d, want 1", factory.calls)
	}
	if len(device.writes) != 1 || !reflect.DeepEqual(device.writes[0], wantEvents) {
		t.Fatalf("device writes = %#v, want one %#v", device.writes, wantEvents)
	}
	if device.destroyCalls != 1 {
		t.Fatalf("device destroys = %d, want 1", device.destroyCalls)
	}
}

func TestTransientPowerWakerDestroysDeviceWhenWriteFails(t *testing.T) {
	device := &fakePowerDevice{writeErr: errors.New("write failed")}
	waker := newTransientPowerWaker(&fakePowerDeviceFactory{device: device}, 0, 0)

	if err := waker.Wake(context.Background()); err == nil {
		t.Fatal("Wake succeeded after a failed click write")
	}
	if len(device.writes) != 1 || device.destroyCalls != 1 {
		t.Fatalf("writes = %d, destroys = %d", len(device.writes), device.destroyCalls)
	}
}

func TestTransientPowerWakerDoesNotWriteAfterCancellation(t *testing.T) {
	device := &fakePowerDevice{}
	waker := newTransientPowerWaker(&fakePowerDeviceFactory{device: device}, time.Hour, 0)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if err := waker.Wake(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("Wake returned %v, want context cancellation", err)
	}
	if len(device.writes) != 0 || device.destroyCalls != 1 {
		t.Fatalf("writes = %d, destroys = %d", len(device.writes), device.destroyCalls)
	}
}
