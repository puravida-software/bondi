package traefik

import (
	"github.com/docker/docker/api/types/container"
	"github.com/docker/go-connections/nat"
)

const defaultTraefikImage = "traefik:v3.3.0"

type Config struct {
	NetworkName  string
	DomainName   string
	TraefikImage string
	ACMEEmail    string
}

type DockerConfig struct {
	ContainerConfig *container.Config
	HostConfig      *container.HostConfig
}

// HTTPS/TLS and HTTP-to-HTTPS redirection.
func GetDockerConfig(config Config) *DockerConfig {
	var image string
	if config.TraefikImage == "" {
		image = defaultTraefikImage
	} else {
		image = config.TraefikImage
	}

	// Define Traefik's container configuration.
	containerConfig := &container.Config{
		Image: image,
		// Pass CLI args to enable the Docker provider, define entrypoints, redirection, and TLS config.
		Cmd: []string{
			"--providers.docker",
			"--providers.docker.exposedbydefault=false",
			"--entrypoints.web.address=:80",
			"--entrypoints.web.http.redirections.entryPoint.to=websecure",
			"--entrypoints.web.http.redirections.entryPoint.scheme=https",
			"--entrypoints.websecure.address=:443",
			"--certificatesResolvers.bondi_resolver.acme.email=" + config.ACMEEmail,
			"--certificatesResolvers.bondi_resolver.acme.storage=/acme/acme.json",
			"--certificatesResolvers.bondi_resolver.acme.tlsChallenge=true",
		},
		ExposedPorts: nat.PortSet{
			"80/tcp":  {},
			"443/tcp": {},
		},
	}

	// Configure how container ports are mapped to host ports.
	hostConfig := &container.HostConfig{
		PortBindings: nat.PortMap{
			"80/tcp": []nat.PortBinding{
				{HostIP: "0.0.0.0", HostPort: "80"},
			},
			"443/tcp": []nat.PortBinding{
				{HostIP: "0.0.0.0", HostPort: "443"},
			},
		},
		// Mount the Traefik configuration file and ACME storage file if needed.
		// Update the host paths accordingly.
		Binds: []string{
			"/var/run/docker.sock:/var/run/docker.sock", // Mount Docker socket to allow Traefik to discover containers
			"/acme/acme.json:/acme/acme.json",           // Must be a file with proper permissions.
		},
	}

	return &DockerConfig{
		ContainerConfig: containerConfig,
		HostConfig:      hostConfig,
	}
}
