package transportwake

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	WakeSchema                = "rmmirror.wake/v1"
	DefaultWakeLoopbackListen = "127.0.0.1:51337"
	DefaultWakeUSBListen      = "10.11.99.1:51337"
	DefaultWakeTokenPath      = "/data/rmmirror/wake-token"
	defaultMaxHeaderBytes     = 4 << 10
	defaultMaxRequests        = 8
	defaultWakeSuppression    = 3 * time.Second
)

type WakeEndpointConfig struct {
	ListenAddresses []string
	TokenPath       string
	RequestTimeout  time.Duration
	ReadTimeout     time.Duration
	WriteTimeout    time.Duration
	IdleTimeout     time.Duration
	MaxHeaderBytes  int
}

func DefaultWakeEndpointConfig() WakeEndpointConfig {
	return WakeEndpointConfig{
		ListenAddresses: []string{DefaultWakeLoopbackListen, DefaultWakeUSBListen},
		TokenPath:       DefaultWakeTokenPath,
		RequestTimeout:  2 * time.Second,
		ReadTimeout:     3 * time.Second,
		WriteTimeout:    3 * time.Second,
		IdleTimeout:     5 * time.Second,
		MaxHeaderBytes:  defaultMaxHeaderBytes,
	}
}

func (config WakeEndpointConfig) Validate() error {
	if len(config.ListenAddresses) == 0 {
		return errors.New("wake listen addresses must not be empty")
	}
	seen := make(map[string]struct{}, len(config.ListenAddresses))
	for _, address := range config.ListenAddresses {
		if address == "" || strings.TrimSpace(address) != address {
			return errors.New("wake listen address is invalid")
		}
		host, port, err := net.SplitHostPort(address)
		if err != nil || (host != "127.0.0.1" && host != "10.11.99.1") {
			return errors.New("wake listen address must use tablet loopback or direct USB")
		}
		portNumber, err := strconv.Atoi(port)
		if err != nil || portNumber < 0 || portNumber > 65535 {
			return errors.New("wake listen address port is invalid")
		}
		canonicalAddress := net.JoinHostPort(host, strconv.Itoa(portNumber))
		if _, exists := seen[canonicalAddress]; exists {
			return errors.New("wake listen addresses must be unique")
		}
		seen[canonicalAddress] = struct{}{}
	}
	if !path.IsAbs(config.TokenPath) && !filepath.IsAbs(config.TokenPath) {
		return errors.New("wake token path must be absolute")
	}
	if config.RequestTimeout <= 0 || config.ReadTimeout <= 0 ||
		config.WriteTimeout <= 0 || config.IdleTimeout <= 0 {
		return errors.New("wake endpoint timeouts must be positive")
	}
	if config.MaxHeaderBytes <= 0 || config.MaxHeaderBytes > 64<<10 {
		return errors.New("wake endpoint header limit is invalid")
	}
	return nil
}

type displayState uint8

const (
	displayUnknown displayState = iota
	displayNormal
	displayDeepSleep
)

type tabletObservation struct {
	HomeKnown    bool
	HomeMounted  bool
	DisplayState displayState
	// Xochitl's journal is buffered, so its latest transition is useful for
	// diagnostics but cannot safely authorize a power-key toggle. A future
	// direct state source must opt in explicitly.
	DisplayAuthoritative bool
}

type tabletInspector interface {
	Inspect(context.Context) (tabletObservation, error)
}

type powerWaker interface {
	Wake(context.Context) error
}

type WakeStatus struct {
	Schema   string `json:"schema"`
	State    string `json:"state,omitempty"`
	WakeSent bool   `json:"wake_sent,omitempty"`
	Error    string `json:"error,omitempty"`
}

type WakeEndpoint struct {
	config  WakeEndpointConfig
	handler http.Handler
	healthy atomic.Bool
}

func NewWakeEndpoint(config WakeEndpointConfig) (*WakeEndpoint, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}
	token, err := loadWakeToken(config.TokenPath)
	if err != nil {
		return nil, err
	}
	return newWakeEndpoint(
		config,
		token,
		newOSTabletInspector(),
		newTransientPowerWaker(newPowerDeviceFactory(), 350*time.Millisecond, 20*time.Millisecond),
	), nil
}

func newWakeEndpoint(
	config WakeEndpointConfig,
	token string,
	inspector tabletInspector,
	waker powerWaker,
) *WakeEndpoint {
	return &WakeEndpoint{
		config: config,
		handler: newWakeHandler(
			token,
			inspector,
			waker,
			config.RequestTimeout,
			time.Now,
		),
	}
}

func (endpoint *WakeEndpoint) Run(ctx context.Context) error {
	listenConfig := net.ListenConfig{KeepAlive: endpoint.config.IdleTimeout}
	listeners := make([]net.Listener, 0, len(endpoint.config.ListenAddresses))
	for _, listenAddress := range endpoint.config.ListenAddresses {
		listener, err := listenConfig.Listen(ctx, "tcp4", listenAddress)
		if err != nil {
			for _, boundListener := range listeners {
				_ = boundListener.Close()
			}
			return fmt.Errorf("listen for wake requests on %s: %w", listenAddress, err)
		}
		listeners = append(listeners, listener)
	}
	endpoint.healthy.Store(true)
	defer endpoint.healthy.Store(false)

	server := &http.Server{
		Handler:           endpoint.handler,
		ReadTimeout:       endpoint.config.ReadTimeout,
		ReadHeaderTimeout: endpoint.config.ReadTimeout,
		WriteTimeout:      endpoint.config.WriteTimeout,
		IdleTimeout:       endpoint.config.IdleTimeout,
		MaxHeaderBytes:    endpoint.config.MaxHeaderBytes,
		ErrorLog:          log.New(io.Discard, "", 0),
	}
	shutdownDone := make(chan struct{})
	stopShutdown := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		select {
		case <-ctx.Done():
			shutdownContext, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			_ = server.Shutdown(shutdownContext)
		case <-stopShutdown:
		}
	}()

	serveResults := make(chan error, len(listeners))
	for _, listener := range listeners {
		go func(listener net.Listener) {
			serveResults <- server.Serve(listener)
		}(listener)
	}
	var serveErr error
	for range listeners {
		result := <-serveResults
		if errors.Is(result, http.ErrServerClosed) {
			continue
		}
		if result == nil {
			result = errors.New("listener stopped unexpectedly")
		}
		serveErr = errors.Join(serveErr, result)
		_ = server.Close()
	}
	if ctx.Err() != nil {
		<-shutdownDone
		return nil
	}
	close(stopShutdown)
	<-shutdownDone
	return serveErr
}

func (endpoint *WakeEndpoint) Healthy() bool {
	return endpoint.healthy.Load()
}

type wakeHandler struct {
	tokenHash       [sha256.Size]byte
	inspector       tabletInspector
	waker           powerWaker
	requestTimeout  time.Duration
	now             func() time.Time
	requestSlots    chan struct{}
	wakeMu          sync.Mutex
	lastWake        time.Time
	wakeSuppression time.Duration
}

func newWakeHandler(
	token string,
	inspector tabletInspector,
	waker powerWaker,
	requestTimeout time.Duration,
	now func() time.Time,
) *wakeHandler {
	return &wakeHandler{
		tokenHash:       sha256.Sum256([]byte(token)),
		inspector:       inspector,
		waker:           waker,
		requestTimeout:  requestTimeout,
		now:             now,
		requestSlots:    make(chan struct{}, defaultMaxRequests),
		wakeSuppression: defaultWakeSuppression,
	}
}

func (handler *wakeHandler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	select {
	case handler.requestSlots <- struct{}{}:
		defer func() { <-handler.requestSlots }()
	default:
		writeWakeJSON(writer, http.StatusServiceUnavailable, WakeStatus{Schema: WakeSchema, Error: "busy"})
		return
	}

	if !handler.authenticate(request.Header.Get("Authorization")) {
		writer.Header().Set("WWW-Authenticate", "Bearer")
		writeWakeJSON(writer, http.StatusUnauthorized, WakeStatus{Schema: WakeSchema, Error: "unauthorized"})
		return
	}
	if request.URL.RawQuery != "" {
		writeWakeJSON(writer, http.StatusBadRequest, WakeStatus{Schema: WakeSchema, Error: "invalid_request"})
		return
	}
	if request.URL.Path != "/v1/status" && request.URL.Path != "/v1/wake" {
		writeWakeJSON(writer, http.StatusNotFound, WakeStatus{Schema: WakeSchema, Error: "not_found"})
		return
	}
	if request.URL.Path == "/v1/status" && request.Method != http.MethodGet {
		writer.Header().Set("Allow", http.MethodGet)
		writeWakeJSON(writer, http.StatusMethodNotAllowed, WakeStatus{Schema: WakeSchema, Error: "method_not_allowed"})
		return
	}
	if request.URL.Path == "/v1/wake" && request.Method != http.MethodPost {
		writer.Header().Set("Allow", http.MethodPost)
		writeWakeJSON(writer, http.StatusMethodNotAllowed, WakeStatus{Schema: WakeSchema, Error: "method_not_allowed"})
		return
	}
	if !emptyRequestBody(writer, request) {
		writeWakeJSON(writer, http.StatusRequestEntityTooLarge, WakeStatus{Schema: WakeSchema, Error: "body_not_allowed"})
		return
	}

	requestContext, cancel := context.WithTimeout(request.Context(), handler.requestTimeout)
	defer cancel()
	if request.URL.Path == "/v1/status" {
		observation, _ := handler.inspector.Inspect(requestContext)
		writeWakeJSON(writer, http.StatusOK, WakeStatus{Schema: WakeSchema, State: observationState(observation)})
		return
	}

	handler.wakeMu.Lock()
	defer handler.wakeMu.Unlock()
	observation, _ := handler.inspector.Inspect(requestContext)
	response := WakeStatus{Schema: WakeSchema, State: observationState(observation)}
	if !observation.DisplayAuthoritative ||
		observation.DisplayState != displayDeepSleep ||
		handler.wakeSuppressed(handler.now()) {
		writeWakeJSON(writer, http.StatusOK, response)
		return
	}
	if err := handler.waker.Wake(requestContext); err != nil {
		response.Error = "wake_failed"
		writeWakeJSON(writer, http.StatusServiceUnavailable, response)
		return
	}
	handler.lastWake = handler.now()
	response.WakeSent = true
	writeWakeJSON(writer, http.StatusOK, response)
}

func (handler *wakeHandler) authenticate(header string) bool {
	parts := strings.Fields(header)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return false
	}
	presented := sha256.Sum256([]byte(parts[1]))
	return subtle.ConstantTimeCompare(presented[:], handler.tokenHash[:]) == 1
}

func (handler *wakeHandler) wakeSuppressed(now time.Time) bool {
	return !handler.lastWake.IsZero() && now.Sub(handler.lastWake) >= 0 &&
		now.Sub(handler.lastWake) < handler.wakeSuppression
}

func observationState(observation tabletObservation) string {
	if observation.HomeKnown && !observation.HomeMounted {
		return "unlock_required"
	}
	if observation.DisplayAuthoritative && observation.DisplayState == displayDeepSleep {
		return "sleeping"
	}
	if observation.HomeKnown && observation.HomeMounted &&
		observation.DisplayAuthoritative && observation.DisplayState == displayNormal {
		return "ready"
	}
	return "starting"
}

func emptyRequestBody(writer http.ResponseWriter, request *http.Request) bool {
	if request.Body == nil {
		return true
	}
	limited := http.MaxBytesReader(writer, request.Body, 0)
	_, err := io.Copy(io.Discard, limited)
	return err == nil
}

func writeWakeJSON(writer http.ResponseWriter, statusCode int, response WakeStatus) {
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(statusCode)
	_ = json.NewEncoder(writer).Encode(response)
}

func loadWakeToken(tokenPath string) (string, error) {
	info, err := os.Lstat(tokenPath)
	if err != nil {
		return "", fmt.Errorf("load wake token: token file is unavailable: %w", err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		return "", errors.New("load wake token: token file must be a regular file with mode 0600")
	}
	payload, err := os.ReadFile(tokenPath)
	if err != nil {
		return "", fmt.Errorf("load wake token: token file is unreadable: %w", err)
	}
	if len(payload) != 64 {
		return "", errors.New("load wake token: token file has an invalid format")
	}
	decoded := make([]byte, 32)
	if _, err := hex.Decode(decoded, payload); err != nil {
		return "", errors.New("load wake token: token file has an invalid format")
	}
	return string(payload), nil
}
