package device

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"strings"
	"sync"
	"time"
)

const (
	inputSchema                  = "rmmirror.input/v1"
	DefaultMarkerPath            = "/dev/input/event2"
	DefaultInputLockPath         = "/run/rmmirror-input.lock"
	DefaultInputHeartbeatTimeout = 15 * time.Second

	touchXMax = 1248
	touchYMax = 2208
	penXMax   = 6760
	penYMax   = 11960

	maxInputCommandBytes = 64 * 1024
	maxTextBytes         = 4096
	inputEventBytes      = 24
	maxMarkerFrameBytes  = 64 * 1024
)

const maximumInputHeartbeatTimeout = 2 * time.Minute

type inputCommand struct {
	ID       uint64   `json:"id"`
	Type     string   `json:"type"`
	Action   string   `json:"action,omitempty"`
	X        *float64 `json:"x,omitempty"`
	Y        *float64 `json:"y,omitempty"`
	Pressure *float64 `json:"pressure,omitempty"`
	Tool     string   `json:"tool,omitempty"`
	Key      string   `json:"key,omitempty"`
	Text     string   `json:"text,omitempty"`
}

type inputResponse struct {
	Schema       string         `json:"schema,omitempty"`
	Ready        bool           `json:"ready,omitempty"`
	DisplayState string         `json:"display_state,omitempty"`
	FilesState   string         `json:"files_state,omitempty"`
	ID           uint64         `json:"id,omitempty"`
	OK           bool           `json:"ok,omitempty"`
	Error        string         `json:"error,omitempty"`
	Touch        *axisRangePair `json:"touch,omitempty"`
	Pen          *axisRangePair `json:"pen,omitempty"`
	Text         string         `json:"text,omitempty"`
}

type axisRangePair struct {
	XMax int `json:"x_max"`
	YMax int `json:"y_max"`
}

type inputBackend interface {
	Touch(action string, x, y, pressure int) error
	Pen(action string, x, y, pressure int, tool string) error
	Key(action string, code int) error
	Reset() error
	Close() error
}

func ServeInput(
	ctx context.Context,
	markerPath string,
	heartbeatTimeout time.Duration,
	enableFilesFallback bool,
	reader io.Reader,
	writer io.Writer,
) error {
	if ctx == nil {
		ctx = context.Background()
	}
	if markerPath == "" {
		return codedError{code: "invalid_marker_path"}
	}
	if heartbeatTimeout < 5*time.Second || heartbeatTimeout > maximumInputHeartbeatTimeout {
		return codedError{code: "invalid_heartbeat_timeout"}
	}
	return serveManagedInput(
		ctx,
		markerPath,
		heartbeatTimeout,
		enableFilesFallback,
		reader,
		writer,
	)
}

func serveInputSession(reader io.Reader, writer io.Writer, backend inputBackend) error {
	return serveInputSessionWithLeaseState(context.Background(), 0, reader, writer, backend, "unknown")
}

type scannedInputLine struct {
	line []byte
	err  error
}

func serveInputSessionWithLease(
	ctx context.Context,
	heartbeatTimeout time.Duration,
	reader io.Reader,
	writer io.Writer,
	backend inputBackend,
) error {
	return serveInputSessionWithLeaseState(ctx, heartbeatTimeout, reader, writer, backend, "unknown")
}

func serveInputSessionWithLeaseState(
	ctx context.Context,
	heartbeatTimeout time.Duration,
	reader io.Reader,
	writer io.Writer,
	backend inputBackend,
	displayState string,
) error {
	return serveInputSessionWithStartupState(
		ctx,
		heartbeatTimeout,
		reader,
		writer,
		backend,
		displayState,
		"",
	)
}

func serveInputSessionWithStartupState(
	ctx context.Context,
	heartbeatTimeout time.Duration,
	reader io.Reader,
	writer io.Writer,
	backend inputBackend,
	displayState string,
	filesState string,
) error {
	encoder := json.NewEncoder(writer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(inputResponse{
		Schema:       inputSchema,
		Ready:        true,
		DisplayState: displayState,
		FilesState:   filesState,
		Touch:        &axisRangePair{XMax: touchXMax, YMax: touchYMax},
		Pen:          &axisRangePair{XMax: penXMax, YMax: penYMax},
		Text:         "us-ascii",
	}); err != nil {
		if resetErr := backend.Reset(); resetErr != nil {
			return codedError{code: "input_reset_failed"}
		}
		return codedError{code: "ready_write_failed"}
	}

	lines, stopScanning := scanInputLines(reader)
	defer stopScanning()
	var heartbeat *time.Timer
	var heartbeatChannel <-chan time.Time
	if heartbeatTimeout > 0 {
		heartbeat = time.NewTimer(heartbeatTimeout)
		heartbeatChannel = heartbeat.C
		defer heartbeat.Stop()
	}
	var sessionErr error
	for sessionErr == nil {
		var scanned scannedInputLine
		select {
		case <-ctx.Done():
			closeInputReader(reader)
			sessionErr = nil
			goto sessionComplete
		case <-heartbeatChannel:
			closeInputReader(reader)
			sessionErr = codedError{code: "heartbeat_timeout"}
			goto sessionComplete
		case next, ok := <-lines:
			if !ok {
				goto sessionComplete
			}
			scanned = next
		}
		if scanned.err != nil {
			sessionErr = codedError{code: "command_read_failed"}
			break
		}
		if heartbeat != nil {
			if !heartbeat.Stop() {
				select {
				case <-heartbeat.C:
				default:
				}
			}
			heartbeat.Reset(heartbeatTimeout)
		}

		line := scanned.line
		if len(strings.TrimSpace(string(line))) == 0 {
			continue
		}

		var command inputCommand
		if err := json.Unmarshal(line, &command); err != nil {
			if writeErr := writeInputResponse(encoder, inputResponse{Error: "invalid_json"}); writeErr != nil {
				sessionErr = writeErr
				break
			}
			continue
		}
		response := inputResponse{ID: command.ID}
		if command.ID == 0 {
			response.Error = "id_required"
		} else if err := executeInputCommand(backend, command); err != nil {
			response.Error = inputCommandError(err)
		} else {
			response.OK = true
		}
		if err := writeInputResponse(encoder, response); err != nil {
			sessionErr = err
			break
		}
	}

sessionComplete:
	if err := backend.Reset(); err != nil {
		return codedError{code: "input_reset_failed"}
	}
	return sessionErr
}

func scanInputLines(reader io.Reader) (<-chan scannedInputLine, func()) {
	lines := make(chan scannedInputLine, 1)
	done := make(chan struct{})
	var stopOnce sync.Once
	stop := func() { stopOnce.Do(func() { close(done) }) }
	send := func(value scannedInputLine) bool {
		select {
		case lines <- value:
			return true
		case <-done:
			return false
		}
	}
	go func() {
		defer close(lines)
		scanner := bufio.NewScanner(reader)
		scanner.Buffer(make([]byte, 4096), maxInputCommandBytes)
		for scanner.Scan() {
			line := append([]byte(nil), scanner.Bytes()...)
			if !send(scannedInputLine{line: line}) {
				return
			}
		}
		if err := scanner.Err(); err != nil {
			_ = send(scannedInputLine{err: err})
		}
	}()
	return lines, stop
}

func closeInputReader(reader io.Reader) {
	if closer, ok := reader.(io.Closer); ok {
		_ = closer.Close()
	}
}

func relayMarkerFrames(reader io.Reader, emit func([]byte) error) error {
	eventBytes := make([]byte, inputEventBytes)
	frame := make([]byte, 0, inputEventBytes*16)
	for {
		if _, err := io.ReadFull(reader, eventBytes); err != nil {
			return codedError{code: "marker_read_failed"}
		}
		frame = append(frame, eventBytes...)
		if len(frame) > maxMarkerFrameBytes {
			return codedError{code: "marker_frame_too_large"}
		}
		eventType := binary.LittleEndian.Uint16(eventBytes[16:18])
		eventCode := binary.LittleEndian.Uint16(eventBytes[18:20])
		if eventType != 0 || eventCode != 0 {
			continue
		}
		if err := emit(frame); err != nil {
			return codedError{code: "marker_frame_write_failed"}
		}
		frame = frame[:0]
	}
}

func writeInputResponse(encoder *json.Encoder, response inputResponse) error {
	if err := encoder.Encode(response); err != nil {
		return codedError{code: "response_write_failed"}
	}
	return nil
}

func executeInputCommand(backend inputBackend, command inputCommand) error {
	switch strings.ToLower(command.Type) {
	case "touch":
		if err := validatePointerAction(command.Action); err != nil {
			return err
		}
		if command.Action == "up" {
			return backend.Touch("up", 0, 0, 0)
		}
		x, y, err := mapPoint(command.X, command.Y, touchXMax, touchYMax)
		if err != nil {
			return err
		}
		pressure, err := mapOptionalUnit(command.Pressure, 255, 255)
		if err != nil {
			return err
		}
		return backend.Touch(command.Action, x, y, pressure)

	case "pen":
		if err := validatePointerAction(command.Action); err != nil {
			return err
		}
		tool := strings.ToLower(command.Tool)
		if tool == "" && command.Action == "down" {
			tool = "pen"
		}
		if tool != "" && tool != "pen" && tool != "eraser" {
			return fmt.Errorf("unsupported_tool")
		}
		if command.Action == "up" {
			return backend.Pen("up", 0, 0, 0, tool)
		}
		x, y, err := mapPoint(command.X, command.Y, penXMax, penYMax)
		if err != nil {
			return err
		}
		pressure, err := mapOptionalUnit(command.Pressure, 4096, 2048)
		if err != nil {
			return err
		}
		return backend.Pen(command.Action, x, y, pressure, tool)

	case "key":
		action := strings.ToLower(command.Action)
		if action != "down" && action != "up" && action != "click" {
			return fmt.Errorf("invalid_action")
		}
		code, ok := linuxKeyCode(command.Key)
		if !ok {
			return fmt.Errorf("unsupported_key")
		}
		if action == "click" {
			if err := backend.Key("down", code); err != nil {
				return err
			}
			if err := backend.Key("up", code); err != nil {
				_ = backend.Reset()
				return err
			}
			return nil
		}
		return backend.Key(action, code)

	case "text":
		if command.Text == "" {
			return fmt.Errorf("text_required")
		}
		if len(command.Text) > maxTextBytes {
			return fmt.Errorf("text_too_long")
		}
		text := strings.ReplaceAll(command.Text, "\r\n", "\n")
		strokes := make([]keyStroke, 0, len(text))
		for _, character := range text {
			stroke, ok := asciiKeyStroke(character)
			if !ok {
				return fmt.Errorf("unsupported_character")
			}
			strokes = append(strokes, stroke)
		}
		for _, stroke := range strokes {
			if stroke.shift {
				if err := backend.Key("down", keyLeftShift); err != nil {
					return err
				}
			}
			if err := backend.Key("down", stroke.code); err != nil {
				if stroke.shift {
					_ = backend.Key("up", keyLeftShift)
				}
				return err
			}
			if err := backend.Key("up", stroke.code); err != nil {
				_ = backend.Reset()
				return err
			}
			if stroke.shift {
				if err := backend.Key("up", keyLeftShift); err != nil {
					_ = backend.Reset()
					return err
				}
			}
		}
		return nil

	case "reset":
		return backend.Reset()

	case "ping":
		return nil

	default:
		return fmt.Errorf("unsupported_type")
	}
}

func inputCommandError(err error) string {
	if err == nil {
		return ""
	}
	message := err.Error()
	if strings.Contains(message, ":") {
		return "input_failed"
	}
	return message
}

func validatePointerAction(action string) error {
	if action != "down" && action != "move" && action != "up" {
		return fmt.Errorf("invalid_action")
	}
	return nil
}

func mapPoint(x, y *float64, xMax, yMax int) (int, int, error) {
	if x == nil || y == nil {
		return 0, 0, fmt.Errorf("coordinates_required")
	}
	mappedX, err := mapUnit(*x, xMax)
	if err != nil {
		return 0, 0, fmt.Errorf("invalid_coordinates")
	}
	mappedY, err := mapUnit(*y, yMax)
	if err != nil {
		return 0, 0, fmt.Errorf("invalid_coordinates")
	}
	return mappedX, mappedY, nil
}

func mapOptionalUnit(value *float64, maximum, defaultValue int) (int, error) {
	if value == nil {
		return defaultValue, nil
	}
	mapped, err := mapUnit(*value, maximum)
	if err != nil {
		return 0, fmt.Errorf("invalid_pressure")
	}
	return mapped, nil
}

func mapUnit(value float64, maximum int) (int, error) {
	if math.IsNaN(value) || math.IsInf(value, 0) || value < 0 || value > 1 {
		return 0, fmt.Errorf("outside_unit_range")
	}
	return int(math.Round(value * float64(maximum))), nil
}

type keyStroke struct {
	code  int
	shift bool
}

const (
	keyEsc        = 1
	key1          = 2
	key2          = 3
	key3          = 4
	key4          = 5
	key5          = 6
	key6          = 7
	key7          = 8
	key8          = 9
	key9          = 10
	key0          = 11
	keyMinus      = 12
	keyEqual      = 13
	keyBackspace  = 14
	keyTab        = 15
	keyQ          = 16
	keyW          = 17
	keyE          = 18
	keyR          = 19
	keyT          = 20
	keyY          = 21
	keyU          = 22
	keyI          = 23
	keyO          = 24
	keyP          = 25
	keyLeftBrace  = 26
	keyRightBrace = 27
	keyEnter      = 28
	keyLeftCtrl   = 29
	keyA          = 30
	keyS          = 31
	keyD          = 32
	keyF          = 33
	keyG          = 34
	keyH          = 35
	keyJ          = 36
	keyK          = 37
	keyL          = 38
	keySemicolon  = 39
	keyApostrophe = 40
	keyGrave      = 41
	keyLeftShift  = 42
	keyBackslash  = 43
	keyZ          = 44
	keyX          = 45
	keyC          = 46
	keyV          = 47
	keyB          = 48
	keyN          = 49
	keyM          = 50
	keyComma      = 51
	keyDot        = 52
	keySlash      = 53
	keyRightShift = 54
	keyLeftAlt    = 56
	keySpace      = 57
	keyCapsLock   = 58
	keyF1         = 59
	keyF2         = 60
	keyF3         = 61
	keyF4         = 62
	keyF5         = 63
	keyF6         = 64
	keyF7         = 65
	keyF8         = 66
	keyF9         = 67
	keyF10        = 68
	keyF11        = 87
	keyF12        = 88
	keyRightCtrl  = 97
	keyRightAlt   = 100
	keyHome       = 102
	keyUp         = 103
	keyPageUp     = 104
	keyLeft       = 105
	keyRight      = 106
	keyEnd        = 107
	keyDown       = 108
	keyPageDown   = 109
	keyInsert     = 110
	keyDelete     = 111
	keyPower      = 116
	keyWakeup     = 143
	keyLeftMeta   = 125
	keyRightMeta  = 126
)

var keyNames = buildKeyNames()

func buildKeyNames() map[string]int {
	result := map[string]int{
		"ESC": keyEsc, "BACKSPACE": keyBackspace, "TAB": keyTab, "ENTER": keyEnter,
		"MINUS": keyMinus, "EQUAL": keyEqual, "LEFTBRACE": keyLeftBrace, "RIGHTBRACE": keyRightBrace,
		"SEMICOLON": keySemicolon, "APOSTROPHE": keyApostrophe, "GRAVE": keyGrave, "BACKSLASH": keyBackslash,
		"COMMA": keyComma, "DOT": keyDot, "SLASH": keySlash,
		"LEFTCTRL": keyLeftCtrl, "LEFTSHIFT": keyLeftShift, "RIGHTSHIFT": keyRightShift,
		"LEFTALT": keyLeftAlt, "SPACE": keySpace, "CAPSLOCK": keyCapsLock,
		"RIGHTCTRL": keyRightCtrl, "RIGHTALT": keyRightAlt,
		"HOME": keyHome, "UP": keyUp, "PAGEUP": keyPageUp, "LEFT": keyLeft,
		"RIGHT": keyRight, "END": keyEnd, "DOWN": keyDown, "PAGEDOWN": keyPageDown,
		"INSERT": keyInsert, "DELETE": keyDelete, "POWER": keyPower, "WAKEUP": keyWakeup,
		"LEFTMETA": keyLeftMeta, "RIGHTMETA": keyRightMeta,
	}
	letters := []int{keyA, keyB, keyC, keyD, keyE, keyF, keyG, keyH, keyI, keyJ, keyK, keyL, keyM,
		keyN, keyO, keyP, keyQ, keyR, keyS, keyT, keyU, keyV, keyW, keyX, keyY, keyZ}
	for index, code := range letters {
		result[string(rune('A'+index))] = code
	}
	digits := []int{key0, key1, key2, key3, key4, key5, key6, key7, key8, key9}
	for index, code := range digits {
		result[string(rune('0'+index))] = code
	}
	for index, code := range []int{keyF1, keyF2, keyF3, keyF4, keyF5, keyF6, keyF7, keyF8, keyF9, keyF10, keyF11, keyF12} {
		result[fmt.Sprintf("F%d", index+1)] = code
	}
	return result
}

func linuxKeyCode(name string) (int, bool) {
	name = strings.ToUpper(strings.TrimSpace(name))
	name = strings.TrimPrefix(name, "KEY_")
	code, ok := keyNames[name]
	return code, ok
}

func asciiKeyStroke(character rune) (keyStroke, bool) {
	if character >= 'a' && character <= 'z' {
		return keyStroke{code: keyNames[string(character-'a'+'A')]}, true
	}
	if character >= 'A' && character <= 'Z' {
		return keyStroke{code: keyNames[string(character)], shift: true}, true
	}
	if character >= '0' && character <= '9' {
		return keyStroke{code: keyNames[string(character)]}, true
	}
	punctuation := map[rune]keyStroke{
		' ': {code: keySpace}, '\n': {code: keyEnter}, '\r': {code: keyEnter}, '\t': {code: keyTab}, '\b': {code: keyBackspace},
		'-': {code: keyMinus}, '_': {code: keyMinus, shift: true}, '=': {code: keyEqual}, '+': {code: keyEqual, shift: true},
		'[': {code: keyLeftBrace}, '{': {code: keyLeftBrace, shift: true}, ']': {code: keyRightBrace}, '}': {code: keyRightBrace, shift: true},
		';': {code: keySemicolon}, ':': {code: keySemicolon, shift: true}, '\'': {code: keyApostrophe}, '"': {code: keyApostrophe, shift: true},
		'`': {code: keyGrave}, '~': {code: keyGrave, shift: true}, '\\': {code: keyBackslash}, '|': {code: keyBackslash, shift: true},
		',': {code: keyComma}, '<': {code: keyComma, shift: true}, '.': {code: keyDot}, '>': {code: keyDot, shift: true},
		'/': {code: keySlash}, '?': {code: keySlash, shift: true},
		'!': {code: key1, shift: true}, '@': {code: key2, shift: true}, '#': {code: key3, shift: true}, '$': {code: key4, shift: true},
		'%': {code: key5, shift: true}, '^': {code: key6, shift: true}, '&': {code: key7, shift: true}, '*': {code: key8, shift: true},
		'(': {code: key9, shift: true}, ')': {code: key0, shift: true},
	}
	stroke, ok := punctuation[character]
	return stroke, ok
}

func supportedKeyCodes() []int {
	seen := make(map[int]bool)
	result := make([]int, 0, len(keyNames)+12)
	for _, code := range keyNames {
		if !seen[code] {
			seen[code] = true
			result = append(result, code)
		}
	}
	for _, character := range "-_ =+[]{};:'\"`~\\|,<.>/? !@#$%^&*()" {
		stroke, _ := asciiKeyStroke(character)
		if !seen[stroke.code] {
			seen[stroke.code] = true
			result = append(result, stroke.code)
		}
	}
	return result
}
