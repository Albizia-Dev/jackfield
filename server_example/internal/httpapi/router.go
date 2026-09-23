package httpapi

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"io"
	"net/http"
	"strings"

	"github.com/Albizia-Dev/jackfield/server_example/internal/callbacks"
	"github.com/Albizia-Dev/jackfield/server_example/internal/calls"
)

type PushSender interface {
	SendIncoming(ctx context.Context, token string, call calls.Call) (string, error)
	SendEnd(ctx context.Context, token string, call calls.Call) (string, error)
}

type router struct {
	store    *calls.Store
	push     PushSender
	apiToken string
}

func NewRouter(store *calls.Store, push PushSender, apiToken, callbackToken string) http.Handler {
	r := &router{store: store, push: push, apiToken: apiToken}
	mux := http.NewServeMux()
	mux.Handle("POST /calls", http.HandlerFunc(r.create))
	mux.Handle("POST /calls/{callId}/end", http.HandlerFunc(r.end))
	mux.Handle("POST /callbacks/jackfield", callbacks.NewHandler(store, callbackToken))
	return mux
}

func (r *router) authorized(request *http.Request) bool {
	provided, ok := strings.CutPrefix(request.Header.Get("Authorization"), "Bearer ")
	providedHash, tokenHash := sha256.Sum256([]byte(provided)), sha256.Sum256([]byte(r.apiToken))
	return ok && r.apiToken != "" && subtle.ConstantTimeCompare(providedHash[:], tokenHash[:]) == 1
}

func (r *router) create(w http.ResponseWriter, request *http.Request) {
	if !r.authorized(request) {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	var input struct {
		CallID   string      `json:"callId"`
		Caller   calls.Party `json:"caller"`
		Media    string      `json:"media"`
		FCMToken string      `json:"fcmToken"`
	}
	request.Body = http.MaxBytesReader(w, request.Body, 64<<10)
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || input.CallID == "" || input.Caller.ID == "" || input.Caller.DisplayName == "" || (input.Media != "audio" && input.Media != "video") || input.FCMToken == "" {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	call := calls.Call{ID: input.CallID, Caller: input.Caller, Media: input.Media, DeviceToken: input.FCMToken}
	if !r.store.Put(call) {
		w.WriteHeader(http.StatusConflict)
		return
	}
	if _, err := r.push.SendIncoming(request.Context(), input.FCMToken, call); err != nil {
		r.store.Delete(input.CallID)
		w.WriteHeader(http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(map[string]string{"callId": input.CallID, "state": string(calls.StateRinging)})
}

func (r *router) end(w http.ResponseWriter, request *http.Request) {
	if !r.authorized(request) {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	id := request.PathValue("callId")
	call, disposition := r.store.ReserveEnd(id)
	switch disposition {
	case calls.EndNotFound:
		w.WriteHeader(http.StatusNotFound)
		return
	case calls.EndAlreadyComplete:
		w.WriteHeader(http.StatusNoContent)
		return
	case calls.EndInProgress:
		w.WriteHeader(http.StatusConflict)
		return
	}
	if _, err := r.push.SendEnd(request.Context(), call.DeviceToken, call); err != nil {
		r.store.FinishEnd(id, false)
		w.WriteHeader(http.StatusBadGateway)
		return
	}
	r.store.FinishEnd(id, true)
	w.WriteHeader(http.StatusNoContent)
}
