package docker

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"strings"

	"github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/image"
	"github.com/docker/docker/api/types/network"
	"github.com/docker/docker/api/types/registry"
	"github.com/docker/docker/client"
)

type Client interface {
	CreateNetworkIfNotExists(ctx context.Context, networkName string) error
	GetContainerByImageName(ctx context.Context, imageName string) (*types.Container, error)
	GetContainerByID(ctx context.Context, containerID string) (*types.Container, error)
	PullImageWithAuth(ctx context.Context, imageName string, tag string) error
	PullImageNoAuth(ctx context.Context, imageName string, tag string) error
	RemoveContainerAndImage(ctx context.Context, cont *types.Container) error
	RunImageWithOpts(ctx context.Context, opts RunImageOptions) (string, error)
	StopContainer(ctx context.Context, containerID string) error
}

type LiveClient struct {
	apiClient    *client.Client
	registryAuth *string
}

func NewDockerClient(registryUser *string, registryPass *string) (Client, error) {
	// Set up the Docker client
	apiClient, err := client.NewClientWithOpts(client.FromEnv)
	if err != nil {
		return nil, fmt.Errorf("error creating Docker client: %w", err)
	}
	defer apiClient.Close()

	dockerClient, err := NewDockerClientWithClient(apiClient, registryUser, registryPass)
	if err != nil {
		return nil, fmt.Errorf("error creating Docker wrapper: %w", err)
	}

	return dockerClient, nil
}

func NewDockerClientWithClient(client *client.Client, registryUser *string, registryPass *string) (*LiveClient, error) {
	if registryUser == nil || registryPass == nil {
		return &LiveClient{apiClient: client, registryAuth: nil}, nil
	}

	authConfig := registry.AuthConfig{
		Username: *registryUser,
		Password: *registryPass,
	}
	jsonBytes, err := json.Marshal(authConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal auth config: %w", err)
	}
	registryAuth := base64.StdEncoding.EncodeToString(jsonBytes)

	return &LiveClient{apiClient: client, registryAuth: &registryAuth}, nil
}

func (c *LiveClient) CreateNetworkIfNotExists(ctx context.Context, networkName string) error {
	networks, err := c.apiClient.NetworkList(ctx, network.ListOptions{})
	if err != nil {
		return fmt.Errorf("failed to list networks: %w", err)
	}

	for _, network := range networks {
		if network.Name == networkName {
			return nil
		}
	}
	_, err = c.apiClient.NetworkCreate(ctx, networkName, network.CreateOptions{
		Driver: "bridge",
	})
	return err
}

func (c *LiveClient) GetContainerByImageName(ctx context.Context, imageName string) (*types.Container, error) {
	containers, err := c.apiClient.ContainerList(ctx, container.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("failed to list containers: %w", err)
	}

	for _, container := range containers {
		if strings.Contains(container.Image, imageName) {
			return &container, nil
		}
	}
	return nil, nil
}

func (c *LiveClient) GetContainerByID(ctx context.Context, containerID string) (*types.Container, error) {
	containers, err := c.apiClient.ContainerList(ctx, container.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("failed to list containers: %w", err)
	}

	for _, container := range containers {
		if container.ID == containerID {
			return &container, nil
		}
	}
	return nil, nil
}

func (c *LiveClient) PullImageWithAuth(ctx context.Context, imageName string, tag string) error {
	pullOpts := image.PullOptions{}
	if c.registryAuth != nil {
		log.Printf("Using registry auth")
		pullOpts.RegistryAuth = *c.registryAuth
	} else {
		log.Printf("No registry auth")
	}

	return c.pullImage(ctx, imageName, tag, pullOpts)
}

func (c *LiveClient) PullImageNoAuth(ctx context.Context, imageName string, tag string) error {
	return c.pullImage(ctx, imageName, tag, image.PullOptions{})
}

func (c *LiveClient) pullImage(ctx context.Context, imageName string, tag string, pullOpts image.PullOptions) error {
	newImage := fmt.Sprintf("%s:%s", imageName, tag)
	log.Printf("Pulling image: %s", newImage)

	response, err := c.apiClient.ImagePull(ctx, newImage, pullOpts)
	if err != nil {
		return fmt.Errorf("failed to pull image: %w", err)
	}
	defer response.Close()

	dec := json.NewDecoder(response)
	for {
		var j map[string]interface{}
		if err := dec.Decode(&j); err != nil {
			if err == io.EOF {
				break
			}
			return fmt.Errorf("failed to decode image pull response: %w", err)
		}
		fmt.Println(j)
	}

	return nil
}

func (c *LiveClient) RemoveContainerAndImage(ctx context.Context, cont *types.Container) error {
	err := c.apiClient.ContainerRemove(ctx, cont.ID, container.RemoveOptions{
		RemoveVolumes: true,
		RemoveLinks:   false,
		Force:         true,
	})
	if err != nil {
		return fmt.Errorf("failed to remove container: %w", err)
	}

	// TODO: do something with the return
	_, err = c.apiClient.ImageRemove(ctx, cont.ImageID, image.RemoveOptions{
		Force:         true,
		PruneChildren: true,
	})
	if err != nil {
		return fmt.Errorf("failed to remove image: %w", err)
	}

	return nil
}

type RunImageOptions struct {
	ContainerName  string
	Config         *container.Config
	HostConfig     *container.HostConfig
	NetworkingConf *network.NetworkingConfig
}

func (c *LiveClient) RunImageWithOpts(ctx context.Context, opts RunImageOptions) (string, error) {
	newContainer, err := c.apiClient.ContainerCreate(ctx, opts.Config, opts.HostConfig, opts.NetworkingConf, nil, opts.ContainerName)
	if err != nil {
		return "", fmt.Errorf("failed to create container: %w", err)
	}

	err = c.apiClient.ContainerStart(ctx, newContainer.ID, container.StartOptions{})
	if err != nil {
		return "", fmt.Errorf("failed to start container: %w", err)
	}

	return newContainer.ID, nil
}

func (c *LiveClient) StopContainer(ctx context.Context, containerID string) error {
	err := c.apiClient.ContainerStop(ctx, containerID, container.StopOptions{
		// 10 seconds
		Timeout: &[]int{10}[0],
	})
	if err != nil {
		return fmt.Errorf("failed to stop container: %w", err)
	}

	return nil
}
