package cmd

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestStatusCommand(t *testing.T) {
	// Create a test server that returns a mock status response
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}

		if r.URL.Path != "/api/v1/status" {
			http.Error(w, "Not found", http.StatusNotFound)
			return
		}

		status := ContainerStatus{
			ImageName:    "test-image",
			Tag:          "v1.0.0",
			CreatedAt:    time.Date(2024, 1, 1, 12, 0, 0, 0, time.UTC),
			RestartCount: 2,
			Status:       "running",
		}

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(status); err != nil {
			http.Error(w, "Error encoding response: "+err.Error(), http.StatusInternalServerError)
			return
		}
	}))
	defer server.Close()

	// Test the status command
	t.Run("status command", func(t *testing.T) {
		// This is a basic test to ensure the command can be created
		// In a real test, you would mock the config and test the actual execution
		if statusCmd == nil {
			t.Error("statusCmd should not be nil")
		}

		if statusCmd.Use != "status" {
			t.Errorf("expected command use 'status', got %s", statusCmd.Use)
		}
	})
}

func TestContainerStatusJSON(t *testing.T) {
	original := ContainerStatus{
		ImageName:    "test-image",
		Tag:          "v1.0.0",
		CreatedAt:    time.Date(2024, 1, 1, 12, 0, 0, 0, time.UTC),
		RestartCount: 2,
		Status:       "running",
	}

	// Marshal to JSON
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("failed to marshal ContainerStatus: %v", err)
	}

	// Unmarshal from JSON
	var unmarshaled ContainerStatus
	if err := json.Unmarshal(data, &unmarshaled); err != nil {
		t.Fatalf("failed to unmarshal ContainerStatus: %v", err)
	}

	// Compare fields
	if original.ImageName != unmarshaled.ImageName {
		t.Errorf("expected ImageName %s, got %s", original.ImageName, unmarshaled.ImageName)
	}
	if original.Tag != unmarshaled.Tag {
		t.Errorf("expected Tag %s, got %s", original.Tag, unmarshaled.Tag)
	}
	if original.Status != unmarshaled.Status {
		t.Errorf("expected Status %s, got %s", original.Status, unmarshaled.Status)
	}
	if original.RestartCount != unmarshaled.RestartCount {
		t.Errorf("expected RestartCount %d, got %d", original.RestartCount, unmarshaled.RestartCount)
	}
	if !original.CreatedAt.Equal(unmarshaled.CreatedAt) {
		t.Errorf("expected CreatedAt %v, got %v", original.CreatedAt, unmarshaled.CreatedAt)
	}
}
