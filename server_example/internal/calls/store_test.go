package calls

import "testing"

func TestRecordEventKeepsNewestSequenceAndTerminalState(t *testing.T) {
	store := NewStore()
	store.Put(Call{ID: "call-1"})
	ended := Event{CallID: "call-1", EventID: "end-3", Sequence: 3, Type: "ended", Reason: "remote"}
	if found, duplicate := store.RecordEvent(ended); !found || duplicate {
		t.Fatalf("first end: found=%v duplicate=%v", found, duplicate)
	}
	for _, event := range []Event{
		{CallID: "call-1", EventID: "answer-2", Sequence: 2, Type: "answer_requested"},
		{CallID: "call-1", EventID: "answer-4", Sequence: 4, Type: "answer_requested"},
		{CallID: "call-1", EventID: "end-3-other", Sequence: 3, Type: "ended", Reason: "rejected"},
	} {
		if found, duplicate := store.RecordEvent(event); !found || duplicate {
			t.Fatalf("stale event %s: found=%v duplicate=%v", event.EventID, found, duplicate)
		}
		call, _ := store.Get("call-1")
		if call.State != StateEnded {
			t.Fatalf("event %s changed terminal state to %s", event.EventID, call.State)
		}
		if found, duplicate := store.RecordEvent(event); !found || !duplicate {
			t.Fatalf("event %s retry: found=%v duplicate=%v", event.EventID, found, duplicate)
		}
	}
}

func TestRecordEventIgnoresLowerAndEqualSequence(t *testing.T) {
	store := NewStore()
	store.Put(Call{ID: "call-1"})
	store.RecordEvent(Event{CallID: "call-1", EventID: "answer-2", Sequence: 2, Type: "answer_requested"})
	store.RecordEvent(Event{CallID: "call-1", EventID: "end-1", Sequence: 1, Type: "ended", Reason: "remote"})
	store.RecordEvent(Event{CallID: "call-1", EventID: "end-2", Sequence: 2, Type: "ended", Reason: "rejected"})
	call, _ := store.Get("call-1")
	if call.State != StateAnswerRequested {
		t.Fatalf("older end changed state to %s", call.State)
	}
	store.RecordEvent(Event{CallID: "call-1", EventID: "end-3", Sequence: 3, Type: "ended", Reason: "remote"})
	call, _ = store.Get("call-1")
	if call.State != StateEnded {
		t.Fatalf("newer end left state %s", call.State)
	}
}
