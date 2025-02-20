package strategies

import (
	"context"
	"fmt"
	"log"
	"log/slog"
	"strconv"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/network"
	"github.com/docker/go-connections/nat"
	"github.com/puravida-software/bondi/server/internal/deployment/models"
	"github.com/puravida-software/bondi/server/internal/docker"
	"github.com/puravida-software/bondi/server/traefik"
)

const _defaultNetworkName = "bondi-network"

var _defaultNetworkingConfig = &network.NetworkingConfig{
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
		_defaultNetworkingConfig,
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

	// Run Traefik
	// TODO: place next to network creation
	if shouldRunTraefik {
		traefikConfig := traefik.Config{
			NetworkName:  _defaultNetworkName,
			DomainName:   *input.TraefikDomainName,
			TraefikImage: *input.TraefikImage,
			ACMEEmail:    *input.TraefikACMEEmail,
		}
		dockerConfig := traefik.GetDockerConfig(traefikConfig)

		_, err = s.dockerClient.RunImageWithOpts(
			ctx,
			dockerConfig.ContainerConfig,
			dockerConfig.HostConfig,
			_defaultNetworkingConfig,
		)
		if err != nil {
			return fmt.Errorf("error running Traefik: %w", err)
		}
	}

	return nil
}

func ServiceConfig(input *models.DeployInput) (*container.Config, *container.HostConfig) {
	newImage := fmt.Sprintf("%s:%s", input.ImageName, input.Tag)

	labels := map[string]string{
		"traefik.enable":                              "true",
		"traefik.http.routers.bondi.rule":             "Host(`your.domain.com`)",
		"traefik.http.routers.bondi.entrypoints":      "websecure",
		"traefik.http.routers.bondi.tls":              "true",
		"traefik.http.routers.bondi.tls.certresolver": "bondi_resolver",
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
