package status

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/docker/docker/api/types"
	"github.com/puravida-software/bondi/server/internal/docker"
)

// fakeDockerClient is a dummy implementation of the DockerClient interface for testing.
type fakeDockerClient struct {
	container *types.Container
	err       error
}

func (f *fakeDockerClient) CreateNetworkIfNotExists(_ context.Context, _ string) error {
	return nil
}

func (f *fakeDockerClient) GetContainerByImageName(_ context.Context, _ string) (*types.Container, error) {
	return f.container, f.err
}

func (f *fakeDockerClient) GetContainerByName(_ context.Context, _ string) (*types.Container, error) {
	return f.container, f.err
}

func (f *fakeDockerClient) GetContainerByID(_ context.Context, _ string) (*types.Container, error) {
	return f.container, f.err
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

func (f *fakeDockerClient) RunImageWithOpts(_ context.Context, _ docker.RunImageOptions) (string, error) {
	return "", nil
}

func (f *fakeDockerClient) StopContainer(_ context.Context, _ string) error {
	return nil
}

func (f *fakeDockerClient) InspectContainer(_ context.Context, _ string) (*types.ContainerJSON, error) {
	return &types.ContainerJSON{
		ContainerJSONBase: &types.ContainerJSONBase{
			Created:      time.Now().Format(time.RFC3339),
			RestartCount: 0,
			State: &types.ContainerState{
				Status: "running",
			},
		},
	}, nil
}

func TestStatusHandler(t *testing.T) {
	t.Run("method not allowed", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodPost, "/status", nil)
		rr := httptest.NewRecorder()

		factory := func(_ *string, _ *string) (docker.Client, error) {
			return &fakeDockerClient{}, nil
		}

		handler := NewHandler(factory)
		handler(rr, req)

		if rr.Code != http.StatusMethodNotAllowed {
			t.Errorf("expected status %d, got %d", http.StatusMethodNotAllowed, rr.Code)
		}
	})

	t.Run("container not found", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/status", nil)
		rr := httptest.NewRecorder()

		factory := func(_ *string, _ *string) (docker.Client, error) {
			return &fakeDockerClient{container: nil}, nil
		}

		handler := NewHandler(factory)
		handler(rr, req)

		if rr.Code != http.StatusNotFound {
			t.Errorf("expected status %d, got %d", http.StatusNotFound, rr.Code)
		}
	})

	t.Run("successful status response", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/status", nil)
		rr := httptest.NewRecorder()

		createdTime := time.Now().Unix()
		container := &types.Container{
			ID:      "test-container-id",
			Image:   "test-image:v1.0.0",
			Created: createdTime,
			State:   "running",
		}

		factory := func(_ *string, _ *string) (docker.Client, error) {
			return &fakeDockerClient{container: container}, nil
		}

		handler := NewHandler(factory)
		handler(rr, req)

		if rr.Code != http.StatusOK {
			t.Errorf("expected status %d, got %d", http.StatusOK, rr.Code)
		}

		contentType := rr.Header().Get("Content-Type")
		if contentType != "application/json" {
			t.Errorf("expected Content-Type 'application/json', got %q", contentType)
		}

		var response ContainerStatus
		if err := json.NewDecoder(rr.Body).Decode(&response); err != nil {
			t.Fatalf("failed to decode response JSON: %v", err)
		}

		if response.ImageName != "test-image" {
			t.Errorf("expected image name 'test-image', got %q", response.ImageName)
		}
		if response.Tag != "v1.0.0" {
			t.Errorf("expected tag 'v1.0.0', got %q", response.Tag)
		}
		if response.Status != "running" {
			t.Errorf("expected status 'running', got %q", response.Status)
		}
		if response.CreatedAt != time.Unix(createdTime, 0).Format(time.RFC3339) {
			t.Errorf("expected created time %s, got %s", time.Unix(createdTime, 0).Format(time.RFC3339), response.CreatedAt)
		}
	})
}

func TestParseImageAndTag(t *testing.T) {
	tests := []struct {
		name     string
		image    string
		expected *struct {
			name string
			tag  string
		}
	}{
		{
			name:  "image with tag",
			image: "test-image:v1.0.0",
			expected: &struct {
				name string
				tag  string
			}{
				name: "test-image",
				tag:  "v1.0.0",
			},
		},
		{
			name:  "image without tag",
			image: "test-image",
			expected: &struct {
				name string
				tag  string
			}{
				name: "test-image",
				tag:  "",
			},
		},
		{
			name:     "image with multiple colons",
			image:    "registry.example.com:5000/test-image:v1.0.0",
			expected: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			name, tag, err := parseImageAndTag(tt.image)
			if tt.expected == nil {
				if err == nil {
					t.Errorf("expected error, got nil")
				}
			} else {
				if err != nil {
					t.Errorf("expected no error, got %v", err)
				}
				if name != tt.expected.name {
					t.Errorf("expected name %q, got %q", tt.expected.name, name)
				}
				if tag != tt.expected.tag {
					t.Errorf("expected tag %q, got %q", tt.expected.tag, tag)
				}
			}
		})
	}
}
