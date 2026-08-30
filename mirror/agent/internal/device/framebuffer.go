package device

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const (
	moveBackingWidth   = 960
	moveVisibleWidth   = 954
	moveHeight         = 1696
	moveBytesPerLine   = 3840
	moveVisibleRowSize = moveVisibleWidth * 4
	moveBackingBytes   = moveBytesPerLine * moveHeight
	moveVisibleBytes   = moveVisibleRowSize * moveHeight
)

type framebufferConfig struct {
	address        uint64
	width          int
	height         int
	pixelType      int
	bytesPerLine   int
	requiresReload bool
}

type codedError struct {
	code string
}

func (err codedError) Error() string { return err.code }

func ErrorCode(err error) string {
	var coded codedError
	if errors.As(err, &coded) {
		return coded.code
	}
	return "failed"
}

func parseFramebufferConfig(value string) (framebufferConfig, error) {
	value = strings.TrimSpace(value)
	if value == "NULL" {
		return framebufferConfig{}, codedError{code: "not_ready"}
	}
	parts := strings.Split(value, ",")
	if len(parts) != 6 {
		return framebufferConfig{}, codedError{code: "invalid_config"}
	}
	address, err := strconv.ParseUint(strings.TrimPrefix(parts[0], "0x"), 16, 64)
	if err != nil || address == 0 {
		return framebufferConfig{}, codedError{code: "invalid_address"}
	}
	values := make([]int, 4)
	for index := range values {
		parsed, parseErr := strconv.Atoi(parts[index+1])
		if parseErr != nil {
			return framebufferConfig{}, codedError{code: "invalid_config"}
		}
		values[index] = parsed
	}
	reload, err := strconv.Atoi(parts[5])
	if err != nil || (reload != 0 && reload != 1) {
		return framebufferConfig{}, codedError{code: "invalid_config"}
	}
	config := framebufferConfig{
		address:        address,
		width:          values[0],
		height:         values[1],
		pixelType:      values[2],
		bytesPerLine:   values[3],
		requiresReload: reload == 1,
	}
	if config.width != moveBackingWidth || config.height != moveHeight ||
		config.pixelType != 2 || config.bytesPerLine != moveBytesPerLine || config.requiresReload {
		return framebufferConfig{}, codedError{code: fmt.Sprintf("unexpected_tuple_%dx%d_t%d_bpl%d_reload%t", config.width, config.height, config.pixelType, config.bytesPerLine, config.requiresReload)}
	}
	return config, nil
}

func cropMoveFrame(backing []byte) ([]byte, error) {
	if len(backing) != moveBackingBytes {
		return nil, codedError{code: "short_backing_frame"}
	}
	visible := make([]byte, moveVisibleBytes)
	if err := cropMoveFrameInto(backing, visible); err != nil {
		return nil, err
	}
	return visible, nil
}

func cropMoveFrameInto(backing, visible []byte) error {
	if len(backing) != moveBackingBytes {
		return codedError{code: "short_backing_frame"}
	}
	if len(visible) != moveVisibleBytes {
		return codedError{code: "invalid_visible_frame"}
	}
	for row := 0; row < moveHeight; row++ {
		sourceStart := row * moveBytesPerLine
		targetStart := row * moveVisibleRowSize
		copy(visible[targetStart:targetStart+moveVisibleRowSize], backing[sourceStart:sourceStart+moveVisibleRowSize])
	}
	return nil
}
