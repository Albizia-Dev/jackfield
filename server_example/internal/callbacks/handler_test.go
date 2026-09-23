package callbacks

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Albizia-Dev/jackfield/server_example/internal/calls"
)

func canonicalAnswer(t *testing.T) string {
	t.Helper()
	path := filepath.Join("..", "..", "..", "test", "fixtures", "callback_answer_requested_v1.json")
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read canonical callback fixture: %v", err)
	}
	var envelope struct {
		Version int `json:"version"`
		Event   struct {
			Version    int    `json:"version"`
			CallID     string `json:"callId"`
			EventID    string `json:"eventId"`
			Sequence   int64  `json:"sequence"`
			OccurredAt string `json:"occurredAt"`
			Type       string `json:"type"`
			ActionID   string `json:"actionId"`
			Deadline   string `json:"deadline"`
		} `json:"event"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		t.Fatalf("decode canonical callback fixture: %v", err)
	}
	if envelope.Version != 1 || envelope.Event.Version != 1 || envelope.Event.CallID != "call-1" || envelope.Event.EventID != "event-7" || envelope.Event.Sequence != 2 || envelope.Event.OccurredAt != "2026-09-23T05:00:00.000Z" || envelope.Event.Type != "answer_requested" || envelope.Event.ActionID != "action-3" || envelope.Event.Deadline != "2026-09-23T05:00:30.000Z" {
		t.Fatalf("canonical callback contract changed: %+v", envelope)
	}
	return string(body)
}

func TestCallbackIsIdempotentByEventID(t *testing.T) {
	store := calls.NewStore()
	store.Put(calls.Call{ID: "call-1", Caller: calls.Party{ID: "person-1", DisplayName: "Alice"}, Media: "audio"})
	handler := NewHandler(store, "secret")
	answer := canonicalAnswer(t)
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
	answer := canonicalAnswer(t)
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

func TestStaleCallbackIsAcknowledgedWithoutRevivingEndedCall(t *testing.T) {
	store := calls.NewStore()
	store.Put(calls.Call{ID: "call-1"})
	handler := NewHandler(store, "secret")
	post := func(body, eventID string) int {
		request := httptest.NewRequest(http.MethodPost, "/callbacks/jackfield", strings.NewReader(body))
		request.Header.Set("Authorization", "Bearer secret")
		request.Header.Set("Idempotency-Key", eventID)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response.Code
	}
	ended := `{"version":1,"event":{"version":1,"callId":"call-1","eventId":"end-3","sequence":3,"occurredAt":"2026-09-23T05:01:00.000Z","type":"ended","reason":"remote"}}`
	if code := post(ended, "end-3"); code != http.StatusNoContent {
		t.Fatalf("end callback returned %d", code)
	}
	answer := canonicalAnswer(t)
	for range 2 {
		if code := post(answer, "event-7"); code != http.StatusNoContent {
			t.Fatalf("late answer returned %d", code)
		}
	}
	call, _ := store.Get("call-1")
	if call.State != calls.StateEnded || store.EventCount("event-7") != 1 {
		t.Fatalf("late answer revived call or was not deduplicated: %+v", call)
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
