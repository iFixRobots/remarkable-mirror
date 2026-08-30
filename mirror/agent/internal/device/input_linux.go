//go:build linux

package device

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	uinputPath = "/dev/uinput"

	evSyn = 0x00
	evRep = 0x14

	synReport = 0

	absX              = 0x00
	absY              = 0x01
	absPressure       = 0x18
	absDistance       = 0x19
	absTiltX          = 0x1a
	absTiltY          = 0x1b
	absMTSlot         = 0x2f
	absMTPositionX    = 0x35
	absMTPositionY    = 0x36
	absMTTrackingID   = 0x39
	absMTPressure     = 0x3a
	btnToolPen        = 0x140
	btnToolRubber     = 0x141
	btnToolFinger     = 0x145
	btnTouch          = 0x14a
	btnStylus         = 0x14b
	btnStylus2        = 0x14c
	inputPropDirect   = 0x01
	busVirtual        = 0x06
	uinputMaxNameSize = 80
)

const (
	iocNRBits    = 8
	iocTypeBits  = 8
	iocSizeBits  = 14
	iocNRShift   = 0
	iocTypeShift = iocNRShift + iocNRBits
	iocSizeShift = iocTypeShift + iocTypeBits
	iocDirShift  = iocSizeShift + iocSizeBits
	iocWrite     = 1
)

type inputID struct {
	BusType uint16
	Vendor  uint16
	Product uint16
	Version uint16
}

type uinputSetup struct {
	ID           inputID
	Name         [uinputMaxNameSize]byte
	FFEffectsMax uint32
}

type uinputAbsInfo struct {
	Value      int32
	Minimum    int32
	Maximum    int32
	Fuzz       int32
	Flat       int32
	Resolution int32
}

type uinputAbsSetup struct {
	Code    uint16
	Padding uint16
	AbsInfo uinputAbsInfo
}

type absoluteAxis struct {
	code       int
	minimum    int
	maximum    int
	resolution int
}

type emittedEvent struct {
	typeCode uint16
	code     uint16
	value    int32
}

type uinputDevice struct {
	file      *os.File
	destroyed bool
	writeMu   sync.Mutex
}

type linuxInputBackend struct {
	touch    *uinputDevice
	pen      *uinputDevice
	keyboard *uinputDevice

	touchDown  bool
	penDown    bool
	penTool    int
	trackingID int
	heldKeys   map[int]bool
}

func newInputBackend() (inputBackend, error) {
	touch, err := createUinputDevice(
		"reMarkable Mirror Touch",
		2,
		[]int{btnTouch, btnToolFinger},
		[]absoluteAxis{
			{code: absX, maximum: touchXMax},
			{code: absY, maximum: touchYMax},
			{code: absMTSlot, maximum: 9},
			{code: absMTTrackingID, maximum: 65535},
			{code: absMTPositionX, maximum: touchXMax},
			{code: absMTPositionY, maximum: touchYMax},
			{code: absMTPressure, maximum: 255},
		},
		true,
		false,
	)
	if err != nil {
		return nil, err
	}
	pen, err := createUinputDevice(
		"reMarkable Mirror Pen",
		3,
		[]int{btnToolPen, btnToolRubber, btnTouch, btnStylus, btnStylus2},
		[]absoluteAxis{
			{code: absX, maximum: penXMax, resolution: 2208},
			{code: absY, maximum: penYMax, resolution: 1248},
			{code: absPressure, maximum: 4096},
			{code: absDistance, maximum: 65535},
			{code: absTiltX, minimum: -9000, maximum: 9000},
			{code: absTiltY, minimum: -9000, maximum: 9000},
		},
		false,
		false,
	)
	if err != nil {
		_ = touch.Close()
		return nil, err
	}
	keyboard, err := createUinputDevice(
		"reMarkable Mirror Keyboard",
		4,
		supportedKeyCodes(),
		nil,
		false,
		true,
	)
	if err != nil {
		_ = pen.Close()
		_ = touch.Close()
		return nil, err
	}

	// uinput creation returns before userspace input consumers finish discovering
	// the new event devices. Keep the ready handshake behind a short settle time.
	time.Sleep(350 * time.Millisecond)
	return &linuxInputBackend{
		touch: touch, pen: pen, keyboard: keyboard,
		trackingID: 1, heldKeys: make(map[int]bool),
	}, nil
}

func createUinputDevice(
	name string,
	product uint16,
	keys []int,
	axes []absoluteAxis,
	direct bool,
	repeat bool,
) (*uinputDevice, error) {
	file, err := os.OpenFile(uinputPath, os.O_WRONLY, 0)
	if err != nil {
		return nil, codedError{code: "uinput_open_failed"}
	}
	device := &uinputDevice{file: file}
	fail := func(code string) (*uinputDevice, error) {
		_ = file.Close()
		return nil, codedError{code: code}
	}

	if err := ioctlValue(file.Fd(), uiSetEVBit(), evKey); err != nil {
		return fail("uinput_capability_failed")
	}
	for _, code := range keys {
		if err := ioctlValue(file.Fd(), uiSetKeyBit(), code); err != nil {
			return fail("uinput_capability_failed")
		}
	}
	if len(axes) > 0 {
		if err := ioctlValue(file.Fd(), uiSetEVBit(), evAbs); err != nil {
			return fail("uinput_capability_failed")
		}
		for _, axis := range axes {
			if err := ioctlValue(file.Fd(), uiSetAbsBit(), axis.code); err != nil {
				return fail("uinput_capability_failed")
			}
			setup := uinputAbsSetup{
				Code: uint16(axis.code),
				AbsInfo: uinputAbsInfo{
					Minimum: int32(axis.minimum), Maximum: int32(axis.maximum), Resolution: int32(axis.resolution),
				},
			}
			if err := ioctlPointer(file.Fd(), uiAbsSetup(), unsafe.Pointer(&setup)); err != nil {
				return fail("uinput_axis_setup_failed")
			}
			runtime.KeepAlive(&setup)
		}
	}
	if direct {
		if err := ioctlValue(file.Fd(), uiSetPropBit(), inputPropDirect); err != nil {
			return fail("uinput_capability_failed")
		}
	}
	if repeat {
		if err := ioctlValue(file.Fd(), uiSetEVBit(), evRep); err != nil {
			return fail("uinput_capability_failed")
		}
	}

	setup := uinputSetup{ID: inputID{BusType: busVirtual, Vendor: 0x524d, Product: product, Version: 1}}
	copy(setup.Name[:], name)
	if err := ioctlPointer(file.Fd(), uiDevSetup(), unsafe.Pointer(&setup)); err != nil {
		return fail("uinput_device_setup_failed")
	}
	runtime.KeepAlive(&setup)
	if err := ioctlValue(file.Fd(), uiDevCreate(), 0); err != nil {
		return fail("uinput_device_create_failed")
	}
	return device, nil
}

func (backend *linuxInputBackend) Touch(action string, x, y, pressure int) error {
	switch action {
	case "down":
		if backend.touchDown {
			return fmt.Errorf("touch_already_down")
		}
		trackingID := backend.trackingID
		backend.trackingID++
		if backend.trackingID > 65535 {
			backend.trackingID = 1
		}
		if err := backend.touch.Emit(
			event(evAbs, absMTSlot, 0),
			event(evAbs, absMTTrackingID, trackingID),
			event(evAbs, absMTPositionX, x), event(evAbs, absMTPositionY, y),
			event(evAbs, absMTPressure, pressure),
			event(evAbs, absX, x), event(evAbs, absY, y),
			event(evKey, btnToolFinger, 1), event(evKey, btnTouch, 1), syncEvent(),
		); err != nil {
			return err
		}
		backend.touchDown = true
		return nil

	case "move":
		if !backend.touchDown {
			return fmt.Errorf("touch_not_down")
		}
		return backend.touch.Emit(
			event(evAbs, absMTSlot, 0),
			event(evAbs, absMTPositionX, x), event(evAbs, absMTPositionY, y),
			event(evAbs, absMTPressure, pressure),
			event(evAbs, absX, x), event(evAbs, absY, y), syncEvent(),
		)

	case "up":
		if !backend.touchDown {
			return nil
		}
		if err := backend.touch.Emit(
			event(evAbs, absMTSlot, 0), event(evAbs, absMTPressure, 0),
			event(evAbs, absMTTrackingID, -1),
			event(evKey, btnTouch, 0), event(evKey, btnToolFinger, 0), syncEvent(),
		); err != nil {
			return err
		}
		backend.touchDown = false
		return nil
	}
	return fmt.Errorf("invalid_action")
}

func (backend *linuxInputBackend) Pen(action string, x, y, pressure int, tool string) error {
	switch action {
	case "down":
		if backend.penDown {
			return fmt.Errorf("pen_already_down")
		}
		toolKey := btnToolPen
		if tool == "eraser" {
			toolKey = btnToolRubber
		}
		if err := backend.pen.Emit(
			event(evAbs, absX, x), event(evAbs, absY, y),
			event(evAbs, absDistance, 0), event(evAbs, absPressure, pressure),
			event(evKey, toolKey, 1), event(evKey, btnTouch, 1), syncEvent(),
		); err != nil {
			return err
		}
		backend.penDown = true
		backend.penTool = toolKey
		return nil

	case "move":
		if !backend.penDown {
			return fmt.Errorf("pen_not_down")
		}
		if tool != "" && ((tool == "eraser") != (backend.penTool == btnToolRubber)) {
			return fmt.Errorf("pen_tool_changed")
		}
		return backend.pen.Emit(
			event(evAbs, absX, x), event(evAbs, absY, y),
			event(evAbs, absDistance, 0), event(evAbs, absPressure, pressure), syncEvent(),
		)

	case "up":
		if !backend.penDown {
			return nil
		}
		if err := backend.pen.Emit(
			event(evAbs, absPressure, 0), event(evKey, btnTouch, 0),
			event(evAbs, absDistance, 65535), event(evKey, backend.penTool, 0), syncEvent(),
		); err != nil {
			return err
		}
		backend.penDown = false
		backend.penTool = 0
		return nil
	}
	return fmt.Errorf("invalid_action")
}

func (backend *linuxInputBackend) Key(action string, code int) error {
	value := 0
	if action == "down" {
		value = 1
		if backend.heldKeys[code] {
			value = 2
		}
	}
	if err := backend.keyboard.Emit(event(evKey, code, value), syncEvent()); err != nil {
		return err
	}
	if action == "down" {
		backend.heldKeys[code] = true
	} else {
		delete(backend.heldKeys, code)
	}
	return nil
}

func (backend *linuxInputBackend) Reset() error {
	var result error
	if err := backend.Touch("up", 0, 0, 0); err != nil {
		result = err
	}
	if err := backend.Pen("up", 0, 0, 0, ""); err != nil && result == nil {
		result = err
	}
	for code := range backend.heldKeys {
		if err := backend.Key("up", code); err != nil && result == nil {
			result = err
		}
	}
	return result
}

func (backend *linuxInputBackend) Close() error {
	resetErr := backend.Reset()
	// Let the final release reports reach input consumers before removing the
	// devices. Device removal is still the fallback if the SSH process dies.
	time.Sleep(20 * time.Millisecond)
	var closeErr error
	for _, device := range []*uinputDevice{backend.keyboard, backend.pen, backend.touch} {
		if err := device.Close(); err != nil && closeErr == nil {
			closeErr = err
		}
	}
	if resetErr != nil {
		return resetErr
	}
	return closeErr
}

func (device *uinputDevice) Emit(events ...emittedEvent) error {
	buffer := make([]byte, len(events)*inputEventBytes)
	now := time.Now()
	seconds := uint64(now.Unix())
	microseconds := uint64(now.Nanosecond() / 1000)
	for index, emitted := range events {
		offset := index * inputEventBytes
		binary.LittleEndian.PutUint64(buffer[offset:], seconds)
		binary.LittleEndian.PutUint64(buffer[offset+8:], microseconds)
		binary.LittleEndian.PutUint16(buffer[offset+16:], emitted.typeCode)
		binary.LittleEndian.PutUint16(buffer[offset+18:], emitted.code)
		binary.LittleEndian.PutUint32(buffer[offset+20:], uint32(emitted.value))
	}
	return device.writePacket(buffer)
}

func (device *uinputDevice) EmitRawFrame(frame []byte) error {
	if len(frame) == 0 || len(frame)%inputEventBytes != 0 {
		return errors.New("invalid raw input frame")
	}
	return device.writePacket(frame)
}

func (device *uinputDevice) writePacket(packet []byte) error {
	if device == nil {
		return errors.New("uinput device is closed")
	}
	device.writeMu.Lock()
	defer device.writeMu.Unlock()
	if device.file == nil || device.destroyed {
		return errors.New("uinput device is closed")
	}
	written, err := device.file.Write(packet)
	if err != nil {
		return fmt.Errorf("uinput_write: %w", err)
	}
	if written != len(packet) {
		return fmt.Errorf("uinput_write: %w", io.ErrShortWrite)
	}
	return nil
}

func (device *uinputDevice) Close() error {
	if device == nil {
		return nil
	}
	device.writeMu.Lock()
	defer device.writeMu.Unlock()
	if device.file == nil || device.destroyed {
		return nil
	}
	device.destroyed = true
	destroyErr := ioctlValue(device.file.Fd(), uiDevDestroy(), 0)
	closeErr := device.file.Close()
	if destroyErr != nil {
		return destroyErr
	}
	return closeErr
}

func event(eventType, code, value int) emittedEvent {
	return emittedEvent{typeCode: uint16(eventType), code: uint16(code), value: int32(value)}
}

func syncEvent() emittedEvent {
	return event(evSyn, synReport, 0)
}

func ioctlRequest(direction, eventType, number, size uintptr) uintptr {
	return direction<<iocDirShift | eventType<<iocTypeShift | number<<iocNRShift | size<<iocSizeShift
}

func ioctlWrite(eventType, number, size uintptr) uintptr {
	return ioctlRequest(iocWrite, eventType, number, size)
}

func uiDevCreate() uintptr  { return ioctlRequest(0, 'U', 1, 0) }
func uiDevDestroy() uintptr { return ioctlRequest(0, 'U', 2, 0) }
func uiDevSetup() uintptr   { return ioctlWrite('U', 3, unsafe.Sizeof(uinputSetup{})) }
func uiAbsSetup() uintptr   { return ioctlWrite('U', 4, unsafe.Sizeof(uinputAbsSetup{})) }
func uiSetEVBit() uintptr   { return ioctlWrite('U', 100, unsafe.Sizeof(int32(0))) }
func uiSetKeyBit() uintptr  { return ioctlWrite('U', 101, unsafe.Sizeof(int32(0))) }
func uiSetAbsBit() uintptr  { return ioctlWrite('U', 103, unsafe.Sizeof(int32(0))) }
func uiSetPropBit() uintptr { return ioctlWrite('U', 110, unsafe.Sizeof(int32(0))) }

func ioctlValue(fd uintptr, request uintptr, value int) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, request, uintptr(value))
	if errno != 0 {
		return errno
	}
	return nil
}

func ioctlPointer(fd uintptr, request uintptr, pointer unsafe.Pointer) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, request, uintptr(pointer))
	if errno != 0 {
		return errno
	}
	return nil
}
