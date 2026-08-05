package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/iFixRobots/remarkable-mirror/agent/internal/device"
)

const version = "0.4.8"

func main() {
	signalContext, stopSignals := signal.NotifyContext(
		context.Background(),
		os.Interrupt,
		syscall.SIGHUP,
		syscall.SIGTERM,
	)
	ctx, cancel := context.WithCancel(signalContext)
	if len(os.Args) > 1 && os.Args[1] == "stream" {
		go func() {
			_, _ = io.Copy(io.Discard, os.Stdin)
			cancel()
		}()
	}
	exitCode := run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	cancel()
	stopSignals()
	os.Exit(exitCode)
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 1 && (args[0] == "version" || args[0] == "--version") {
		fmt.Fprintln(stdout, version)
		return 0
	}

	command := "snapshot"
	if len(args) > 0 && (args[0] == "snapshot" || args[0] == "frame" || args[0] == "stream" || args[0] == "input" || args[0] == "input-ready" || args[0] == "input-watchdog" || args[0] == "xovi-activate" || args[0] == "xovi-activation-status") {
		command = args[0]
		args = args[1:]
	}
	if command == "xovi-activate" {
		activationFlags := flag.NewFlagSet("rmmirror-probe xovi-activate", flag.ContinueOnError)
		activationFlags.SetOutput(io.Discard)
		attempt := activationFlags.String("attempt", "", "unique 32-character lowercase hex attempt")
		if err := activationFlags.Parse(args); err != nil || activationFlags.NArg() != 0 || *attempt == "" {
			writeUsage(stderr)
			return 2
		}
		status, err := device.StartXoviActivation(ctx, *attempt)
		if status.Schema != "" {
			if encodeErr := json.NewEncoder(stdout).Encode(status); encodeErr != nil {
				fmt.Fprintln(stderr, "rmmirror-probe: xovi_activation_encode_failed")
				return 2
			}
		}
		if err != nil {
			fmt.Fprintf(stderr, "rmmirror-probe: xovi_activation_%s\n", device.ErrorCode(err))
			return 1
		}
		if strings.HasPrefix(status.Outcome, "failed_") {
			return 1
		}
		return 0
	}
	if command == "xovi-activation-status" {
		if len(args) != 0 {
			writeUsage(stderr)
			return 2
		}
		status, err := device.ReadXoviActivationStatus()
		if err != nil {
			fmt.Fprintf(stderr, "rmmirror-probe: xovi_activation_status_%s\n", device.ErrorCode(err))
			return 1
		}
		if err := json.NewEncoder(stdout).Encode(status); err != nil {
			fmt.Fprintln(stderr, "rmmirror-probe: xovi_activation_status_encode_failed")
			return 2
		}
		return 0
	}

	flags := flag.NewFlagSet("rmmirror-probe", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	pretty := flags.Bool("pretty", false, "indent JSON output")
	frameFormat := flags.String("format", "bgra", "frame output: bgra or png")
	streamInterval := flags.Duration("interval", 40*time.Millisecond, "stream polling interval")
	markerPath := flags.String("marker", device.DefaultMarkerPath, "physical marker event device")
	inputLock := flags.String("lock", device.DefaultInputLockPath, "input session lock")
	heartbeatTimeout := flags.Duration("heartbeat-timeout", device.DefaultInputHeartbeatTimeout, "input heartbeat timeout")
	restoreTimeout := flags.Duration("restore-timeout", 50*time.Second, "physical input restoration timeout")
	filesFallback := flags.Bool("files-fallback", false, "enable the session-owned stock Files fallback")
	filesFallbackOwned := flags.Bool("files-fallback-owned", false, "clean a fallback address owned by the parent input session")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		writeUsage(stderr)
		return 2
	}

	if command == "frame" {
		if *pretty {
			writeUsage(stderr)
			return 2
		}
		if err := device.WriteVisibleFrame(stdout, *frameFormat); err != nil {
			fmt.Fprintf(stderr, "rmmirror-probe: frame_%s\n", device.ErrorCode(err))
			return 1
		}
		return 0
	}
	if command == "stream" {
		if *pretty || *frameFormat != "bgra" {
			writeUsage(stderr)
			return 2
		}
		if err := device.StreamFrames(ctx, stdout, *streamInterval); err != nil {
			fmt.Fprintf(stderr, "rmmirror-probe: stream_%s\n", device.ErrorCode(err))
			return 1
		}
		return 0
	}
	if command == "input" {
		if *pretty || *frameFormat != "bgra" || *filesFallbackOwned {
			writeUsage(stderr)
			return 2
		}
		if err := device.ServeInput(
			ctx,
			*markerPath,
			*heartbeatTimeout,
			*filesFallback,
			os.Stdin,
			stdout,
		); err != nil {
			fmt.Fprintf(stderr, "rmmirror-probe: input_%s\n", device.ErrorCode(err))
			return 1
		}
		return 0
	}
	if command == "input-ready" {
		if *pretty || *frameFormat != "bgra" || *restoreTimeout <= 0 || *restoreTimeout > 2*time.Minute {
			writeUsage(stderr)
			return 2
		}
		if err := device.WaitForPhysicalInputRestored(*markerPath, *restoreTimeout); err != nil {
			fmt.Fprintf(stderr, "rmmirror-probe: input_ready_%s\n", device.ErrorCode(err))
			return 1
		}
		return 0
	}
	if command == "input-watchdog" {
		if *pretty || *frameFormat != "bgra" || *filesFallback {
			writeUsage(stderr)
			return 2
		}
		if err := device.RunInputWatchdog(
			*markerPath,
			*inputLock,
			*filesFallbackOwned,
		); err != nil {
			fmt.Fprintf(stderr, "rmmirror-probe: input_watchdog_%s\n", device.ErrorCode(err))
			return 1
		}
		return 0
	}
	if *frameFormat != "bgra" {
		writeUsage(stderr)
		return 2
	}

	snapshot := device.CaptureCapabilities()
	encoder := json.NewEncoder(stdout)
	encoder.SetEscapeHTML(false)
	if *pretty {
		encoder.SetIndent("", "  ")
	}
	if err := encoder.Encode(snapshot); err != nil {
		fmt.Fprintln(stderr, "rmmirror-probe: encode_failed")
		return 2
	}
	if snapshot.Status == "complete" {
		return 0
	}
	return 1
}

func writeUsage(writer io.Writer) {
	fmt.Fprintln(writer, "usage: rmmirror-probe [snapshot] [--pretty]")
	fmt.Fprintln(writer, "       rmmirror-probe frame [--format bgra|png]")
	fmt.Fprintln(writer, "       rmmirror-probe stream [--interval 40ms]")
	fmt.Fprintln(writer, "       rmmirror-probe input [--marker /dev/input/event2] [--heartbeat-timeout 15s] [--files-fallback]")
	fmt.Fprintln(writer, "       rmmirror-probe input-ready [--marker /dev/input/event2] [--restore-timeout 50s]")
	fmt.Fprintln(writer, "       rmmirror-probe xovi-activate --attempt <32hex>")
	fmt.Fprintln(writer, "       rmmirror-probe xovi-activation-status")
	fmt.Fprintln(writer, "       rmmirror-probe version")
}
