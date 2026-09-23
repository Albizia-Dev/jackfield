package callbacks

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Albizia-Dev/jackfield/server_example/internal/calls"
)

const answer = `{"version":1,"event":{"version":1,"callId":"call-1","eventId":"event-7","sequence":2,"occurredAt":"2026-09-23T05:00:00.000Z","type":"answer_requested","actionId":"action-3","deadline":"2026-09-23T05:00:30.000Z"}}`

func TestCallbackIsIdempotentByEventID(t *testing.T) {
	store := calls.NewStore()
	store.Put(calls.Call{ID: "call-1", Caller: calls.Party{ID: "person-1", DisplayName: "Alice"}, Media: "audio"})
	handler := NewHandler(store, "secret")
	for range 2 {
		request := httptest.NewRequest(http.MethodPost, "/callbacks/jackfield", strings.NewReader(answer))
		request.Header.Set("Authorization", "Bearer secret")
		request.Header.Set("Idempotency-Key", "event-7")
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusNoContent {
			t.Fatalf("callback returned %d: %s", response.Code, response.Body.String())
		}
	}
	if got := store.EventCount("event-7"); got != 1 {
		t.Fatalf("stored %d duplicate events", got)
	}
	call, ok := store.Get("call-1")
	if !ok || call.State != calls.StateAnswerRequested {
		t.Fatalf("wrong call state: %#v", call)
	}
}

func TestCallbackRequiresMatchingBearerAndIdempotencyKey(t *testing.T) {
	handler := NewHandler(calls.NewStore(), "secret")
	for _, auth := range []string{"", "Bearer wrong", "Basic secret"} {
		request := httptest.NewRequest(http.MethodPost, "/callbacks/jackfield", strings.NewReader(answer))
		request.Header.Set("Authorization", auth)
		request.Header.Set("Idempotency-Key", "event-7")
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("auth %q returned %d", auth, response.Code)
		}
	}
	request := httptest.NewRequest(http.MethodPost, "/callbacks/jackfield", strings.NewReader(answer))
	request.Header.Set("Authorization", "Bearer secret")
	request.Header.Set("Idempotency-Key", "different-event")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("mismatched idempotency key returned %d", response.Code)
	}
}

func TestRejectedEndUpdatesCallOnce(t *testing.T) {
	store := calls.NewStore()
	store.Put(calls.Call{ID: "call-1", Caller: calls.Party{ID: "person-1", DisplayName: "Alice"}, Media: "audio"})
	handler := NewHandler(store, "secret")
	body := `{"version":1,"event":{"version":1,"callId":"call-1","eventId":"event-8","sequence":3,"occurredAt":"2026-09-23T05:01:00.000Z","type":"ended","reason":"rejected"}}`
	request := httptest.NewRequest(http.MethodPost, "/callbacks/jackfield", strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer secret")
	request.Header.Set("Idempotency-Key", "event-8")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	call, _ := store.Get("call-1")
	if response.Code != http.StatusNoContent || call.State != calls.StateRejected || store.EventCount("event-8") != 1 {
		t.Fatalf("rejection: %d %#v", response.Code, call)
	}
}

func TestCallbackRejectsIncompleteAnswer(t *testing.T) {
	store := calls.NewStore()
	store.Put(calls.Call{ID: "call-1"})
	handler := NewHandler(store, "secret")
	body := `{"version":1,"event":{"version":1,"callId":"call-1","eventId":"event-7","sequence":2,"occurredAt":"2026-09-23T05:00:00.000Z","type":"answer_requested"}}`
	request := httptest.NewRequest(http.MethodPost, "/callbacks/jackfield", strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer secret")
	request.Header.Set("Idempotency-Key", "event-7")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest || store.EventCount("event-7") != 0 {
		t.Fatalf("incomplete answer: %d", response.Code)
	}
}
