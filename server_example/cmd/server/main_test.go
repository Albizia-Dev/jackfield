package main

import "testing"

func TestConfigurationRequiresBothBearerTokens(t *testing.T) {
	t.Setenv("JACKFIELD_API_TOKEN", "")
	t.Setenv("JACKFIELD_CALLBACK_TOKEN", "callback")
	if _, err := loadConfig(); err == nil {
		t.Fatal("accepted missing API token")
	}
	t.Setenv("JACKFIELD_API_TOKEN", "api")
	t.Setenv("JACKFIELD_CALLBACK_TOKEN", "")
	if _, err := loadConfig(); err == nil {
		t.Fatal("accepted missing callback token")
	}
}

func TestConfigurationRejectsInvalidTTL(t *testing.T) {
	t.Setenv("JACKFIELD_API_TOKEN", "api")
	t.Setenv("JACKFIELD_CALLBACK_TOKEN", "callback")
	t.Setenv("JACKFIELD_FCM_TTL", "0s")
	if _, err := loadConfig(); err == nil {
		t.Fatal("accepted zero TTL")
	}
}
