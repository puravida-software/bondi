package deployment

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/docker/docker/client"
	"github.com/puravida-software/bondi/server/deployment/models"
	"github.com/puravida-software/bondi/server/deployment/strategies"
	"github.com/puravida-software/bondi/server/docker"
)

func Handler(w http.ResponseWriter, r *http.Request) {
	// Only allow POST method
	if r.Method != http.MethodPost {
		slog.Error("Method not allowed", "method", r.Method)
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Decode the JSON request body
	var input models.DeployInput
	if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
		slog.Error("Error decoding request body", "error", err)
		http.Error(w, "Bad request: "+err.Error(), http.StatusBadRequest)
		return
	}

	// Log the received deploy input (e.g., tag)
	fmt.Printf("Received deploy request with tag: %s\n", input.Tag)

	ctx := context.Background()

	// Set up the Docker client
	apiClient, err := client.NewClientWithOpts(client.FromEnv)
	if err != nil {
		slog.Error("Error creating Docker client", "error", err)
		http.Error(w, "Error creating Docker client: "+err.Error(), http.StatusInternalServerError)
		return
	}
	defer apiClient.Close()

	dockerClient, err := docker.NewDockerClient(apiClient, input.RegistryUser, input.RegistryPass)
	if err != nil {
		slog.Error("Error creating Docker wrapper", "error", err)
		http.Error(w, "Error creating Docker wrapper: "+err.Error(), http.StatusInternalServerError)
		return
	}

	strategy := strategies.NewSimpleDeployment(dockerClient)
	err = strategy.Deploy(ctx, &input)
	if err != nil {
		slog.Error("Error deploying", "error", err)
		http.Error(w, "Error deploying: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Respond to the client
	w.Header().Set("Content-Type", "application/json")
	response := map[string]string{
		"status": "Deploy initiated",
		"tag":    input.Tag,
	}
	if err := json.NewEncoder(w).Encode(response); err != nil {
		slog.Error("Error encoding response", "error", err)
		http.Error(w, "Error encoding response: "+err.Error(), http.StatusInternalServerError)
	}
}
