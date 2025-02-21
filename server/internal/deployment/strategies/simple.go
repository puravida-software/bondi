package strategies

import (
	"context"
	"fmt"
	"log"
	"log/slog"
	"strconv"
	"time"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/network"
	"github.com/docker/go-connections/nat"
	"github.com/puravida-software/bondi/server/internal/deployment/models"
	"github.com/puravida-software/bondi/server/internal/docker"
	"github.com/puravida-software/bondi/server/internal/docker/traefik"
)

const _defaultNetworkName = "bondi-network"

var defaultNetworkingConfig = &network.NetworkingConfig{
	EndpointsConfig: map[string]*network.EndpointSettings{
		_defaultNetworkName: {},
	},
}

type SimpleDeployment struct {
	dockerClient docker.Client
}

func NewSimpleDeployment(dockerClient docker.Client) *SimpleDeployment {
	return &SimpleDeployment{dockerClient: dockerClient}
}

func (s *SimpleDeployment) Deploy(ctx context.Context, input *models.DeployInput) error {
	shouldRunTraefik := input.TraefikDomainName != nil && input.TraefikImage != nil && input.TraefikACMEEmail != nil
	if shouldRunTraefik {
		slog.Info("Creating network", "network_name", _defaultNetworkName)
		// Create a new network if it doesn't exist
		err := s.dockerClient.CreateNetwork(ctx, _defaultNetworkName)
		if err != nil {
			return fmt.Errorf("error creating network: %w", err)
		}

		traefikContainerID, err := s.runTraefik(ctx, input)
		if err != nil {
			return fmt.Errorf("error running Traefik: %w", err)
		}

		err = waitForTraefik(ctx, s.dockerClient, traefikContainerID)
		if err != nil {
			return fmt.Errorf("error waiting for Traefik to start: %w", err)
		}
	} else {
		slog.Info("Skipping network creation, Traefik is not enabled...")
	}

	// Get current container
	currentContainer, err := s.dockerClient.GetContainer(ctx, input.ImageName)
	if err != nil {
		return fmt.Errorf("error getting container: %w", err)
	}
	if currentContainer == nil {
		slog.Info("Container not found for image, assuming a fresh deployment...", "image_name", input.ImageName)
	}

	// Pull the new image
	err = s.dockerClient.PullImage(ctx, input.ImageName, input.Tag)
	if err != nil {
		return fmt.Errorf("error pulling image: %w", err)
	}

	// Stop current container
	if currentContainer != nil {
		err = s.dockerClient.StopContainer(ctx, currentContainer.ID)
		if err != nil {
			return fmt.Errorf("error stopping container: %w", err)
		}
	}

	// Start new container
	conf, hostConf := ServiceConfig(input)
	newContainerID, err := s.dockerClient.RunImageWithOpts(
		ctx,
		conf,
		hostConf,
		defaultNetworkingConfig,
	)
	if err != nil {
		return fmt.Errorf("error running image: %w", err)
	}
	slog.Info("Started new container", "container_id", newContainerID)

	// Remove old image
	if currentContainer != nil {
		err = s.dockerClient.RemoveContainerAndImage(ctx, currentContainer)
		if err != nil {
			return fmt.Errorf("error removing image: %w", err)
		}
		slog.Info("Removed old image", "image_id", currentContainer.ImageID)
	}

	return nil
}

func (s *SimpleDeployment) runTraefik(ctx context.Context, input *models.DeployInput) (string, error) {
	traefikConfig := traefik.Config{
		NetworkName:  _defaultNetworkName,
		DomainName:   *input.TraefikDomainName,
		TraefikImage: *input.TraefikImage,
		ACMEEmail:    *input.TraefikACMEEmail,
	}
	dockerConfig := traefik.GetDockerConfig(traefikConfig)

	containerID, err := s.dockerClient.RunImageWithOpts(
		ctx,
		dockerConfig.ContainerConfig,
		dockerConfig.HostConfig,
		defaultNetworkingConfig,
	)
	if err != nil {
		return "", err
	}
	return containerID, nil
}

func waitForTraefik(ctx context.Context, dockerClient docker.Client, traefikContainerID string) error {
	// TODO: configure timeouts
	// TODO: try using the /ping endpoint instead
	// Maximum number of retries
	maxRetries := 30 // 30 seconds timeout

	lastState := ""
	for i := 0; i < maxRetries; i++ {
		container, err := dockerClient.GetContainer(ctx, traefikContainerID)
		if err != nil {
			return fmt.Errorf("error inspecting Traefik container: %w", err)
		}

		slog.Info("Traefik container state", "state", container.State)
		slog.Info("Traefik container status", "status", container.Status)
		if container.State == "running" {
			slog.Info("Traefik is running", "container_id", traefikContainerID)
			return nil
		}
		lastState = container.State

		// Wait for 1 second before next check
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
			continue
		}
	}

	return fmt.Errorf("timeout waiting for Traefik to start, last state: %s", lastState)
}

func ServiceConfig(input *models.DeployInput) (*container.Config, *container.HostConfig) {
	newImage := fmt.Sprintf("%s:%s", input.ImageName, input.Tag)

	// TODO: enable TLS
	labels := map[string]string{
		"traefik.enable":                  "true",
		"traefik.http.routers.bondi.rule": fmt.Sprintf("Host(`%s`)", *input.TraefikDomainName),
		// "traefik.http.routers.bondi.entrypoints":      "websecure",
		"traefik.http.routers.bondi.entrypoints": "web",
		// "traefik.http.routers.bondi.tls":              "true",
		// "traefik.http.routers.bondi.tls.certresolver": "bondi_resolver",
	}

	env := []string{}
	for k, v := range input.EnvVars {
		env = append(env, fmt.Sprintf("%s=%s", k, v))
	}

	conf := container.Config{
		Image:  newImage,
		Env:    env,
		Labels: labels,
	}
	log.Printf("conf: %v", conf)
	hostConf := container.HostConfig{
		PortBindings: map[nat.Port][]nat.PortBinding{
			nat.Port(fmt.Sprintf("%d/tcp", input.Port)): {{HostIP: "0.0.0.0", HostPort: strconv.Itoa(input.Port)}},
		},
	}

	return &conf, &hostConf
}
