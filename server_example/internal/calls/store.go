package calls

import "sync"

type Party struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
}

type State string

const (
	StateRinging         State = "ringing"
	StateAnswerRequested State = "answer_requested"
	StateAccepted        State = "accepted"
	StateRejected        State = "rejected"
	StateEnded           State = "ended"
)

type Call struct {
	ID          string `json:"callId"`
	Caller      Party  `json:"caller"`
	Media       string `json:"media"`
	State       State  `json:"state"`
	DeviceToken string `json:"-"`
}

type Event struct {
	Version    int    `json:"version"`
	CallID     string `json:"callId"`
	EventID    string `json:"eventId"`
	Sequence   int64  `json:"sequence"`
	OccurredAt string `json:"occurredAt"`
	Type       string `json:"type"`
	ActionID   string `json:"actionId,omitempty"`
	Deadline   string `json:"deadline,omitempty"`
	Reason     string `json:"reason,omitempty"`
}

type Store struct {
	mu     sync.Mutex
	calls  map[string]Call
	events map[string]Event
}

func NewStore() *Store { return &Store{calls: make(map[string]Call), events: make(map[string]Event)} }

func (s *Store) Put(call Call) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.calls[call.ID]; exists {
		return false
	}
	if call.State == "" {
		call.State = StateRinging
	}
	s.calls[call.ID] = call
	return true
}

func (s *Store) Get(id string) (Call, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	call, ok := s.calls[id]
	return call, ok
}

func (s *Store) Delete(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.calls, id)
}

func (s *Store) End(id string) (Call, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	call, ok := s.calls[id]
	if !ok {
		return Call{}, false
	}
	call.State = StateEnded
	s.calls[id] = call
	return call, true
}

// RecordEvent accepts an event only once, including across HTTP retries.
func (s *Store) RecordEvent(event Event) (found bool, duplicate bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	call, ok := s.calls[event.CallID]
	if !ok {
		return false, false
	}
	if _, exists := s.events[event.EventID]; exists {
		return true, true
	}
	s.events[event.EventID] = event
	switch event.Type {
	case "answer_requested":
		call.State = StateAnswerRequested
	case "ended":
		if event.Reason == "rejected" {
			call.State = StateRejected
		} else {
			call.State = StateEnded
		}
	}
	s.calls[event.CallID] = call
	return true, false
}

func (s *Store) EventCount(id string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.events[id]; ok {
		return 1
	}
	return 0
}
