package httpapi

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Albizia-Dev/jackfield/server_example/internal/calls"
)

type fakePush struct {
	incoming    int
	ended       int
	token       string
	incomingErr error
}

func (f *fakePush) SendIncoming(_ context.Context, token string, _ calls.Call) (string, error) {
	f.incoming++
	f.token = token
	return "fcm-id", f.incomingErr
}
func (f *fakePush) SendEnd(_ context.Context, token string, _ calls.Call) (string, error) {
	f.ended++
	f.token = token
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
