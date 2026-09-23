package fcm

import (
	"context"
	"errors"
	"os"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"github.com/Albizia-Dev/jackfield/server_example/internal/calls"
	"google.golang.org/api/option"
)

const MaxTTL = 4 * 7 * 24 * time.Hour

type messageClient interface {
	Send(context.Context, *messaging.Message) (string, error)
}

type Sender struct {
	client messageClient
	ttl    time.Duration
}

func ValidateTTL(ttl time.Duration) (time.Duration, error) {
	if ttl <= 0 || ttl > MaxTTL {
		return 0, errors.New("FCM TTL must be positive and at most four weeks")
	}
	return ttl, nil
}

func BuildInvite(token string, call calls.Call, ttl time.Duration) *messaging.Message {
	return &messaging.Message{
		Token: token,
		Data: map[string]string{
			"version": "1", "type": "incoming", "callId": call.ID,
			"callerId": call.Caller.ID, "callerName": call.Caller.DisplayName, "media": call.Media,
		},
		Android: &messaging.AndroidConfig{TTL: &ttl, Priority: "high"},
	}
}

func BuildEnd(token string, call calls.Call, ttl time.Duration) *messaging.Message {
	return &messaging.Message{
		Token:   token,
		Data:    map[string]string{"version": "1", "type": "end", "callId": call.ID, "reason": "remote"},
		Android: &messaging.AndroidConfig{TTL: &ttl, Priority: "high"},
	}
}

func (s *Sender) SendIncoming(ctx context.Context, token string, call calls.Call) (string, error) {
	return s.client.Send(ctx, BuildInvite(token, call, s.ttl))
}

func (s *Sender) SendEnd(ctx context.Context, token string, call calls.Call) (string, error) {
	return s.client.Send(ctx, BuildEnd(token, call, s.ttl))
}

// NewSender explicitly requires a service account path supplied by the operator.
func NewSender(ctx context.Context, ttl time.Duration) (*Sender, error) {
	if _, err := ValidateTTL(ttl); err != nil {
		return nil, err
	}
	credentials := os.Getenv("GOOGLE_APPLICATION_CREDENTIALS")
	if credentials == "" {
		return nil, errors.New("GOOGLE_APPLICATION_CREDENTIALS is required")
	}
	app, err := firebase.NewApp(ctx, nil, option.WithCredentialsFile(credentials))
	if err != nil {
		return nil, err
	}
	client, err := app.Messaging(ctx)
	if err != nil {
		return nil, err
	}
	return &Sender{client: client, ttl: ttl}, nil
}
