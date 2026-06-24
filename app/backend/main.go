package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"
)

type StatusResponse struct {
	Service   string `json:"service"`
	Version   string `json:"version"`
	Timestamp string `json:"timestamp"`
	Hostname  string `json:"hostname"`
}

func main() {
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})

	http.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
		hostname, _ := os.Hostname()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(StatusResponse{
			Service:   "securechain-backend",
			Version:   getEnv("APP_VERSION", "1.0.0"),
			Timestamp: time.Now().UTC().Format(time.RFC3339),
			Hostname:  hostname,
		})
	})

	port := getEnv("PORT", "8080")
	fmt.Printf("Backend listening on :%s\n", port)
	http.ListenAndServe(":"+port, nil)
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
