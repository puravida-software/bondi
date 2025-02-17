package main

import (
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/puravida-software/bondi/server/deployment"
)

func healthCheckHandler(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
}

// TODO: add a readiness probe

func main() {
	// Set up the /deploy and /health endpoints
	http.HandleFunc("/deploy", deployment.Handler)
	http.HandleFunc("/health", healthCheckHandler)

	// Create a server with explicit timeouts
	server := &http.Server{
		Addr:         ":3030",
		Handler:      nil,               // Using the default mux
		ReadTimeout:  5 * time.Second,   //nolint:mnd // we'll start with sane defaults, and add support for custom timeouts later
		WriteTimeout: 10 * time.Second,  //nolint:mnd // we'll start with sane defaults, and add support for custom timeouts later
		IdleTimeout:  120 * time.Second, //nolint:mnd // we'll start with sane defaults, and add support for custom timeouts later
	}

	fmt.Println("Server listening on port 3030...")
	if err := server.ListenAndServe(); err != nil {
		slog.Error("Server failed", "error", err)
	}
}
