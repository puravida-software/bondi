package deployment

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/puravida-software/bondi/server/internal/deployment/models"
	"github.com/puravida-software/bondi/server/internal/deployment/strategies"
	"github.com/puravida-software/bondi/server/internal/docker"
)

type (
	ClientFactory   func(registryUser *string, registryPass *string) (docker.Client, error)
	StrategyFactory func(dockerClient docker.Client) strategies.Strategy
)

// TODO: evaluate naming and design decision for factories
func NewHandler(factory ClientFactory, strategyFactory StrategyFactory) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
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

		dockerClient, err := factory(input.RegistryUser, input.RegistryPass)
		if err != nil {
			slog.Error("Error creating Docker client", "error", err)
			http.Error(w, "Error creating Docker client: "+err.Error(), http.StatusInternalServerError)
			return
		}

		strategy := strategyFactory(dockerClient)
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
}
