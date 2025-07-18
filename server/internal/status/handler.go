package status

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"

	"github.com/puravida-software/bondi/server/internal/docker"
)

type (
	ClientFactory func(registryUser *string, registryPass *string) (docker.Client, error)
)

type ContainerStatus struct {
	ImageName    string `json:"image_name"`
	Tag          string `json:"tag"`
	CreatedAt    string `json:"created_at"`
	RestartCount int64  `json:"restart_count"`
	Status       string `json:"status"`
}

func NewHandler(factory ClientFactory) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Only allow GET method
		if r.Method != http.MethodGet {
			slog.Error("Method not allowed", "method", r.Method)
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}

		ctx := context.Background()

		// Create Docker client without auth (status endpoint doesn't need registry access)
		dockerClient, err := factory(nil, nil)
		if err != nil {
			slog.Error("Error creating Docker client", "error", err)
			http.Error(w, "Error creating Docker client: "+err.Error(), http.StatusInternalServerError)
			return
		}

		container, err := dockerClient.GetContainerByName(ctx, "bondi-service")
		if err != nil {
			slog.Error(fmt.Sprintf("Error getting container %s %v", "bondi-service", err))
			http.Error(w, "Error getting container: "+err.Error(), http.StatusInternalServerError)
			return
		}

		if container == nil {
			http.Error(w, "Container not found", http.StatusNotFound)
			return
		}

		containerJSON, err := dockerClient.InspectContainer(ctx, container.ID)
		if err != nil {
			slog.Error(fmt.Sprintf("Error inspecting container %s %v", container.ID, err))
			http.Error(w, "Error inspecting container: "+err.Error(), http.StatusInternalServerError)
			return
		}

		imageName, tag, err := parseImageAndTag(container.Image)
		if err != nil {
			slog.Error(fmt.Sprintf("Error parsing image and tag %s %v", container.Image, err))
			http.Error(w, "Error parsing image and tag: "+err.Error(), http.StatusInternalServerError)
			return
		}

		status := ContainerStatus{
			ImageName:    imageName,
			Tag:          tag,
			CreatedAt:    containerJSON.Created,
			RestartCount: int64(containerJSON.RestartCount),
			Status:       containerJSON.State.Status,
		}

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(status); err != nil {
			slog.Error("Error encoding response", "error", err)
			http.Error(w, "Error encoding response: "+err.Error(), http.StatusInternalServerError)
		}
	}
}

// parseImageAndTag splits an image string like "image:tag" into name and tag.
func parseImageAndTag(image string) (name, tag string, err error) {
	parts := strings.Split(image, ":")
	if len(parts) == 1 {
		return parts[0], "", nil
	} else if len(parts) == 2 { //nolint:mnd // image and tag are separated by a colon
		return parts[0], parts[1], nil
	}

	return "", "", fmt.Errorf("invalid image format: %s", image)
}
