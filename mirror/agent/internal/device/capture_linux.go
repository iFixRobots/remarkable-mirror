//go:build linux

package device

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	evKey = 0x01
	evAbs = 0x03
)

var eventTypeNames = map[int]string{
	0x00: "EV_SYN",
	0x01: "EV_KEY",
	0x02: "EV_REL",
	0x03: "EV_ABS",
	0x04: "EV_MSC",
	0x05: "EV_SW",
	0x11: "EV_LED",
	0x12: "EV_SND",
	0x14: "EV_REP",
	0x15: "EV_FF",
	0x16: "EV_PWR",
}

var axisNames = map[int]string{
	0x00: "ABS_X",
	0x01: "ABS_Y",
	0x18: "ABS_PRESSURE",
	0x19: "ABS_DISTANCE",
	0x1a: "ABS_TILT_X",
	0x1b: "ABS_TILT_Y",
	0x2f: "ABS_MT_SLOT",
	0x30: "ABS_MT_TOUCH_MAJOR",
	0x31: "ABS_MT_TOUCH_MINOR",
	0x32: "ABS_MT_WIDTH_MAJOR",
	0x33: "ABS_MT_WIDTH_MINOR",
	0x34: "ABS_MT_ORIENTATION",
	0x35: "ABS_MT_POSITION_X",
	0x36: "ABS_MT_POSITION_Y",
	0x37: "ABS_MT_TOOL_TYPE",
	0x38: "ABS_MT_BLOB_ID",
	0x39: "ABS_MT_TRACKING_ID",
	0x3a: "ABS_MT_PRESSURE",
	0x3b: "ABS_MT_DISTANCE",
}

var relevantKeys = map[int]string{
	28:    "KEY_ENTER",
	30:    "KEY_A",
	57:    "KEY_SPACE",
	0x140: "BTN_TOOL_PEN",
	0x141: "BTN_TOOL_RUBBER",
	0x14a: "BTN_TOUCH",
	0x14b: "BTN_STYLUS",
	0x14c: "BTN_STYLUS2",
}

type inputAbsInfo struct {
	Value      int32
	Minimum    int32
	Maximum    int32
	Fuzz       int32
	Flat       int32
	Resolution int32
}

func CaptureCapabilities() Capabilities {
	result := Capabilities{
		Schema:     "rmmirror.capabilities/v1",
		CapturedAt: time.Now().UTC().Format(time.RFC3339Nano),
		Status:     "complete",
		Device: Device{
			Architecture: runtime.GOARCH,
		},
		Display: Display{
			ExpectedBacking: FrameGeometry{Width: 960, Height: 1696, BytesPerLine: 3840, PixelFormat: "BGRA8888", Observation: "community_move_capture_to_verify_live"},
			ExpectedVisible: FrameGeometry{Width: 954, Height: 1696, BytesPerLine: 3816, PixelFormat: "BGRA8888", Observation: "community_move_capture_to_verify_live"},
		},
		Errors: []ObservationError{},
	}

	result.Device.Model = readTrimmed("/sys/firmware/devicetree/base/model")
	result.Device.Compatible = readNULTokens("/sys/firmware/devicetree/base/compatible")
	result.Device.Kernel = readTrimmed("/proc/sys/kernel/osrelease")
	osRelease := parseKeyValueFile("/etc/os-release")
	result.Device.SoftwareVersion = osRelease["IMG_VERSION"]
	result.Device.OSBuild = osRelease["VERSION_ID"]

	result.Xochitl = inspectXochitl()
	result.Xovi = inspectXovi(result.Xochitl)
	if result.Xovi.FramebufferSpyMapped {
		if _, err := queryFramebufferConfig(2 * time.Second); err == nil {
			result.Xovi.FramebufferAddressSeen = true
			result.Display.ExpectedBacking.Observation = "live_framebuffer_spy"
			result.Display.ExpectedVisible.Observation = "live_stride_aware_crop"
		} else {
			result.Errors = append(result.Errors, ObservationError{Component: "framebuffer_spy", Code: ErrorCode(err)})
		}
	}
	result.Display.Connectors = inspectDRMConnectors()
	result.Input.Devices = inspectInputDevices(&result.Errors)
	result.VirtualInput = VirtualInput{
		Uinput: inspectWritableDevice("/dev/uinput"),
		UHID:   inspectWritableDevice("/dev/uhid"),
	}
	result.Transport = inspectTransport()

	if result.Device.Model == "" || result.Device.SoftwareVersion == "" || !result.Xochitl.Running || len(result.Input.Devices) == 0 {
		result.Status = "partial"
	}
	return result
}

func inspectXochitl() Xochitl {
	result := Xochitl{MappedHooks: []string{}}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return result
	}
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil || pid <= 0 {
			continue
		}
		if readTrimmed(filepath.Join("/proc", entry.Name(), "comm")) != "xochitl" {
			continue
		}
		result.Running = true
		result.PID = pid
		maps, err := os.ReadFile(filepath.Join("/proc", entry.Name(), "maps"))
		if err == nil {
			result.MapsReadable = true
			seen := map[string]bool{}
			for _, line := range strings.Split(string(maps), "\n") {
				lower := strings.ToLower(line)
				if !strings.Contains(lower, "xovi") && !strings.Contains(lower, "framebuffer") && !strings.Contains(lower, "messagebroker") {
					continue
				}
				fields := strings.Fields(line)
				if len(fields) < 6 || !strings.HasPrefix(fields[len(fields)-1], "/") {
					if len(fields) < 7 || fields[len(fields)-1] != "(deleted)" ||
						!strings.HasPrefix(fields[len(fields)-2], "/") {
						continue
					}
					fields = fields[:len(fields)-1]
				}
				path := fields[len(fields)-1]
				if !seen[path] {
					seen[path] = true
					result.MappedHooks = append(result.MappedHooks, path)
				}
			}
			sort.Strings(result.MappedHooks)
		}
		break
	}
	return result
}

func inspectXovi(xochitl Xochitl) Xovi {
	result := Xovi{DetectedPaths: []string{}}
	candidates := []string{
		"/opt/xovi",
		"/home/root/.local/bin/xovi",
		"/home/root/.local/share/xovi",
		"/home/root/xovi",
	}
	for _, path := range candidates {
		if _, err := os.Lstat(path); err == nil {
			result.DetectedPaths = append(result.DetectedPaths, path)
		}
	}
	for _, path := range xochitl.MappedHooks {
		lower := strings.ToLower(path)
		if strings.Contains(lower, "framebuffer-spy") || strings.Contains(lower, "framebuffer_spy") {
			result.FramebufferSpyMapped = true
		}
	}
	return result
}

func inspectDRMConnectors() []DRMConnector {
	paths, _ := filepath.Glob("/sys/class/drm/card*-*")
	result := make([]DRMConnector, 0, len(paths))
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil || !info.IsDir() {
			continue
		}
		connector := DRMConnector{
			Name:   filepath.Base(path),
			Status: readTrimmed(filepath.Join(path, "status")),
			Modes:  readLines(filepath.Join(path, "modes")),
		}
		result = append(result, connector)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result
}

func inspectInputDevices(observationErrors *[]ObservationError) []InputDevice {
	paths, _ := filepath.Glob("/dev/input/event*")
	sort.Strings(paths)
	result := make([]InputDevice, 0, len(paths))
	for _, path := range paths {
		device, err := inspectInputDevice(path)
		if err != nil {
			*observationErrors = append(*observationErrors, ObservationError{Component: path, Code: "evdev_query_failed"})
			continue
		}
		result = append(result, device)
	}
	return result
}

func inspectInputDevice(path string) (InputDevice, error) {
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return InputDevice{}, err
	}
	defer file.Close()

	nameBuffer := make([]byte, 256)
	if err := ioctl(file.Fd(), eviocgname(len(nameBuffer)), unsafe.Pointer(&nameBuffer[0])); err != nil {
		return InputDevice{}, err
	}
	device := InputDevice{
		Path:       path,
		Name:       cString(nameBuffer),
		Roles:      []string{},
		EventTypes: []string{},
		Keys:       []string{},
		Axes:       []AbsoluteAxis{},
	}

	typeBits := make([]byte, 8)
	if err := ioctl(file.Fd(), eviocgbit(0, len(typeBits)), unsafe.Pointer(&typeBits[0])); err != nil {
		return InputDevice{}, err
	}
	for code := 0; code < len(typeBits)*8; code++ {
		if bitSet(typeBits, code) {
			name := eventTypeNames[code]
			if name == "" {
				name = fmt.Sprintf("EV_%d", code)
			}
			device.EventTypes = append(device.EventTypes, name)
		}
	}

	keyBits := make([]byte, 96)
	if bitSet(typeBits, evKey) && ioctl(file.Fd(), eviocgbit(evKey, len(keyBits)), unsafe.Pointer(&keyBits[0])) == nil {
		keyCodes := make([]int, 0, len(relevantKeys))
		for code := range relevantKeys {
			keyCodes = append(keyCodes, code)
		}
		sort.Ints(keyCodes)
		for _, code := range keyCodes {
			if bitSet(keyBits, code) {
				device.Keys = append(device.Keys, relevantKeys[code])
			}
		}
	}

	absBits := make([]byte, 8)
	if bitSet(typeBits, evAbs) && ioctl(file.Fd(), eviocgbit(evAbs, len(absBits)), unsafe.Pointer(&absBits[0])) == nil {
		for code := 0; code < len(absBits)*8; code++ {
			if !bitSet(absBits, code) {
				continue
			}
			var info inputAbsInfo
			if ioctl(file.Fd(), eviocgabs(code), unsafe.Pointer(&info)) != nil {
				continue
			}
			name := axisNames[code]
			if name == "" {
				name = fmt.Sprintf("ABS_%d", code)
			}
			device.Axes = append(device.Axes, AbsoluteAxis{
				Code: int32(code), Name: name, Minimum: info.Minimum, Maximum: info.Maximum,
				Fuzz: info.Fuzz, Flat: info.Flat, Resolution: info.Resolution,
			})
		}
	}

	if bitSet(keyBits, 0x140) {
		device.Roles = append(device.Roles, "pen")
	}
	if bitSet(absBits, 0x35) && bitSet(absBits, 0x36) {
		device.Roles = append(device.Roles, "touch")
	}
	if bitSet(keyBits, 30) && bitSet(keyBits, 28) {
		device.Roles = append(device.Roles, "keyboard")
	}
	if len(device.Roles) == 0 {
		device.Roles = append(device.Roles, "other")
	}
	return device, nil
}

func inspectWritableDevice(path string) DeviceNode {
	result := DeviceNode{Path: path}
	if _, err := os.Stat(path); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			result.Error = "stat_failed"
		}
		return result
	}
	result.Present = true
	file, err := os.OpenFile(path, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		result.Error = "open_write_failed"
		return result
	}
	result.OpenableForWrite = true
	_ = file.Close()
	return result
}

func inspectTransport() Transport {
	result := Transport{Interfaces: []NetworkInterface{}, SSHListeners: []SSHListener{}}
	hasUSBAddress := false
	hasWiFiAddress := false
	interfaces, _ := net.Interfaces()
	for _, iface := range interfaces {
		entry := NetworkInterface{
			Name:      iface.Name,
			Up:        iface.Flags&net.FlagUp != 0,
			Loopback:  iface.Flags&net.FlagLoopback != 0,
			Addresses: []string{},
		}
		addresses, _ := iface.Addrs()
		for _, address := range addresses {
			entry.Addresses = append(entry.Addresses, address.String())
			ip, _, err := net.ParseCIDR(address.String())
			if err != nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
				continue
			}
			if iface.Name == "usb0" || strings.HasPrefix(ip.String(), "10.11.99.") {
				hasUSBAddress = true
			} else if iface.Name == "wlan0" || strings.HasPrefix(iface.Name, "wl") {
				hasWiFiAddress = true
			}
		}
		sort.Strings(entry.Addresses)
		result.Interfaces = append(result.Interfaces, entry)
	}
	sort.Slice(result.Interfaces, func(i, j int) bool { return result.Interfaces[i].Name < result.Interfaces[j].Name })

	listeners := append(parseTCPListeners("/proc/net/tcp", "ipv4"), parseTCPListeners("/proc/net/tcp6", "ipv6")...)
	seenListeners := map[string]bool{}
	hasUSBListener := false
	hasWiFiListener := false
	for _, listener := range listeners {
		key := listener.Family + "\x00" + listener.Address + "\x00" + listener.Scope
		if !seenListeners[key] {
			seenListeners[key] = true
			result.SSHListeners = append(result.SSHListeners, listener)
		}
		switch listener.Scope {
		case "all":
			result.SSHListeningAllInterfaces = true
			hasUSBListener = true
			hasWiFiListener = true
		case "usb":
			hasUSBListener = true
		case "wifi":
			hasWiFiListener = true
		}
	}
	result.USBReady = hasUSBAddress && hasUSBListener
	result.WiFiReady = hasWiFiAddress && hasWiFiListener
	return result
}

func parseTCPListeners(path, family string) []SSHListener {
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()
	result := []SSHListener{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 4 || fields[3] != "0A" {
			continue
		}
		parts := strings.Split(fields[1], ":")
		if len(parts) != 2 || strings.ToUpper(parts[1]) != "0016" {
			continue
		}
		address := decodeProcAddress(parts[0], family)
		result = append(result, SSHListener{Family: family, Address: address, Scope: classifyListener(address)})
	}
	return result
}

func decodeProcAddress(value, family string) string {
	bytesValue, err := strconv.ParseUint(value, 16, 32)
	if family == "ipv4" && err == nil {
		buffer := make([]byte, 4)
		binary.LittleEndian.PutUint32(buffer, uint32(bytesValue))
		return net.IP(buffer).String()
	}
	if family == "ipv6" {
		return strings.ToLower(value)
	}
	return value
}

func classifyListener(address string) string {
	switch {
	case address == "0.0.0.0" || address == strings.Repeat("0", 32):
		return "all"
	case strings.HasPrefix(address, "10.11.99."):
		return "usb"
	case address == "127.0.0.1" || address == "00000000000000000000000001000000":
		return "loopback"
	default:
		return "wifi"
	}
}

func readTrimmed(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.Trim(strings.TrimSpace(string(data)), "\x00")
}

func readNULTokens(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return []string{}
	}
	result := []string{}
	for _, value := range strings.Split(string(data), "\x00") {
		if value = strings.TrimSpace(value); value != "" {
			result = append(result, value)
		}
	}
	return result
}

func readLines(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return []string{}
	}
	result := []string{}
	for _, line := range strings.Split(string(data), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			result = append(result, line)
		}
	}
	return result
}

func parseKeyValueFile(path string) map[string]string {
	result := map[string]string{}
	for _, line := range readLines(path) {
		if strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if ok {
			result[key] = strings.Trim(strings.TrimSpace(value), "\"")
		}
	}
	return result
}

func bitSet(bits []byte, code int) bool {
	return code >= 0 && code/8 < len(bits) && bits[code/8]&(1<<uint(code%8)) != 0
}

func cString(value []byte) string {
	if index := strings.IndexByte(string(value), 0); index >= 0 {
		value = value[:index]
	}
	return strings.TrimSpace(string(value))
}

func ioctl(fd uintptr, request uintptr, pointer unsafe.Pointer) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, request, uintptr(pointer))
	if errno != 0 {
		return errno
	}
	return nil
}

func eviocgname(length int) uintptr {
	return ioc(2, uintptr('E'), 0x06, uintptr(length))
}

func eviocgbit(eventType, length int) uintptr {
	return ioc(2, uintptr('E'), uintptr(0x20+eventType), uintptr(length))
}

func eviocgabs(axis int) uintptr {
	return ioc(2, uintptr('E'), uintptr(0x40+axis), unsafe.Sizeof(inputAbsInfo{}))
}

func ioc(direction, kind, number, size uintptr) uintptr {
	return (direction << 30) | (size << 16) | (kind << 8) | number
}
