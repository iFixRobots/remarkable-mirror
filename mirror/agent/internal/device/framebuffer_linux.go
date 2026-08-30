//go:build linux

package device

import (
	"fmt"
	"image"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

const (
	xoviMessageInput  = "/run/xovi-mb"
	xoviMessageOutput = "/run/xovi-mb-out"
	framebufferQuery  = ">eframebuffer-spy$getConfigString:\n"
)

type fifoResult struct {
	value string
	err   error
}

type frameReader struct {
	memory  *os.File
	address int64
	backing []byte
	visible []byte
}

func WriteVisibleFrame(writer io.Writer, format string) error {
	if format != "bgra" && format != "png" {
		return codedError{code: "unsupported_format"}
	}
	reader, err := newFrameReader()
	if err != nil {
		return err
	}
	defer reader.Close()
	visible, err := reader.Capture()
	if err != nil {
		return err
	}
	if format == "png" {
		return writePNG(writer, visible)
	}
	return writeAll(writer, visible)
}

func newFrameReader() (*frameReader, error) {
	xochitl := inspectXochitl()
	if !xochitl.Running || xochitl.PID <= 0 {
		return nil, codedError{code: "xochitl_not_running"}
	}
	config, err := queryFramebufferConfig(2 * time.Second)
	if err != nil {
		return nil, err
	}
	memoryPath := filepath.Join("/proc", fmt.Sprintf("%d", xochitl.PID), "mem")
	memory, err := os.Open(memoryPath)
	if err != nil {
		return nil, codedError{code: "process_memory_open_failed"}
	}
	return &frameReader{
		memory: memory, address: int64(config.address),
		backing: make([]byte, moveBackingBytes), visible: make([]byte, moveVisibleBytes),
	}, nil
}

func (reader *frameReader) Close() error {
	return reader.memory.Close()
}

func (reader *frameReader) Capture() ([]byte, error) {
	read, err := reader.memory.ReadAt(reader.backing, reader.address)
	if err != nil && err != io.EOF {
		return nil, codedError{code: "process_memory_read_failed"}
	}
	if read != len(reader.backing) {
		return nil, codedError{code: "process_memory_short_read"}
	}
	if err := cropMoveFrameInto(reader.backing, reader.visible); err != nil {
		return nil, err
	}
	return reader.visible, nil
}

func writeAll(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		written, writeErr := writer.Write(data)
		if writeErr != nil {
			return codedError{code: "output_write_failed"}
		}
		if written <= 0 {
			return codedError{code: "output_short_write"}
		}
		data = data[written:]
	}
	return nil
}

func writePNG(writer io.Writer, bgra []byte) error {
	if len(bgra) != moveVisibleBytes {
		return codedError{code: "invalid_visible_frame"}
	}
	imageBuffer := image.NewNRGBA(image.Rect(0, 0, moveVisibleWidth, moveHeight))
	for source := 0; source < len(bgra); source += 4 {
		imageBuffer.Pix[source] = bgra[source+2]
		imageBuffer.Pix[source+1] = bgra[source+1]
		imageBuffer.Pix[source+2] = bgra[source]
		imageBuffer.Pix[source+3] = bgra[source+3]
	}
	encoder := png.Encoder{CompressionLevel: png.BestSpeed}
	if err := encoder.Encode(writer, imageBuffer); err != nil {
		return codedError{code: "png_encode_failed"}
	}
	return nil
}

func queryFramebufferConfig(timeout time.Duration) (framebufferConfig, error) {
	for _, path := range []string{xoviMessageInput, xoviMessageOutput} {
		info, err := os.Stat(path)
		if err != nil || info.Mode()&os.ModeNamedPipe == 0 {
			return framebufferConfig{}, codedError{code: "broker_unavailable"}
		}
	}

	resultChannel := make(chan fifoResult, 1)
	readerStarted := make(chan struct{})
	go func() {
		close(readerStarted)
		file, err := os.Open(xoviMessageOutput)
		if err != nil {
			resultChannel <- fifoResult{err: codedError{code: "broker_output_open_failed"}}
			return
		}
		defer file.Close()
		data, err := io.ReadAll(io.LimitReader(file, 1025))
		if err != nil {
			resultChannel <- fifoResult{err: codedError{code: "broker_output_read_failed"}}
			return
		}
		if len(data) > 1024 {
			resultChannel <- fifoResult{err: codedError{code: "broker_response_too_large"}}
			return
		}
		resultChannel <- fifoResult{value: string(data)}
	}()
	<-readerStarted

	inputFD, err := syscall.Open(xoviMessageInput, syscall.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		unblockFIFOReader()
		return framebufferConfig{}, codedError{code: "broker_input_open_failed"}
	}
	input := os.NewFile(uintptr(inputFD), xoviMessageInput)
	_, writeErr := io.WriteString(input, framebufferQuery)
	closeErr := input.Close()
	if writeErr != nil || closeErr != nil {
		unblockFIFOReader()
		return framebufferConfig{}, codedError{code: "broker_input_write_failed"}
	}

	select {
	case result := <-resultChannel:
		if result.err != nil {
			return framebufferConfig{}, result.err
		}
		return parseFramebufferConfig(result.value)
	case <-time.After(timeout):
		unblockFIFOReader()
		return framebufferConfig{}, codedError{code: "broker_timeout"}
	}
}

func unblockFIFOReader() {
	fd, err := syscall.Open(xoviMessageOutput, syscall.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err == nil {
		_ = syscall.Close(fd)
	}
}
