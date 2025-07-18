package strategies

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/network"
	"github.com/docker/go-connections/nat"
	"github.com/puravida-software/bondi/server/internal/deployment/models"
	"github.com/puravida-software/bondi/server/internal/docker"
	"github.com/puravida-software/bondi/server/internal/docker/traefik"
)

const (
	_defaultNetworkName = "bondi-network"
	_serviceName        = "bondi-service"
	_traefikName        = "bondi-traefik"
)

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
		err := s.dockerClient.CreateNetworkIfNotExists(ctx, _defaultNetworkName)
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
	currentContainer, err := s.dockerClient.GetContainerByImageName(ctx, input.ImageName)
	if err != nil {
		return fmt.Errorf("error getting container: %w", err)
	}
	if currentContainer == nil {
		slog.Info("Container not found for image, assuming a fresh deployment...", "image_name", input.ImageName)
	} else {
		slog.Info("Container found for image", "container_id", currentContainer.ID)
	}

	// Stop current container
	if currentContainer != nil {
		slog.Info("Stopping current container", "container_id", currentContainer.ID)
		err = s.dockerClient.StopContainer(ctx, currentContainer.ID)
		if err != nil {
			return fmt.Errorf("error stopping container: %w", err)
		}

		slog.Info("Removing old image", "image_id", currentContainer.ImageID)
		err = s.dockerClient.RemoveContainerAndImage(ctx, currentContainer)
		if err != nil {
			return fmt.Errorf("error removing image: %w", err)
		}
	} else {
		slog.Info("No container found for image, assuming a fresh deployment...", "image_name", input.ImageName)
	}

	// Pull the new image
	slog.Info("Pulling new image", "image_name", input.ImageName, "tag", input.Tag)
	err = s.dockerClient.PullImageWithAuth(ctx, input.ImageName, input.Tag)
	if err != nil {
		return fmt.Errorf("error pulling image: %w", err)
	}

	// Start new container
	conf := ServiceConfig(input)
	opts := docker.RunImageOptions{
		ContainerName:  _serviceName,
		Config:         conf,
		HostConfig:     nil,
		NetworkingConf: defaultNetworkingConfig,
	}
	newContainerID, err := s.dockerClient.RunImageWithOpts(
		ctx,
		opts,
	)
	if err != nil {
		return fmt.Errorf("error running image %s: %w", input.ImageName, err)
	}
	slog.Info("Started new container", "container_id", newContainerID)

	return nil
}

func (s *SimpleDeployment) runTraefik(ctx context.Context, input *models.DeployInput) (string, error) {
	// TODO: refactor the handling of running images and rerunning them
	// Check if Traefik is already running by image name
	currentTraefik, err := s.dockerClient.GetContainerByImageName(ctx, "traefik")
	if err != nil {
		return "", fmt.Errorf("error getting Traefik container: %w", err)
	}

	if currentTraefik != nil {
		// Extract current version from image tag
		currentVersion := strings.Split(currentTraefik.Image, ":")[1]
		requestedVersion := strings.Split(*input.TraefikImage, ":")[1]

		if currentVersion != requestedVersion {
			slog.Info("Stopping old Traefik version", "current_version", currentVersion, "new_version", requestedVersion)
			err = s.dockerClient.StopContainer(ctx, currentTraefik.ID)
			if err != nil {
				return "", fmt.Errorf("error stopping old Traefik container: %w", err)
			}
			err = s.dockerClient.RemoveContainerAndImage(ctx, currentTraefik)
			if err != nil {
				return "", fmt.Errorf("error removing old Traefik container and image: %w", err)
			}
		} else {
			slog.Info("Traefik already running at requested version", "version", currentVersion)
			return currentTraefik.ID, nil
		}
	}

	if input.TraefikImage == nil || input.TraefikDomainName == nil || input.TraefikACMEEmail == nil {
		return "", errors.New("missing required Traefik configuration")
	}

	// Pull the Traefik image
	imageAndTag := strings.Split(*input.TraefikImage, ":")
	if len(imageAndTag) != 2 { //nolint:mnd // we just expected an image:tag
		return "", fmt.Errorf("invalid Traefik image: %s", *input.TraefikImage)
	}

	err = s.dockerClient.PullImageNoAuth(ctx, imageAndTag[0], imageAndTag[1])
	if err != nil {
		return "", fmt.Errorf("error pulling Traefik image: %w", err)
	}

	traefikConfig := traefik.Config{
		NetworkName:  _defaultNetworkName,
		DomainName:   *input.TraefikDomainName,
		TraefikImage: *input.TraefikImage,
		ACMEEmail:    *input.TraefikACMEEmail,
	}
	dockerConfig := traefik.GetDockerConfig(traefikConfig)

	opts := docker.RunImageOptions{
		ContainerName:  _traefikName,
		Config:         dockerConfig.ContainerConfig,
		HostConfig:     dockerConfig.HostConfig,
		NetworkingConf: defaultNetworkingConfig,
	}
	containerID, err := s.dockerClient.RunImageWithOpts(
		ctx,
		opts,
	)
	if err != nil {
		return "", fmt.Errorf("error running Traefik container: %w", err)
	}
	return containerID, nil
}

func waitForTraefik(ctx context.Context, dockerClient docker.Client, traefikContainerID string) error {
	slog.Info("waiting for Traefik to start", "container_id", traefikContainerID)
	// TODO: configure timeouts
	// TODO: try using the /ping endpoint instead
	// Maximum number of retries
	maxRetries := 30 // 30 seconds timeout

	lastState := ""
	for i := 0; i < maxRetries; i++ {
		container, err := dockerClient.GetContainerByID(ctx, traefikContainerID)
		slog.Info("waiting for Traefik to start", "container", container, "lastState", lastState)
		if err != nil {
			return fmt.Errorf("error inspecting Traefik container: %w", err)
		}
		if container != nil {
			if container.State == "running" {
				slog.Info("Traefik is running", "container_id", traefikContainerID)
				return nil
			}
			lastState = container.State
		}

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

func ServiceConfig(input *models.DeployInput) *container.Config {
	newImage := fmt.Sprintf("%s:%s", input.ImageName, input.Tag)

	labels := map[string]string{
		"traefik.enable":                              "true",
		"traefik.http.routers.bondi.rule":             fmt.Sprintf("Host(`%[1]s`) || Host(`www.%[1]s`)", *input.TraefikDomainName),
		"traefik.http.routers.bondi.entrypoints":      "websecure",
		"traefik.http.routers.bondi.tls":              "true",
		"traefik.http.routers.bondi.tls.certresolver": "bondi_resolver",
	}

	env := []string{}
	for k, v := range input.EnvVars {
		env = append(env, fmt.Sprintf("%s=%s", k, v))
	}

	// Create exposed ports configuration
	exposedPorts := nat.PortSet{
		nat.Port(fmt.Sprintf("%d/tcp", input.Port)): {},
	}

	conf := container.Config{
		Image:        newImage,
		Env:          env,
		Labels:       labels,
		ExposedPorts: exposedPorts,
	}

	return &conf
}
