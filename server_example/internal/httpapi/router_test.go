package httpapi

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/Albizia-Dev/jackfield/server_example/internal/calls"
)

type fakePush struct {
	incoming    int
	ended       int
	token       string
	incomingErr error
	endErr      error
}

func (f *fakePush) SendIncoming(_ context.Context, token string, _ calls.Call) (string, error) {
	f.incoming++
	f.token = token
	return "fcm-id", f.incomingErr
}
func (f *fakePush) SendEnd(_ context.Context, token string, _ calls.Call) (string, error) {
	f.ended++
	f.token = token
	return "fcm-end-id", f.endErr
}

type blockingEndPush struct {
	sent    chan struct{}
	release chan struct{}
	ends    atomic.Int32
}

func (f *blockingEndPush) SendIncoming(context.Context, string, calls.Call) (string, error) {
	return "fcm-id", nil
}

func (f *blockingEndPush) SendEnd(context.Context, string, calls.Call) (string, error) {
	f.ends.Add(1)
	f.sent <- struct{}{}
	<-f.release
	return "fcm-end-id", nil
}

func TestCreateAndRemoteEnd(t *testing.T) {
	store := calls.NewStore()
	push := &fakePush{}
	router := NewRouter(store, push, "api-secret", "callback-secret")
	post := func(path, body string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
		request.Header.Set("Authorization", "Bearer api-secret")
		response := httptest.NewRecorder()
		router.ServeHTTP(response, request)
		return response
	}
	response := post("/calls", `{"callId":"call-1","caller":{"id":"person-1","displayName":"Alice"},"media":"audio","fcmToken":"device-token"}`)
	if response.Code != http.StatusCreated || push.incoming != 1 || push.token != "device-token" {
		t.Fatalf("create: %d, %#v", response.Code, push)
	}
	response = post("/calls/call-1/end", `{}`)
	if response.Code != http.StatusNoContent || push.ended != 1 {
		t.Fatalf("end: %d, %#v", response.Code, push)
	}
	call, ok := store.Get("call-1")
	if !ok || call.State != calls.StateEnded {
		t.Fatalf("wrong state after end: %#v", call)
	}
}

func TestFailedPushCanBeRetriedWithSameCallID(t *testing.T) {
	store := calls.NewStore()
	push := &fakePush{incomingErr: errors.New("provider unavailable")}
	router := NewRouter(store, push, "api-secret", "callback-secret")
	request := httptest.NewRequest(http.MethodPost, "/calls", strings.NewReader(`{"callId":"call-1","caller":{"id":"person-1","displayName":"Alice"},"media":"audio","fcmToken":"device-token"}`))
	request.Header.Set("Authorization", "Bearer api-secret")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusBadGateway {
		t.Fatalf("failed push returned %d", response.Code)
	}
	if _, exists := store.Get("call-1"); exists {
		t.Fatal("failed send left a ringing call")
	}
}

func TestCreateRequiresAPIBearerAndValidCall(t *testing.T) {
	store := calls.NewStore()
	push := &fakePush{}
	router := NewRouter(store, push, "api-secret", "callback-secret")
	request := httptest.NewRequest(http.MethodPost, "/calls", strings.NewReader(`{"callId":"call-1"}`))
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized || push.incoming != 0 {
		t.Fatalf("unauthorized create: %d, %#v", response.Code, push)
	}
	request.Header.Set("Authorization", "Bearer api-secret")
	response = httptest.NewRecorder()
	router.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("invalid create returned %d", response.Code)
	}
}

func TestConcurrentRemoteEndSendsOnce(t *testing.T) {
	store := calls.NewStore()
	store.Put(calls.Call{ID: "call-1", DeviceToken: "device-token"})
	push := &blockingEndPush{sent: make(chan struct{}, 2), release: make(chan struct{})}
	router := NewRouter(store, push, "api-secret", "callback-secret")
	post := func() *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodPost, "/calls/call-1/end", nil)
		request.Header.Set("Authorization", "Bearer api-secret")
		response := httptest.NewRecorder()
		router.ServeHTTP(response, request)
		return response
	}
	first := make(chan *httptest.ResponseRecorder, 1)
	go func() { first <- post() }()
	<-push.sent
	secondDone := make(chan *httptest.ResponseRecorder, 1)
	go func() { secondDone <- post() }()
	var second *httptest.ResponseRecorder
	select {
	case second = <-secondDone:
	case <-push.sent:
		close(push.release)
		<-first
		<-secondDone
		t.Fatal("concurrent end entered FCM SendEnd twice")
	}
	if second.Code != http.StatusConflict {
		t.Fatalf("concurrent end returned %d, want 409 pending", second.Code)
	}
	if got := push.ends.Load(); got != 1 {
		t.Fatalf("concurrent end sent %d FCM messages", got)
	}
	close(push.release)
	if response := <-first; response.Code != http.StatusNoContent {
		t.Fatalf("first end returned %d", response.Code)
	}
	if response := post(); response.Code != http.StatusNoContent || push.ends.Load() != 1 {
		t.Fatalf("completed retry returned %d, sends=%d", response.Code, push.ends.Load())
	}
}

func TestFailedRemoteEndReleasesReservationForRetry(t *testing.T) {
	store := calls.NewStore()
	store.Put(calls.Call{ID: "call-1", DeviceToken: "device-token"})
	push := &fakePush{endErr: errors.New("provider unavailable")}
	router := NewRouter(store, push, "api-secret", "callback-secret")
	post := func() int {
		request := httptest.NewRequest(http.MethodPost, "/calls/call-1/end", nil)
		request.Header.Set("Authorization", "Bearer api-secret")
		response := httptest.NewRecorder()
		router.ServeHTTP(response, request)
		return response.Code
	}
	if code := post(); code != http.StatusBadGateway {
		t.Fatalf("failed end returned %d", code)
	}
	call, _ := store.Get("call-1")
	if call.State != calls.StateRinging {
		t.Fatalf("failed end changed state to %s", call.State)
	}
	push.endErr = nil
	if code := post(); code != http.StatusNoContent || push.ended != 2 {
		t.Fatalf("retry returned %d, sends=%d", code, push.ended)
	}
}
