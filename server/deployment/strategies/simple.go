package strategies

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/puravida-software/bondi/server/deployment/models"
	"github.com/puravida-software/bondi/server/docker"
)

type SimpleDeployment struct {
	dockerClient docker.Client
}

func NewSimpleDeployment(dockerClient docker.Client) *SimpleDeployment {
	return &SimpleDeployment{dockerClient: dockerClient}
}

func (s *SimpleDeployment) Deploy(ctx context.Context, input *models.DeployInput) error {
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
	opts := docker.RunImageOptions{
		ImageName: input.ImageName,
		Tag:       input.Tag,
		Port:      input.Port,
		EnvVars:   input.EnvVars,
	}
	newContainerID, err := s.dockerClient.RunImage(ctx, opts)
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
