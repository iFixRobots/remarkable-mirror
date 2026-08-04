package device

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"reflect"
	"testing"
	"time"
)

type recordingInputBackend struct {
	events     []string
	resetCount int
	closeCount int
	resetErr   error
}

type keyReleaseFailingBackend struct {
	recordingInputBackend
}

func (backend *keyReleaseFailingBackend) Key(action string, code int) error {
	backend.events = append(backend.events, fmt.Sprintf("key:%s:%d", action, code))
	if action == "up" {
		return errors.New("release failed")
	}
	return nil
}

func (backend *recordingInputBackend) Touch(action string, x, y, pressure int) error {
	backend.events = append(backend.events, fmt.Sprintf("touch:%s:%d:%d:%d", action, x, y, pressure))
	return nil
}

func (backend *recordingInputBackend) Pen(action string, x, y, pressure int, tool string) error {
	backend.events = append(backend.events, fmt.Sprintf("pen:%s:%d:%d:%d:%s", action, x, y, pressure, tool))
	return nil
}

func (backend *recordingInputBackend) Key(action string, code int) error {
	backend.events = append(backend.events, fmt.Sprintf("key:%s:%d", action, code))
	return nil
}

func (backend *recordingInputBackend) Reset() error {
	backend.resetCount++
	return backend.resetErr
}

func (backend *recordingInputBackend) Close() error {
	backend.closeCount++
	return nil
}

func TestServeInputSessionResetsWithoutClosingBackend(t *testing.T) {
	backend := &recordingInputBackend{}
	commands := "" +
		`{"id":1,"type":"touch","action":"down","x":0.25,"y":0.75}` + "\n" +
		`{"id":2,"type":"key","action":"down","key":"A"}` + "\n"
	var output bytes.Buffer

	if err := serveInputSession(bytes.NewBufferString(commands), &output, backend); err != nil {
		t.Fatalf("serveInputSession returned %v", err)
	}
	if backend.resetCount != 1 {
		t.Fatalf("reset count = %d, want 1", backend.resetCount)
	}
	if backend.closeCount != 0 {
		t.Fatalf("close count = %d, want 0", backend.closeCount)
	}
	wantEvents := []string{
		"touch:down:312:1656:255",
		"key:down:30",
	}
	if !reflect.DeepEqual(backend.events, wantEvents) {
		t.Fatalf("events = %#v, want %#v", backend.events, wantEvents)
	}

	decoder := json.NewDecoder(&output)
	var ready inputResponse
	if err := decoder.Decode(&ready); err != nil {
		t.Fatalf("decode ready response: %v", err)
	}
	if !ready.Ready || ready.Schema != inputSchema {
		t.Fatalf("ready response = %#v", ready)
	}
	for id := uint64(1); id <= 2; id++ {
		var response inputResponse
		if err := decoder.Decode(&response); err != nil {
			t.Fatalf("decode response %d: %v", id, err)
		}
		if response.ID != id || !response.OK || response.Error != "" {
			t.Fatalf("response %d = %#v", id, response)
		}
	}

	var secondOutput bytes.Buffer
	if err := serveInputSession(bytes.NewBufferString(`{"id":3,"type":"ping"}`+"\n"), &secondOutput, backend); err != nil {
		t.Fatalf("second serveInputSession returned %v", err)
	}
	if backend.resetCount != 2 || backend.closeCount != 0 {
		t.Fatalf("after reconnect reset count = %d and close count = %d, want 2 and 0", backend.resetCount, backend.closeCount)
	}
}

func TestInputReadyReportsUnavailableFilesAndStillAcceptsCommands(t *testing.T) {
	backend := &recordingInputBackend{}
	var output bytes.Buffer
	err := serveInputSessionWithStartupState(
		context.Background(),
		0,
		bytes.NewBufferString(`{"id":7,"type":"ping"}`+"\n"),
		&output,
		backend,
		"unknown",
		filesStateUnavailable,
	)
	if err != nil {
		t.Fatalf("serveInputSessionWithStartupState returned %v", err)
	}

	decoder := json.NewDecoder(&output)
	var ready inputResponse
	if err := decoder.Decode(&ready); err != nil {
		t.Fatalf("decode ready response: %v", err)
	}
	if !ready.Ready || ready.FilesState != filesStateUnavailable {
		t.Fatalf("ready response = %#v", ready)
	}
	var response inputResponse
	if err := decoder.Decode(&response); err != nil {
		t.Fatalf("decode ping response: %v", err)
	}
	if response.ID != 7 || !response.OK || response.Error != "" {
		t.Fatalf("ping response = %#v", response)
	}
}

func TestServeInputSessionReportsResetFailure(t *testing.T) {
	backend := &recordingInputBackend{resetErr: errors.New("reset failed")}
	var output bytes.Buffer

	err := serveInputSession(bytes.NewBufferString(""), &output, backend)
	if ErrorCode(err) != "input_reset_failed" {
		t.Fatalf("ErrorCode(%v) = %q, want input_reset_failed", err, ErrorCode(err))
	}
}

func TestKeyClickEmitsDownAndUpInsideOneCommand(t *testing.T) {
	backend := &recordingInputBackend{}
	err := executeInputCommand(backend, inputCommand{
		ID: 1, Type: "key", Action: "click", Key: "KEY_POWER",
	})
	if err != nil {
		t.Fatalf("executeInputCommand returned %v", err)
	}
	want := []string{"key:down:116", "key:up:116"}
	if !reflect.DeepEqual(backend.events, want) {
		t.Fatalf("events = %#v, want %#v", backend.events, want)
	}
}

func TestKeyClickResetsBackendWhenReleaseFails(t *testing.T) {
	backend := &keyReleaseFailingBackend{}
	err := executeInputCommand(backend, inputCommand{
		ID: 1, Type: "key", Action: "click", Key: "KEY_POWER",
	})
	if err == nil {
		t.Fatal("executeInputCommand unexpectedly succeeded")
	}
	if backend.resetCount != 1 {
		t.Fatalf("reset count = %d, want 1", backend.resetCount)
	}
}

func TestServeInputSessionHeartbeatTimeoutResetsAndClosesReader(t *testing.T) {
	backend := &recordingInputBackend{}
	reader, writer := io.Pipe()
	defer writer.Close()
	var output bytes.Buffer

	err := serveInputSessionWithLease(
		context.Background(),
		25*time.Millisecond,
		reader,
		&output,
		backend,
	)
	if ErrorCode(err) != "heartbeat_timeout" {
		t.Fatalf("ErrorCode(%v) = %q, want heartbeat_timeout", err, ErrorCode(err))
	}
	if backend.resetCount != 1 {
		t.Fatalf("reset count = %d, want 1", backend.resetCount)
	}
	if _, err := writer.Write([]byte("late")); !errors.Is(err, io.ErrClosedPipe) {
		t.Fatalf("late writer error = %v, want io.ErrClosedPipe", err)
	}
}

func TestServeInputSessionCancellationIsClean(t *testing.T) {
	backend := &recordingInputBackend{}
	reader, writer := io.Pipe()
	defer writer.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if err := serveInputSessionWithLease(ctx, time.Second, reader, io.Discard, backend); err != nil {
		t.Fatalf("serveInputSessionWithLease returned %v", err)
	}
	if backend.resetCount != 1 {
		t.Fatalf("reset count = %d, want 1", backend.resetCount)
	}
}

func TestRelayMarkerFramesPreservesCompleteRawFrames(t *testing.T) {
	first := append(rawInputEvent(10, 20, 0x03, 0x00, 111), rawInputEvent(10, 21, 0x00, 0x00, 0)...)
	second := append(rawInputEvent(11, 22, 0x01, 0x14a, 1), rawInputEvent(11, 23, 0x00, 0x00, 0)...)
	stream := append(append([]byte{}, first...), second...)
	var frames [][]byte

	err := relayMarkerFrames(bytes.NewReader(stream), func(frame []byte) error {
		frames = append(frames, append([]byte{}, frame...))
		return nil
	})
	if ErrorCode(err) != "marker_read_failed" {
		t.Fatalf("ErrorCode(%v) = %q, want marker_read_failed at EOF", err, ErrorCode(err))
	}
	want := [][]byte{first, second}
	if !reflect.DeepEqual(frames, want) {
		t.Fatalf("frames did not preserve the raw input_event bytes")
	}
}

func TestRelayMarkerFramesCodesVirtualPenWriteFailure(t *testing.T) {
	frame := rawInputEvent(1, 2, 0x00, 0x00, 0)
	err := relayMarkerFrames(bytes.NewReader(frame), func([]byte) error {
		return errors.New("write failed")
	})
	if ErrorCode(err) != "marker_frame_write_failed" {
		t.Fatalf("ErrorCode(%v) = %q, want marker_frame_write_failed", err, ErrorCode(err))
	}
}

func rawInputEvent(seconds, microseconds uint64, eventType, code uint16, value int32) []byte {
	event := make([]byte, inputEventBytes)
	binary.LittleEndian.PutUint64(event[0:8], seconds)
	binary.LittleEndian.PutUint64(event[8:16], microseconds)
	binary.LittleEndian.PutUint16(event[16:18], eventType)
	binary.LittleEndian.PutUint16(event[18:20], code)
	binary.LittleEndian.PutUint32(event[20:24], uint32(value))
	return event
}
