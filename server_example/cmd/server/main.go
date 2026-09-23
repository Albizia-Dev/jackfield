package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/Albizia-Dev/jackfield/server_example/internal/calls"
	"github.com/Albizia-Dev/jackfield/server_example/internal/fcm"
	"github.com/Albizia-Dev/jackfield/server_example/internal/httpapi"
)

type config struct {
	address       string
	apiToken      string
	callbackToken string
	ttl           time.Duration
}

func loadConfig() (config, error) {
	c := config{address: os.Getenv("JACKFIELD_LISTEN_ADDR"), apiToken: os.Getenv("JACKFIELD_API_TOKEN"), callbackToken: os.Getenv("JACKFIELD_CALLBACK_TOKEN"), ttl: 90 * time.Second}
	if c.address == "" {
		c.address = "127.0.0.1:8080"
	}
	if strings.TrimSpace(c.apiToken) == "" || strings.TrimSpace(c.callbackToken) == "" || strings.ContainsAny(c.apiToken+c.callbackToken, "\r\n") {
		return config{}, errors.New("JACKFIELD_API_TOKEN and JACKFIELD_CALLBACK_TOKEN are required")
	}
	if raw := os.Getenv("JACKFIELD_FCM_TTL"); raw != "" {
		var err error
		c.ttl, err = time.ParseDuration(raw)
		if err != nil {
			return config{}, err
		}
	}
	if _, err := fcm.ValidateTTL(c.ttl); err != nil {
		return config{}, err
	}
	return c, nil
}

func main() {
	c, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	sender, err := fcm.NewSender(ctx, c.ttl)
	if err != nil {
		log.Fatal(err)
	}
	server := &http.Server{Addr: c.address, Handler: httpapi.NewRouter(calls.NewStore(), sender, c.apiToken, c.callbackToken), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		shutdownCtx, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		_ = server.Shutdown(shutdownCtx)
	}()
	log.Printf("Jackfield manual stand listening on %s", c.address)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
