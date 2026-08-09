package transportwake

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type fakeTabletInspector struct {
	observation tabletObservation
	err         error
	calls       int
}

func (inspector *fakeTabletInspector) Inspect(context.Context) (tabletObservation, error) {
	inspector.calls++
	return inspector.observation, inspector.err
}

type fakePowerWaker struct {
	err   error
	calls int
}

func (waker *fakePowerWaker) Wake(context.Context) error {
	waker.calls++
	return waker.err
}

func TestWakeEndpointHealthTracksListenerLifecycle(t *testing.T) {
	listenAddresses := reserveLoopbackAddresses(t, 2)
	config := DefaultWakeEndpointConfig()
	config.ListenAddresses = listenAddresses
	endpoint := newWakeEndpoint(config, "token", &fakeTabletInspector{}, &fakePowerWaker{})
	if endpoint.Healthy() {
		t.Fatal("endpoint reported healthy before binding")
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- endpoint.Run(ctx)
	}()

	deadline := time.Now().Add(time.Second)
	for !endpoint.Healthy() && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !endpoint.Healthy() {
		cancel()
		<-done
		t.Fatal("endpoint did not report healthy after binding")
	}
	for _, listenAddress := range listenAddresses {
		request, err := http.NewRequest(http.MethodGet, "http://"+listenAddress+"/v1/status", nil)
		if err != nil {
			t.Fatalf("create request for %s: %v", listenAddress, err)
		}
		response, err := (&http.Client{Timeout: time.Second}).Do(request)
		if err != nil {
			t.Fatalf("request listener %s: %v", listenAddress, err)
		}
		_ = response.Body.Close()
		if response.StatusCode != http.StatusUnauthorized {
			t.Fatalf("listener %s status = %d, want %d", listenAddress, response.StatusCode, http.StatusUnauthorized)
		}
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Run returned %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("endpoint did not stop after cancellation")
	}
	if endpoint.Healthy() {
		t.Fatal("endpoint remained healthy after shutdown")
	}
}

func TestWakeEndpointBindFailureNeverReportsHealthy(t *testing.T) {
	listenAddresses := reserveLoopbackAddresses(t, 2)
	listener, err := net.Listen("tcp4", listenAddresses[1])
	if err != nil {
		t.Fatalf("reserve listen address: %v", err)
	}
	defer listener.Close()

	config := DefaultWakeEndpointConfig()
	config.ListenAddresses = listenAddresses
	endpoint := newWakeEndpoint(config, "token", &fakeTabletInspector{}, &fakePowerWaker{})
	err = endpoint.Run(context.Background())
	if err == nil || !strings.Contains(err.Error(), "listen for wake requests") {
		t.Fatalf("Run error = %v, want listen failure", err)
	}
	if endpoint.Healthy() {
		t.Fatal("endpoint reported healthy after bind failure")
	}
	rebound, err := net.Listen("tcp4", listenAddresses[0])
	if err != nil {
		t.Fatalf("first listener remained open after second bind failed: %v", err)
	}
	_ = rebound.Close()
}

func TestDefaultWakeEndpointListenersExcludeLan(t *testing.T) {
	config := DefaultWakeEndpointConfig()
	want := []string{"127.0.0.1:51337", "10.11.99.1:51337"}
	if strings.Join(config.ListenAddresses, "|") != strings.Join(want, "|") {
		t.Fatalf("default listeners = %q, want %q", config.ListenAddresses, want)
	}
	if err := config.Validate(); err != nil {
		t.Fatalf("default config validation: %v", err)
	}
}

func TestWakeEndpointConfigRejectsListenerOutsideLoopbackAndDirectUSB(t *testing.T) {
	tests := []struct {
		name      string
		addresses []string
	}{
		{name: "no listeners"},
		{name: "wildcard", addresses: []string{"0.0.0.0:51337"}},
		{name: "wifi address", addresses: []string{"192.0.2.10:51337"}},
		{name: "hostname", addresses: []string{"localhost:51337"}},
		{name: "ipv6 loopback", addresses: []string{"[::1]:51337"}},
		{name: "duplicate", addresses: []string{"127.0.0.1:51337", "127.0.0.1:51337"}},
		{name: "missing port", addresses: []string{"127.0.0.1"}},
		{name: "invalid port", addresses: []string{"127.0.0.1:not-a-port"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			config := DefaultWakeEndpointConfig()
			config.ListenAddresses = test.addresses
			if err := config.Validate(); err == nil {
				t.Fatalf("Validate accepted listeners %q", test.addresses)
			}
		})
	}
}

func reserveLoopbackAddresses(t *testing.T, count int) []string {
	t.Helper()
	listeners := make([]net.Listener, 0, count)
	addresses := make([]string, 0, count)
	for range count {
		listener, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			for _, existing := range listeners {
				_ = existing.Close()
			}
			t.Fatalf("reserve loopback address: %v", err)
		}
		listeners = append(listeners, listener)
		addresses = append(addresses, listener.Addr().String())
	}
	for _, listener := range listeners {
		if err := listener.Close(); err != nil {
			t.Fatalf("release loopback address: %v", err)
		}
	}
	return addresses
}

func TestObservationStateUsesUnlockDisplayAndHomeSignals(t *testing.T) {
	tests := []struct {
		name        string
		observation tabletObservation
		want        string
	}{
		{
			name: "encrypted home is not mounted",
			observation: tabletObservation{
				HomeKnown: true, DisplayState: displayDeepSleep, DisplayAuthoritative: true,
			},
			want: "unlock_required",
		},
		{
			name: "current invocation is sleeping",
			observation: tabletObservation{
				HomeKnown: true, HomeMounted: true, DisplayState: displayDeepSleep,
				DisplayAuthoritative: true,
			},
			want: "sleeping",
		},
		{
			name: "home and current display are ready",
			observation: tabletObservation{
				HomeKnown: true, HomeMounted: true, DisplayState: displayNormal,
				DisplayAuthoritative: true,
			},
			want: "ready",
		},
		{
			name:        "display state is not yet reported",
			observation: tabletObservation{HomeKnown: true, HomeMounted: true},
			want:        "starting",
		},
		{
			name:        "home inspection failed",
			observation: tabletObservation{DisplayState: displayNormal},
			want:        "starting",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := observationState(test.observation); got != test.want {
				t.Fatalf("observationState(%#v) = %q, want %q", test.observation, got, test.want)
			}
		})
	}
}

func TestWakeHandlerRequiresBearerTokenBeforeInspection(t *testing.T) {
	inspector := &fakeTabletInspector{}
	waker := &fakePowerWaker{}
	handler := newWakeHandler("correct-token", inspector, waker, time.Second, time.Now)
	request := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	request.Header.Set("Authorization", "Bearer wrong-token")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusUnauthorized)
	}
	if inspector.calls != 0 || waker.calls != 0 {
		t.Fatalf("unauthorized request reached device: inspector=%d waker=%d", inspector.calls, waker.calls)
	}
	if strings.Contains(recorder.Body.String(), "wrong-token") || strings.Contains(recorder.Body.String(), "correct-token") {
		t.Fatalf("response leaked a token: %q", recorder.Body.String())
	}
}

func TestWakeHandlerAllowsTokenlessDirectCableRecoveryStatusAndWake(t *testing.T) {
	inspector := &fakeTabletInspector{
		observation: tabletObservation{
			HomeKnown: true, HomeMounted: true, DisplayState: displayDeepSleep,
			DisplayAuthoritative: true,
		},
	}
	waker := &fakePowerWaker{}
	handler := newWakeHandler("token", inspector, waker, time.Second, time.Now)

	for _, peer := range []string{"10.11.99.2:49152", "10.11.99.30:49152"} {
		status := requestAt(
			handler,
			http.MethodGet,
			"/v1/status",
			nil,
			DefaultWakeUSBListen,
			peer,
			nil,
		)
		statusResponse := decodeWakeResponse(t, status)
		if status.Code != http.StatusOK || statusResponse.State != "sleeping" || statusResponse.WakeSent {
			t.Fatalf("peer %s status response = (%d, %#v)", peer, status.Code, statusResponse)
		}
	}

	wake := requestAt(
		handler,
		http.MethodPost,
		"/v1/wake",
		nil,
		DefaultWakeUSBListen,
		"10.11.99.11:49153",
		nil,
	)
	wakeResponse := decodeWakeResponse(t, wake)
	if wake.Code != http.StatusOK || wakeResponse.State != "sleeping" || !wakeResponse.WakeSent {
		t.Fatalf("wake response = (%d, %#v)", wake.Code, wakeResponse)
	}
	if inspector.calls != 3 || waker.calls != 1 {
		t.Fatalf("recovery calls: inspector=%d waker=%d", inspector.calls, waker.calls)
	}
}

func TestWakeHandlerTokenlessRecoveryRequiresExactDirectCableEndpoints(t *testing.T) {
	tests := []struct {
		name   string
		local  string
		remote string
	}{
		{name: "loopback listener", local: DefaultWakeLoopbackListen, remote: "127.0.0.1:49152"},
		{name: "wrong local address", local: "10.11.99.2:51337", remote: "10.11.99.11:49152"},
		{name: "wrong local port", local: "10.11.99.1:51338", remote: "10.11.99.11:49152"},
		{name: "network address", local: DefaultWakeUSBListen, remote: "10.11.99.0:49152"},
		{name: "tablet address", local: DefaultWakeUSBListen, remote: "10.11.99.1:49152"},
		{name: "broadcast address", local: DefaultWakeUSBListen, remote: "10.11.99.31:49152"},
		{name: "outside cable subnet", local: DefaultWakeUSBListen, remote: "10.11.99.32:49152"},
		{name: "loopback peer", local: DefaultWakeUSBListen, remote: "127.0.0.1:49152"},
		{name: "ipv6 peer", local: DefaultWakeUSBListen, remote: "[::1]:49152"},
		{name: "invalid peer", local: DefaultWakeUSBListen, remote: "not-an-endpoint"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			inspector := &fakeTabletInspector{}
			waker := &fakePowerWaker{}
			handler := newWakeHandler("token", inspector, waker, time.Second, time.Now)
			recorder := requestAt(
				handler,
				http.MethodGet,
				"/v1/status",
				nil,
				test.local,
				test.remote,
				nil,
			)
			if recorder.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want %d", recorder.Code, http.StatusUnauthorized)
			}
			if inspector.calls != 0 || waker.calls != 0 {
				t.Fatalf("rejected recovery reached device: inspector=%d waker=%d", inspector.calls, waker.calls)
			}
		})
	}
}

func TestWakeHandlerTokenlessRecoveryNeverDowngradesPresentAuthorization(t *testing.T) {
	tests := []struct {
		name   string
		values []string
	}{
		{name: "empty", values: []string{""}},
		{name: "malformed bearer", values: []string{"Bearer"}},
		{name: "wrong bearer", values: []string{"Bearer wrong-token"}},
		{name: "wrong scheme", values: []string{"Basic credential"}},
		{name: "repeated", values: []string{"Bearer correct-token", "Bearer wrong-token"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			inspector := &fakeTabletInspector{}
			waker := &fakePowerWaker{}
			handler := newWakeHandler("correct-token", inspector, waker, time.Second, time.Now)
			recorder := requestAt(
				handler,
				http.MethodGet,
				"/v1/status",
				nil,
				DefaultWakeUSBListen,
				"10.11.99.11:49152",
				test.values,
			)
			if recorder.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want %d", recorder.Code, http.StatusUnauthorized)
			}
			if inspector.calls != 0 || waker.calls != 0 {
				t.Fatalf("wrong bearer reached device: inspector=%d waker=%d", inspector.calls, waker.calls)
			}
		})
	}
}

func TestWakeHandlerTokenlessRecoveryAllowsOnlyBoundedOperations(t *testing.T) {
	tests := []struct {
		name   string
		method string
		path   string
		body   []byte
		status int
	}{
		{name: "wrong status method", method: http.MethodPost, path: "/v1/status", status: http.StatusUnauthorized},
		{name: "wrong wake method", method: http.MethodGet, path: "/v1/wake", status: http.StatusUnauthorized},
		{name: "unknown path", method: http.MethodGet, path: "/v1/missing", status: http.StatusUnauthorized},
		{name: "query", method: http.MethodGet, path: "/v1/status?extra=1", status: http.StatusBadRequest},
		{name: "body", method: http.MethodPost, path: "/v1/wake", body: []byte("x"), status: http.StatusRequestEntityTooLarge},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			inspector := &fakeTabletInspector{}
			waker := &fakePowerWaker{}
			handler := newWakeHandler("token", inspector, waker, time.Second, time.Now)
			recorder := requestAt(
				handler,
				test.method,
				test.path,
				test.body,
				DefaultWakeUSBListen,
				"10.11.99.11:49152",
				nil,
			)
			if recorder.Code != test.status {
				t.Fatalf("status = %d, want %d", recorder.Code, test.status)
			}
			if inspector.calls != 0 || waker.calls != 0 {
				t.Fatalf("invalid recovery reached device: inspector=%d waker=%d", inspector.calls, waker.calls)
			}
		})
	}
}

func TestWakeHandlerReturnsUnlockRequiredWithoutLeakingInspectionError(t *testing.T) {
	inspector := &fakeTabletInspector{
		observation: tabletObservation{HomeKnown: true, DisplayState: displayUnknown},
		err:         errors.New("journal unavailable while home is locked"),
	}
	handler := newWakeHandler("token", inspector, &fakePowerWaker{}, time.Second, time.Now)
	recorder := authenticatedRequest(handler, http.MethodGet, "/v1/status", nil, "token")

	response := decodeWakeResponse(t, recorder)
	if recorder.Code != http.StatusOK || response.Schema != WakeSchema || response.State != "unlock_required" {
		t.Fatalf("response = (%d, %#v)", recorder.Code, response)
	}
	if strings.Contains(recorder.Body.String(), "journal") {
		t.Fatalf("response leaked inspection detail: %q", recorder.Body.String())
	}
}

func TestWakeHandlerSendsOneWakeOnlyForCurrentDeepSleep(t *testing.T) {
	inspector := &fakeTabletInspector{
		observation: tabletObservation{
			HomeKnown: true, HomeMounted: true, DisplayState: displayDeepSleep,
			DisplayAuthoritative: true,
		},
	}
	waker := &fakePowerWaker{}
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)
	handler := newWakeHandler("token", inspector, waker, time.Second, func() time.Time { return now })

	first := authenticatedRequest(handler, http.MethodPost, "/v1/wake", nil, "token")
	firstResponse := decodeWakeResponse(t, first)
	if first.Code != http.StatusOK || !firstResponse.WakeSent || firstResponse.State != "sleeping" {
		t.Fatalf("first response = (%d, %#v)", first.Code, firstResponse)
	}
	second := authenticatedRequest(handler, http.MethodPost, "/v1/wake", nil, "token")
	secondResponse := decodeWakeResponse(t, second)
	if second.Code != http.StatusOK || secondResponse.WakeSent {
		t.Fatalf("suppressed response = (%d, %#v)", second.Code, secondResponse)
	}
	if waker.calls != 1 {
		t.Fatalf("wake calls = %d, want exactly one", waker.calls)
	}
}

func TestWakeHandlerCanWakeUnlockRequiredScreenButNeverNormalDisplay(t *testing.T) {
	now := time.Date(2026, 8, 2, 12, 0, 0, 0, time.UTC)
	waker := &fakePowerWaker{}
	lockedInspector := &fakeTabletInspector{
		observation: tabletObservation{
			HomeKnown: true, DisplayState: displayDeepSleep, DisplayAuthoritative: true,
		},
	}
	lockedHandler := newWakeHandler("token", lockedInspector, waker, time.Second, func() time.Time { return now })
	locked := authenticatedRequest(lockedHandler, http.MethodPost, "/v1/wake", nil, "token")
	lockedResponse := decodeWakeResponse(t, locked)
	if lockedResponse.State != "unlock_required" || !lockedResponse.WakeSent || waker.calls != 1 {
		t.Fatalf("locked response = %#v, wake calls = %d", lockedResponse, waker.calls)
	}

	readyInspector := &fakeTabletInspector{
		observation: tabletObservation{
			HomeKnown: true, HomeMounted: true, DisplayState: displayNormal,
			DisplayAuthoritative: true,
		},
	}
	readyHandler := newWakeHandler("token", readyInspector, waker, time.Second, func() time.Time { return now })
	ready := authenticatedRequest(readyHandler, http.MethodPost, "/v1/wake", nil, "token")
	readyResponse := decodeWakeResponse(t, ready)
	if readyResponse.State != "ready" || readyResponse.WakeSent || waker.calls != 1 {
		t.Fatalf("ready response = %#v, wake calls = %d", readyResponse, waker.calls)
	}
}

func TestWakeHandlerReturnsStartingWhenInspectionIsUnknown(t *testing.T) {
	inspector := &fakeTabletInspector{err: errors.New("systemd is not ready")}
	waker := &fakePowerWaker{}
	handler := newWakeHandler("token", inspector, waker, time.Second, time.Now)
	recorder := authenticatedRequest(handler, http.MethodPost, "/v1/wake", nil, "token")
	response := decodeWakeResponse(t, recorder)

	if response.State != "starting" || response.WakeSent || waker.calls != 0 {
		t.Fatalf("response = %#v, wake calls = %d", response, waker.calls)
	}
}

func TestWakeHandlerRejectsBodiesMethodsAndQueries(t *testing.T) {
	inspector := &fakeTabletInspector{}
	handler := newWakeHandler("token", inspector, &fakePowerWaker{}, time.Second, time.Now)
	tests := []struct {
		method string
		path   string
		body   []byte
		status int
	}{
		{method: http.MethodPost, path: "/v1/status", status: http.StatusMethodNotAllowed},
		{method: http.MethodGet, path: "/v1/wake", status: http.StatusMethodNotAllowed},
		{method: http.MethodGet, path: "/v1/status?extra=1", status: http.StatusBadRequest},
		{method: http.MethodGet, path: "/v1/missing", status: http.StatusNotFound},
		{method: http.MethodPost, path: "/v1/wake", body: []byte("x"), status: http.StatusRequestEntityTooLarge},
	}
	for _, test := range tests {
		recorder := authenticatedRequest(handler, test.method, test.path, test.body, "token")
		if recorder.Code != test.status {
			t.Fatalf("%s %s status = %d, want %d", test.method, test.path, recorder.Code, test.status)
		}
	}
	if inspector.calls != 0 {
		t.Fatalf("invalid requests reached inspector %d times", inspector.calls)
	}
}

func TestWakeHandlerReturnsStableFailureWithoutInternalError(t *testing.T) {
	inspector := &fakeTabletInspector{
		observation: tabletObservation{
			HomeKnown: true, HomeMounted: true, DisplayState: displayDeepSleep,
			DisplayAuthoritative: true,
		},
	}
	waker := &fakePowerWaker{err: errors.New("uinput details must stay private")}
	handler := newWakeHandler("token", inspector, waker, time.Second, time.Now)
	recorder := authenticatedRequest(handler, http.MethodPost, "/v1/wake", nil, "token")
	response := decodeWakeResponse(t, recorder)

	if recorder.Code != http.StatusServiceUnavailable || response.Error != "wake_failed" || response.WakeSent {
		t.Fatalf("response = (%d, %#v)", recorder.Code, response)
	}
	if strings.Contains(recorder.Body.String(), "uinput") {
		t.Fatalf("response leaked wake implementation detail: %q", recorder.Body.String())
	}
}

func TestWakeHandlerNeverUsesJournalOnlyDeepSleepAsAPowerDecision(t *testing.T) {
	inspector := &fakeTabletInspector{
		observation: tabletObservation{
			HomeKnown: true, HomeMounted: true, DisplayState: displayDeepSleep,
		},
	}
	waker := &fakePowerWaker{}
	handler := newWakeHandler("token", inspector, waker, time.Second, time.Now)
	recorder := authenticatedRequest(handler, http.MethodPost, "/v1/wake", nil, "token")
	response := decodeWakeResponse(t, recorder)

	if recorder.Code != http.StatusOK || response.State != "starting" || response.WakeSent {
		t.Fatalf("response = (%d, %#v)", recorder.Code, response)
	}
	if waker.calls != 0 {
		t.Fatalf("journal-only display state sent %d power events", waker.calls)
	}
}

func authenticatedRequest(
	handler http.Handler,
	method string,
	path string,
	body []byte,
	token string,
) *httptest.ResponseRecorder {
	var reader *bytes.Reader
	if body == nil {
		reader = bytes.NewReader(nil)
	} else {
		reader = bytes.NewReader(body)
	}
	request := httptest.NewRequest(method, path, reader)
	request.Header.Set("Authorization", "Bearer "+token)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	return recorder
}

func requestAt(
	handler http.Handler,
	method string,
	path string,
	body []byte,
	localAddress string,
	remoteAddress string,
	authorizations []string,
) *httptest.ResponseRecorder {
	var reader *bytes.Reader
	if body == nil {
		reader = bytes.NewReader(nil)
	} else {
		reader = bytes.NewReader(body)
	}
	request := httptest.NewRequest(method, path, reader)
	local, err := net.ResolveTCPAddr("tcp4", localAddress)
	if err != nil {
		panic(err)
	}
	request = request.WithContext(
		context.WithValue(request.Context(), http.LocalAddrContextKey, local),
	)
	request.RemoteAddr = remoteAddress
	for _, authorization := range authorizations {
		request.Header.Add("Authorization", authorization)
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	return recorder
}

func decodeWakeResponse(t *testing.T, recorder *httptest.ResponseRecorder) WakeStatus {
	t.Helper()
	var response WakeStatus
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response %q: %v", recorder.Body.String(), err)
	}
	return response
}
