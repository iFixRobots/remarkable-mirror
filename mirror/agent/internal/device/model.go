package device

type Capabilities struct {
	Schema       string             `json:"schema"`
	CapturedAt   string             `json:"captured_at"`
	Status       string             `json:"status"`
	Device       Device             `json:"device"`
	Xochitl      Xochitl            `json:"xochitl"`
	Xovi         Xovi               `json:"xovi"`
	Display      Display            `json:"display"`
	Input        Input              `json:"input"`
	VirtualInput VirtualInput       `json:"virtual_input"`
	Transport    Transport          `json:"transport"`
	Errors       []ObservationError `json:"errors"`
}

type Device struct {
	Model           string   `json:"model,omitempty"`
	Compatible      []string `json:"compatible"`
	SoftwareVersion string   `json:"software_version,omitempty"`
	OSBuild         string   `json:"os_build,omitempty"`
	Kernel          string   `json:"kernel,omitempty"`
	Architecture    string   `json:"architecture"`
}

type Xochitl struct {
	Running      bool     `json:"running"`
	PID          int      `json:"pid,omitempty"`
	MapsReadable bool     `json:"maps_readable"`
	MappedHooks  []string `json:"mapped_hooks"`
}

type Xovi struct {
	DetectedPaths          []string `json:"detected_paths"`
	FramebufferSpyMapped   bool     `json:"framebuffer_spy_mapped"`
	FramebufferAddressSeen bool     `json:"framebuffer_address_seen"`
}

type Display struct {
	ExpectedBacking FrameGeometry  `json:"expected_backing"`
	ExpectedVisible FrameGeometry  `json:"expected_visible"`
	Connectors      []DRMConnector `json:"connectors"`
}

type FrameGeometry struct {
	Width        int    `json:"width"`
	Height       int    `json:"height"`
	BytesPerLine int    `json:"bytes_per_line"`
	PixelFormat  string `json:"pixel_format"`
	Observation  string `json:"observation"`
}

type DRMConnector struct {
	Name   string   `json:"name"`
	Status string   `json:"status,omitempty"`
	Modes  []string `json:"modes"`
}

type Input struct {
	Devices []InputDevice `json:"devices"`
}

type InputDevice struct {
	Path       string         `json:"path"`
	Name       string         `json:"name"`
	Roles      []string       `json:"roles"`
	EventTypes []string       `json:"event_types"`
	Keys       []string       `json:"relevant_keys"`
	Axes       []AbsoluteAxis `json:"absolute_axes"`
}

type AbsoluteAxis struct {
	Code       int32  `json:"code"`
	Name       string `json:"name"`
	Minimum    int32  `json:"minimum"`
	Maximum    int32  `json:"maximum"`
	Fuzz       int32  `json:"fuzz"`
	Flat       int32  `json:"flat"`
	Resolution int32  `json:"resolution"`
}

type VirtualInput struct {
	Uinput DeviceNode `json:"uinput"`
	UHID   DeviceNode `json:"uhid"`
}

type DeviceNode struct {
	Path             string `json:"path"`
	Present          bool   `json:"present"`
	OpenableForWrite bool   `json:"openable_for_write"`
	Error            string `json:"error,omitempty"`
}

type Transport struct {
	Interfaces                []NetworkInterface `json:"interfaces"`
	SSHListeners              []SSHListener      `json:"ssh_listeners"`
	SSHListeningAllInterfaces bool               `json:"ssh_listening_all_interfaces"`
	USBReady                  bool               `json:"usb_ready"`
	WiFiReady                 bool               `json:"wifi_ready"`
}

type NetworkInterface struct {
	Name      string   `json:"name"`
	Up        bool     `json:"up"`
	Loopback  bool     `json:"loopback"`
	Addresses []string `json:"addresses"`
}

type SSHListener struct {
	Family  string `json:"family"`
	Address string `json:"address"`
	Scope   string `json:"scope"`
}

type ObservationError struct {
	Component string `json:"component"`
	Code      string `json:"code"`
}
