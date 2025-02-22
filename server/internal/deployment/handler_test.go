package deployment

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/network"
	"github.com/puravida-software/bondi/server/internal/deployment/models"
	"github.com/puravida-software/bondi/server/internal/deployment/strategies"
	"github.com/puravida-software/bondi/server/internal/docker"
)

// fakeDockerClient is a dummy implementation of the DockerClient interface.
type fakeDockerClient struct{}

func (f *fakeDockerClient) GetContainerByImageName(_ context.Context, _ string) (*types.Container, error) {
	return nil, nil
}

func (f *fakeDockerClient) GetContainerByID(_ context.Context, _ string) (*types.Container, error) {
	return nil, nil
}

func (f *fakeDockerClient) PullImageWithAuth(_ context.Context, _ string, _ string) error {
	return nil
}

func (f *fakeDockerClient) PullImageNoAuth(_ context.Context, _ string, _ string) error {
	return nil
}

func (f *fakeDockerClient) RemoveContainerAndImage(_ context.Context, _ *types.Container) error {
	return nil
}

func (f *fakeDockerClient) RunImageWithOpts(
	_ context.Context,
	_ *container.Config,
	_ *container.HostConfig,
	_ *network.NetworkingConfig,
) (string, error) {
	return "fake-container-id", nil
}

func (f *fakeDockerClient) StopContainer(_ context.Context, _ string) error {
	return nil
}

func (f *fakeDockerClient) CreateNetworkIfNotExists(_ context.Context, _ string) error {
	return nil
}

// fakeStrategy is a dummy implementation of the Strategy interface.
type fakeStrategy struct {
	deployErr error
}

func (f fakeStrategy) Deploy(_ context.Context, _ *models.DeployInput) error {
	return f.deployErr
}

//nolint:gocyclo,funlen // This is a test file, and we can tolerate a few cyclomatic complexities.
func TestDeploymentHandler(t *testing.T) {
	// dummyFactory always returns a fakeDockerClient without errors.
	dummyFactory := func(_ *string, _ *string) (docker.Client, error) {
		return &fakeDockerClient{}, nil
	}
	// dummyStrategyFactory always returns a fakeStrategy with no deployment error.
	dummyStrategyFactory := func(_ docker.Client) strategies.Strategy {
		return fakeStrategy{deployErr: nil}
	}

	t.Run("method not allowed", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/deploy", nil)
		rr := httptest.NewRecorder()
		handler := NewHandler(dummyFactory, dummyStrategyFactory)
		handler(rr, req)

		if rr.Code != http.StatusMethodNotAllowed {
			t.Errorf("expected status %d, got %d", http.StatusMethodNotAllowed, rr.Code)
		}
		if !strings.Contains(rr.Body.String(), "Method not allowed") {
			t.Errorf("expected body to contain 'Method not allowed', got %q", rr.Body.String())
		}
	})

	t.Run("invalid JSON", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodPost, "/deploy", bytes.NewBufferString("invalid json"))
		rr := httptest.NewRecorder()
		handler := NewHandler(dummyFactory, dummyStrategyFactory)
		handler(rr, req)

		if rr.Code != http.StatusBadRequest {
			t.Errorf("expected status %d, got %d", http.StatusBadRequest, rr.Code)
		}
		if !strings.HasPrefix(rr.Body.String(), "Bad request:") {
			t.Errorf("expected body to start with 'Bad request:', got %q", rr.Body.String())
		}
	})

	t.Run("factory error", func(t *testing.T) {
		validInput := models.DeployInput{
			ImageName: "test-image",
			Tag:       "v1",
			Port:      8080,
			EnvVars:   map[string]string{},
		}
		body, err := json.Marshal(validInput)
		if err != nil {
			t.Fatalf("failed to marshal input: %v", err)
		}
		req := httptest.NewRequest(http.MethodPost, "/deploy", bytes.NewBuffer(body))
		rr := httptest.NewRecorder()

		// errorFactory simulates a failure in creating the Docker client.
		errorFactory := func(_ *string, _ *string) (docker.Client, error) {
			return nil, errors.New("docker client creation error")
		}
		handler := NewHandler(errorFactory, dummyStrategyFactory)
		handler(rr, req)

		if rr.Code != http.StatusInternalServerError {
			t.Errorf("expected status %d, got %d", http.StatusInternalServerError, rr.Code)
		}
		if !strings.Contains(rr.Body.String(), "Error creating Docker client:") {
			t.Errorf("expected error message to contain 'Error creating Docker client:', got %q", rr.Body.String())
		}
	})

	t.Run("strategy deploy error", func(t *testing.T) {
		validInput := models.DeployInput{
			ImageName: "test-image",
			Tag:       "v1",
			Port:      8080,
			EnvVars:   map[string]string{},
		}
		body, err := json.Marshal(validInput)
		if err != nil {
			t.Fatalf("failed to marshal input: %v", err)
		}
		req := httptest.NewRequest(http.MethodPost, "/deploy", bytes.NewBuffer(body))
		rr := httptest.NewRecorder()

		// return a strategy that fails when deploying.
		strategyFactoryWithError := func(_ docker.Client) strategies.Strategy {
			return fakeStrategy{deployErr: errors.New("deployment failure")}
		}
		handler := NewHandler(dummyFactory, strategyFactoryWithError)
		handler(rr, req)

		if rr.Code != http.StatusInternalServerError {
			t.Errorf("expected status %d, got %d", http.StatusInternalServerError, rr.Code)
		}
		if !strings.Contains(rr.Body.String(), "Error deploying:") {
			t.Errorf("expected error message to contain 'Error deploying:', got %q", rr.Body.String())
		}
	})

	t.Run("successful deployment", func(t *testing.T) {
		validInput := models.DeployInput{
			ImageName: "test-image",
			Tag:       "v1",
			Port:      8080,
			EnvVars:   map[string]string{"KEY": "value"},
		}
		body, err := json.Marshal(validInput)
		if err != nil {
			t.Fatalf("failed to marshal input: %v", err)
		}
		req := httptest.NewRequest(http.MethodPost, "/deploy", bytes.NewBuffer(body))
		rr := httptest.NewRecorder()
		handler := NewHandler(dummyFactory, dummyStrategyFactory)
		handler(rr, req)

		if rr.Code != http.StatusOK {
			t.Errorf("expected status %d, got %d", http.StatusOK, rr.Code)
		}
		contentType := rr.Header().Get("Content-Type")
		if contentType != "application/json" {
			t.Errorf("expected Content-Type 'application/json', got %q", contentType)
		}

		// Verify the JSON response.
		var response map[string]string
		responseBody, err := io.ReadAll(rr.Body)
		if err != nil {
			t.Fatalf("failed to read response body: %v", err)
		}
		if err := json.Unmarshal(responseBody, &response); err != nil {
			t.Fatalf("failed to unmarshal response JSON: %v", err)
		}
		if status, ok := response["status"]; !ok || status != "Deploy initiated" {
			t.Errorf("expected status 'Deploy initiated', got %q", status)
		}
		if tag, ok := response["tag"]; !ok || tag != validInput.Tag {
			t.Errorf("expected tag %q, got %q", validInput.Tag, tag)
		}
	})
}
