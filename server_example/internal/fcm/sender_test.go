package fcm

import (
	"testing"
	"time"

	"github.com/Albizia-Dev/jackfield/server_example/internal/calls"
)

func TestInviteUsesDataMessageWithTTL(t *testing.T) {
	expiresAt := time.Date(2026, 9, 30, 4, 0, 45, 0, time.UTC)
	message := BuildInvite("device-token", calls.Call{ID: "call-1", Caller: calls.Party{ID: "person-1", DisplayName: "Alice"}, Media: "audio", ExpiresAt: expiresAt}, 90*time.Second)
	if message.Token != "device-token" || message.Data["version"] != "1" || message.Data["callId"] != "call-1" || message.Data["callerId"] != "person-1" || message.Data["callerName"] != "Alice" || message.Data["media"] != "audio" {
		t.Fatalf("unexpected FCM data: %#v", message)
	}
	if message.Android == nil || message.Android.TTL == nil || *message.Android.TTL != 90*time.Second || message.Android.CollapseKey != "call-1" || message.Notification != nil {
		t.Fatalf("invite must be a data-only message with positive TTL: %#v", message)
	}
	if message.Data["expiresAt"] != "2026-09-30T04:00:45.000Z" {
		t.Fatalf("missing stable ring deadline: %#v", message.Data)
	}
}

func TestInviteRejectsNonpositiveTTL(t *testing.T) {
	if _, err := ValidateTTL(0); err == nil {
		t.Fatal("zero TTL accepted")
	}
}

func TestRemoteEndUsesDataMessage(t *testing.T) {
	message := BuildEnd("device-token", calls.Call{ID: "call-1"}, "rejected", 90*time.Second)
	if message.Token != "device-token" || message.Data["version"] != "1" || message.Data["type"] != "end" || message.Data["callId"] != "call-1" || message.Data["reason"] != "rejected" || message.Notification != nil || message.Android == nil || message.Android.TTL == nil || *message.Android.TTL != 90*time.Second || message.Android.CollapseKey != "call-1" {
		t.Fatalf("invalid remote end: %#v", message)
	}
}
