//go:build linux

package device

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"time"
)

const streamHeaderBytes = 28

type changedRegion struct {
	x      int
	y      int
	width  int
	height int
}

func StreamFrames(ctx context.Context, writer io.Writer, interval time.Duration) error {
	if interval < 16*time.Millisecond || interval > time.Second {
		return codedError{code: "invalid_interval"}
	}
	reader, err := newFrameReader()
	if err != nil {
		return err
	}
	defer reader.Close()

	buffered := bufio.NewWriterSize(writer, 256*1024)
	previous := make([]byte, moveVisibleBytes)
	delta := make([]byte, moveVisibleBytes)
	sequence := uint64(0)
	first := true
	for {
		if ctx.Err() != nil {
			return nil
		}

		started := time.Now()
		current, captureErr := reader.Capture()
		if captureErr != nil {
			return captureErr
		}
		if ctx.Err() != nil {
			return nil
		}

		region, changed := findChangedRegion(current, previous, first)
		if changed {
			sequence++
			payload := packRegion(current, delta, region)
			header := makeStreamHeader(sequence, region, first, len(payload))
			if _, err := buffered.Write(header[:]); err != nil {
				return codedError{code: "stream_header_write_failed"}
			}
			if _, err := buffered.Write(payload); err != nil {
				return codedError{code: "stream_payload_write_failed"}
			}
			if err := buffered.Flush(); err != nil {
				return codedError{code: "stream_flush_failed"}
			}
			copyRegion(previous, current, region)
			first = false
		}
		if remaining := interval - time.Since(started); remaining > 0 {
			if !waitForStreamInterval(ctx, remaining) {
				return nil
			}
		}
	}
}

func copyRegion(target, source []byte, region changedRegion) {
	rowBytes := region.width * 4
	for row := 0; row < region.height; row++ {
		start := (region.y+row)*moveVisibleRowSize + region.x*4
		copy(target[start:start+rowBytes], source[start:start+rowBytes])
	}
}

func findChangedRegion(current, previous []byte, forceFull bool) (changedRegion, bool) {
	if forceFull {
		return changedRegion{x: 0, y: 0, width: moveVisibleWidth, height: moveHeight}, true
	}
	minX, minY := moveVisibleWidth, moveHeight
	maxX, maxY := -1, -1
	for y := 0; y < moveHeight; y++ {
		rowStart := y * moveVisibleRowSize
		currentRow := current[rowStart : rowStart+moveVisibleRowSize]
		previousRow := previous[rowStart : rowStart+moveVisibleRowSize]
		if bytes.Equal(currentRow, previousRow) {
			continue
		}
		if y < minY {
			minY = y
		}
		maxY = y
		for x := 0; x < moveVisibleWidth; x++ {
			offset := x * 4
			if currentRow[offset] == previousRow[offset] &&
				currentRow[offset+1] == previousRow[offset+1] &&
				currentRow[offset+2] == previousRow[offset+2] &&
				currentRow[offset+3] == previousRow[offset+3] {
				continue
			}
			if x < minX {
				minX = x
			}
			if x > maxX {
				maxX = x
			}
		}
	}
	if maxX < minX || maxY < minY {
		return changedRegion{}, false
	}
	return changedRegion{x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1}, true
}

func packRegion(frame, scratch []byte, region changedRegion) []byte {
	if region.x == 0 && region.width == moveVisibleWidth {
		start := region.y * moveVisibleRowSize
		return frame[start : start+region.height*moveVisibleRowSize]
	}
	rowBytes := region.width * 4
	payload := scratch[:rowBytes*region.height]
	for row := 0; row < region.height; row++ {
		sourceStart := (region.y+row)*moveVisibleRowSize + region.x*4
		targetStart := row * rowBytes
		copy(payload[targetStart:targetStart+rowBytes], frame[sourceStart:sourceStart+rowBytes])
	}
	return payload
}

func makeStreamHeader(sequence uint64, region changedRegion, full bool, payloadBytes int) [streamHeaderBytes]byte {
	var header [streamHeaderBytes]byte
	copy(header[0:4], "RMM1")
	header[4] = 1
	if full {
		header[5] = 1
	}
	binary.LittleEndian.PutUint16(header[6:8], streamHeaderBytes)
	binary.LittleEndian.PutUint64(header[8:16], sequence)
	binary.LittleEndian.PutUint16(header[16:18], uint16(region.x))
	binary.LittleEndian.PutUint16(header[18:20], uint16(region.y))
	binary.LittleEndian.PutUint16(header[20:22], uint16(region.width))
	binary.LittleEndian.PutUint16(header[22:24], uint16(region.height))
	binary.LittleEndian.PutUint32(header[24:28], uint32(payloadBytes))
	return header
}
