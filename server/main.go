package main

import (
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/docker/docker/client"
	"github.com/puravida-software/bondi/server/internal/deployment"
	"github.com/puravida-software/bondi/server/internal/deployment/strategies"
	"github.com/puravida-software/bondi/server/internal/docker"
	"github.com/puravida-software/bondi/server/internal/health"
)

// TODO: change to struct as opposed to factory functions.
func NewDockerClient(registryUser *string, registryPass *string) (docker.Client, error) {
	// Set up the Docker client
	apiClient, err := client.NewClientWithOpts(client.FromEnv)
	if err != nil {
		return nil, fmt.Errorf("error creating Docker client: %w", err)
	}
	defer apiClient.Close()

	dockerClient, err := docker.NewDockerClient(registryUser, registryPass)
	if err != nil {
		return nil, fmt.Errorf("error creating Docker wrapper: %w", err)
	}

	return dockerClient, nil
}

func NewSimpleDeployment(dockerClient docker.Client) strategies.Strategy {
	return strategies.NewSimpleDeployment(dockerClient)
}

func main() {
	http.HandleFunc("/api/v1/deploy", deployment.NewHandler(NewDockerClient, NewSimpleDeployment))
	http.HandleFunc("/api/v1/health", health.NewHandler())

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
