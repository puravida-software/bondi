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
		Labels: map[string]string{
			// Enable Traefik to handle ACME HTTP challenge even with redirect
			"traefik.http.middlewares.acme-http.redirectscheme.permanent": "false",
			"traefik.http.routers.acme-http.rule":                         "PathPrefix(`/.well-known/acme-challenge/`)",
			"traefik.http.routers.acme-http.entrypoints":                  "web",
			"traefik.http.routers.acme-http.middlewares":                  "acme-http",
			"traefik.http.routers.acme-http.service":                      "acme-http",
			"traefik.http.services.acme-http.loadbalancer.server.port":    "80",
		},
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
			"--certificatesResolvers.bondi_resolver.acme.httpchallenge=true",
			"--certificatesResolvers.bondi_resolver.acme.httpchallenge.entrypoint=web",
			// TODO: is this needed?
			"--certificatesresolvers.bondi_resolver.acme.dnschallenge.resolvers=1.1.1.1:53,8.8.8.8:53",
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
			"/var/run/docker.sock:/var/run/docker.sock",   // Mount Docker socket to allow Traefik to discover containers
			"/etc/traefik/acme/acme.json:/acme/acme.json", // Mount ACME storage as read-only to prevent permission changes
		},
	}

	return &DockerConfig{
		ContainerConfig: containerConfig,
		HostConfig:      hostConfig,
	}
}
