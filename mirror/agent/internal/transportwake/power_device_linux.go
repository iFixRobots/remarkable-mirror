//go:build linux

package transportwake

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"runtime"
	"syscall"
	"time"
	"unsafe"
)

const (
	wakeUinputPath        = "/dev/uinput"
	wakeBusVirtual        = 0x06
	wakeUinputMaxNameSize = 80
	wakeInputEventBytes   = 24

	wakeIOCNRBits    = 8
	wakeIOCTypeBits  = 8
	wakeIOCSizeBits  = 14
	wakeIOCNRShift   = 0
	wakeIOCTypeShift = wakeIOCNRShift + wakeIOCNRBits
	wakeIOCSizeShift = wakeIOCTypeShift + wakeIOCTypeBits
	wakeIOCDirShift  = wakeIOCSizeShift + wakeIOCSizeBits
	wakeIOCWrite     = 1
)

type wakeInputID struct {
	BusType uint16
	Vendor  uint16
	Product uint16
	Version uint16
}

type wakeUinputSetup struct {
	ID           wakeInputID
	Name         [wakeUinputMaxNameSize]byte
	FFEffectsMax uint32
}

type linuxPowerDeviceFactory struct{}

type linuxPowerDevice struct {
	file      *os.File
	destroyed bool
}

func newPowerDeviceFactory() powerDeviceFactory {
	return linuxPowerDeviceFactory{}
}

func (linuxPowerDeviceFactory) Create() (powerDevice, error) {
	file, err := os.OpenFile(wakeUinputPath, os.O_WRONLY, 0)
	if err != nil {
		return nil, fmt.Errorf("open transient wake device: %w", err)
	}
	fail := func(operationErr error) (powerDevice, error) {
		return nil, errors.Join(operationErr, file.Close())
	}
	if err := wakeIoctlValue(file.Fd(), wakeUISetEVBit(), wakeEventKey); err != nil {
		return fail(fmt.Errorf("configure transient wake device event type: %w", err))
	}
	if err := wakeIoctlValue(file.Fd(), wakeUISetKeyBit(), wakeKeyPower); err != nil {
		return fail(fmt.Errorf("configure transient wake device power key: %w", err))
	}
	setup := wakeUinputSetup{
		ID: wakeInputID{
			BusType: wakeBusVirtual,
			Vendor:  0x524d,
			Product: 5,
			Version: 1,
		},
	}
	copy(setup.Name[:], "reMarkable Mirror Wake")
	if err := wakeIoctlPointer(file.Fd(), wakeUIDevSetup(), unsafe.Pointer(&setup)); err != nil {
		return fail(fmt.Errorf("set up transient wake device: %w", err))
	}
	runtime.KeepAlive(&setup)
	if err := wakeIoctlValue(file.Fd(), wakeUIDevCreate(), 0); err != nil {
		return fail(fmt.Errorf("create transient wake device: %w", err))
	}
	return &linuxPowerDevice{file: file}, nil
}

func (device *linuxPowerDevice) WriteEvents(events []wakeInputEvent) error {
	if device == nil || device.file == nil || device.destroyed {
		return errors.New("transient wake device is closed")
	}
	packet := make([]byte, len(events)*wakeInputEventBytes)
	now := time.Now()
	seconds := uint64(now.Unix())
	microseconds := uint64(now.Nanosecond() / 1000)
	for index, event := range events {
		offset := index * wakeInputEventBytes
		binary.LittleEndian.PutUint64(packet[offset:], seconds)
		binary.LittleEndian.PutUint64(packet[offset+8:], microseconds)
		binary.LittleEndian.PutUint16(packet[offset+16:], event.Type)
		binary.LittleEndian.PutUint16(packet[offset+18:], event.Code)
		binary.LittleEndian.PutUint32(packet[offset+20:], uint32(event.Value))
	}
	written, err := device.file.Write(packet)
	if err != nil {
		return fmt.Errorf("write transient wake click: %w", err)
	}
	if written != len(packet) {
		return fmt.Errorf("write transient wake click: %w", io.ErrShortWrite)
	}
	return nil
}

func (device *linuxPowerDevice) Destroy() error {
	if device == nil || device.file == nil || device.destroyed {
		return nil
	}
	device.destroyed = true
	destroyErr := wakeIoctlValue(device.file.Fd(), wakeUIDevDestroy(), 0)
	closeErr := device.file.Close()
	return errors.Join(destroyErr, closeErr)
}

func wakeIoctlRequest(direction, eventType, number, size uintptr) uintptr {
	return direction<<wakeIOCDirShift |
		eventType<<wakeIOCTypeShift |
		number<<wakeIOCNRShift |
		size<<wakeIOCSizeShift
}

func wakeIoctlWrite(eventType, number, size uintptr) uintptr {
	return wakeIoctlRequest(wakeIOCWrite, eventType, number, size)
}

func wakeUIDevCreate() uintptr {
	return wakeIoctlRequest(0, 'U', 1, 0)
}

func wakeUIDevDestroy() uintptr {
	return wakeIoctlRequest(0, 'U', 2, 0)
}

func wakeUIDevSetup() uintptr {
	return wakeIoctlWrite('U', 3, unsafe.Sizeof(wakeUinputSetup{}))
}

func wakeUISetEVBit() uintptr {
	return wakeIoctlWrite('U', 100, unsafe.Sizeof(int32(0)))
}

func wakeUISetKeyBit() uintptr {
	return wakeIoctlWrite('U', 101, unsafe.Sizeof(int32(0)))
}

func wakeIoctlValue(fd, request uintptr, value int) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, request, uintptr(value))
	if errno != 0 {
		return errno
	}
	return nil
}

func wakeIoctlPointer(fd, request uintptr, pointer unsafe.Pointer) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, request, uintptr(pointer))
	if errno != 0 {
		return errno
	}
	return nil
}
