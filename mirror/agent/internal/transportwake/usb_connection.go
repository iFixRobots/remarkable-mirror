package transportwake

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
)

const (
	DefaultPowerOnlinePath = "/sys/class/power_supply/max77818-charger/online"
	DefaultUDCStatePattern = "/sys/class/udc/*/state"
)

type SignalState struct {
	Known  bool
	Active bool
}

type USBSignals struct {
	Carrier            SignalState
	UDCConfigured      SignalState
	UDCSignalEnabled   bool
	PowerOnline        SignalState
	PowerSignalEnabled bool
}

type USBConnectionLatch struct {
	dataQualified bool
}

func (latch *USBConnectionLatch) Resolve(signals USBSignals) (connected bool, known bool) {
	if signals.PowerSignalEnabled && signals.PowerOnline.Known && !signals.PowerOnline.Active {
		latch.dataQualified = false
		// The charger input is the physical-power authority. A known zero
		// confirms detach even if the network carrier has not caught up yet.
		return false, true
	}
	dataConnection := signals.dataConnection()
	if dataConnection.Known && dataConnection.Active {
		latch.dataQualified = true
		return true, true
	}

	if !signals.PowerSignalEnabled {
		return false, dataConnection.Known
	}
	if latch.dataQualified && signals.PowerOnline.Known && signals.PowerOnline.Active {
		return true, true
	}
	if dataConnection.Known && !dataConnection.Active &&
		signals.PowerOnline.Known && signals.PowerOnline.Active {
		// A powered cable that has not carried Mirror's USB network in this
		// service or executor session is ordinary charging, not an active
		// Mirror attachment.
		return false, true
	}
	return false, false
}

func (signals USBSignals) dataConnection() SignalState {
	if signals.Carrier.Known && signals.Carrier.Active ||
		signals.UDCConfigured.Known && signals.UDCConfigured.Active {
		return SignalState{Known: true, Active: true}
	}
	if !signals.UDCSignalEnabled {
		return signals.Carrier
	}
	if signals.Carrier.Known && signals.UDCConfigured.Known {
		return SignalState{Known: true}
	}
	return SignalState{}
}

func (latch *USBConnectionLatch) DataQualified() bool {
	return latch.dataQualified
}

func ReadUSBSignals(
	readFile func(string) ([]byte, error),
	carrierPath string,
	udcStatePattern string,
	powerOnlinePath string,
) (USBSignals, error) {
	carrier, carrierErr := readBinarySignal(readFile, carrierPath, "USB carrier")
	udcConfigured, udcSignalEnabled, udcErr := readUDCConfiguredSignal(
		readFile,
		udcStatePattern,
	)
	if carrier.Known && carrier.Active {
		udcErr = nil
	}
	if udcConfigured.Known && udcConfigured.Active {
		carrierErr = nil
	}
	signals := USBSignals{
		Carrier:            carrier,
		UDCConfigured:      udcConfigured,
		UDCSignalEnabled:   udcSignalEnabled,
		PowerSignalEnabled: powerOnlinePath != "",
	}
	if powerOnlinePath == "" {
		return signals, errors.Join(carrierErr, udcErr)
	}

	powerOnline, powerErr := readBinarySignal(readFile, powerOnlinePath, "USB power")
	signals.PowerOnline = powerOnline
	return signals, errors.Join(carrierErr, udcErr, powerErr)
}

func readUDCConfiguredSignal(
	readFile func(string) ([]byte, error),
	statePattern string,
) (SignalState, bool, error) {
	if statePattern == "" {
		return SignalState{}, false, nil
	}
	paths, err := filepath.Glob(statePattern)
	if err != nil {
		return SignalState{}, true, fmt.Errorf("resolve USB device-controller state: %w", err)
	}
	if len(paths) == 0 {
		return SignalState{}, true, fmt.Errorf(
			"resolve USB device-controller state: no controllers found",
		)
	}
	configuredCount := 0
	for _, statePath := range paths {
		payload, readErr := readFile(statePath)
		if readErr != nil {
			return SignalState{}, true, fmt.Errorf(
				"read USB device-controller state: %w",
				readErr,
			)
		}
		switch strings.TrimSpace(string(payload)) {
		case "configured":
			configuredCount++
		case "not-attached", "not attached", "attached", "powered", "reconnecting", "unauthenticated",
			"default", "addressed", "suspended":
		default:
			return SignalState{}, true, fmt.Errorf(
				"read USB device-controller state: unexpected value %q",
				strings.TrimSpace(string(payload)),
			)
		}
	}
	switch configuredCount {
	case 0:
		return SignalState{Known: true}, true, nil
	case 1:
		return SignalState{Known: true, Active: true}, true, nil
	default:
		return SignalState{}, true, fmt.Errorf(
			"resolve USB device-controller state: found %d configured controllers",
			configuredCount,
		)
	}
}

func readBinarySignal(
	readFile func(string) ([]byte, error),
	path string,
	name string,
) (SignalState, error) {
	value, err := readFile(path)
	if err != nil {
		return SignalState{}, fmt.Errorf("read %s: %w", name, err)
	}
	switch strings.TrimSpace(string(value)) {
	case "1":
		return SignalState{Known: true, Active: true}, nil
	case "0":
		return SignalState{Known: true}, nil
	default:
		return SignalState{}, fmt.Errorf(
			"read %s: unexpected value %q",
			name,
			strings.TrimSpace(string(value)),
		)
	}
}
