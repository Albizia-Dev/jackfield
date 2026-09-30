package callbacks

import (
	"context"
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
	relay EndSender
}

type EndSender interface {
	SendEnd(ctx context.Context, token string, call calls.Call, reason string) (string, error)
}

func NewHandler(store *calls.Store, token string, relay ...EndSender) *Handler {
	var sender EndSender
	if len(relay) != 0 {
		sender = relay[0]
	}
	return &Handler{store: store, token: token, relay: sender}
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
	if envelope.Event.Type == "ended" && h.relay != nil {
		call, disposition := h.store.ReserveRelay(envelope.Event.EventID)
		switch disposition {
		case calls.RelayInProgress:
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		case calls.RelayReserved:
			if _, err := h.relay.SendEnd(r.Context(), call.InitiatorToken, call, envelope.Event.Reason); err != nil {
				h.store.FinishRelay(envelope.Event.EventID, false)
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			h.store.FinishRelay(envelope.Event.EventID, true)
		}
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
