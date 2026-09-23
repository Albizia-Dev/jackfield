package callbacks

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/Albizia-Dev/jackfield/server_example/internal/calls"
)

type Handler struct {
	store *calls.Store
	token string
}

func NewHandler(store *calls.Store, token string) *Handler {
	return &Handler{store: store, token: token}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	provided, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	providedHash, tokenHash := sha256.Sum256([]byte(provided)), sha256.Sum256([]byte(h.token))
	if !ok || h.token == "" || subtle.ConstantTimeCompare(providedHash[:], tokenHash[:]) != 1 {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	var envelope struct {
		Version int         `json:"version"`
		Event   calls.Event `json:"event"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&envelope); err != nil || envelope.Version != 1 || envelope.Event.Version != 1 || envelope.Event.EventID == "" || envelope.Event.CallID == "" || envelope.Event.Sequence < 0 || (envelope.Event.Type != "answer_requested" && envelope.Event.Type != "ended") || r.Header.Get("Idempotency-Key") != envelope.Event.EventID {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if _, err := time.Parse(time.RFC3339Nano, envelope.Event.OccurredAt); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if envelope.Event.Type == "answer_requested" {
		if envelope.Event.ActionID == "" || envelope.Event.Deadline == "" || envelope.Event.Reason != "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if _, err := time.Parse(time.RFC3339Nano, envelope.Event.Deadline); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
	} else if envelope.Event.ActionID != "" || envelope.Event.Deadline != "" || !validReason(envelope.Event.Reason) {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	found, _ := h.store.RecordEvent(envelope.Event)
	if !found {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func validReason(reason string) bool {
	switch reason {
	case "local", "remote", "rejected", "missed", "failed":
		return true
	default:
		return false
	}
}
