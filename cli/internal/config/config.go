package config

import (
	"bytes"
	"fmt"
	"os"
	"strings"
	"text/template"

	"github.com/goccy/go-yaml"
)

const ConfigFileName = "bondi.yaml"

type BondiConfig struct {
	UserService UserService `yaml:"service"`
	BondiServer BondiServer `yaml:"bondi_server"`
	Traefik     Traefik     `yaml:"traefik"`
}

type Traefik struct {
	DomainName string `yaml:"domain_name"`
	Image      string `yaml:"image"`
	ACMEEmail  string `yaml:"acme_email"`
}

type Server struct {
	IPAddress string     `yaml:"ip_address"`
	SSH       *ServerSSH `yaml:"ssh,omitempty"`
}

type ServerSSH struct {
	User           string `yaml:"user"`
	PrivateKeyPath string `yaml:"private_key_path"`
	PrivateKeyPass string `yaml:"private_key_pass"`
}

type UserService struct {
	ImageName    string            `yaml:"image_name"`
	Port         int               `yaml:"port"`
	RegistryUser *string           `yaml:"registry_user,omitempty"`
	RegistryPass *string           `yaml:"registry_pass,omitempty"`
	EnvVars      map[string]string `yaml:"env_vars"`
	Servers      []Server          `yaml:"servers"`
}

type BondiServer struct {
	Version string `yaml:"version"`
}

func ReadConfig() (*BondiConfig, error) {
	fileBytes, err := os.ReadFile(ConfigFileName)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	// Convert env vars to a map
	envMap := envToMap()

	return parseConfig(fileBytes, envMap)
}

func parseConfig(fileBytes []byte, envMap map[string]string) (*BondiConfig, error) {
	// Execute the template with env vars
	var b bytes.Buffer
	t := template.Must(template.New("config").Parse(string(fileBytes)))
	err := t.Execute(&b, envMap)
	if err != nil {
		return nil, fmt.Errorf("failed to execute template: %w", err)
	}

	// Unmarshal the config
	y := b.Bytes()
	var config BondiConfig
	if err := yaml.Unmarshal(y, &config); err != nil {
		return nil, fmt.Errorf("failed to unmarshal config: %w", err)
	}

	return &config, nil
}

func envToMap() map[string]string {
	envMap := make(map[string]string)

	// TODO: what are the implications loading all env vars into memory?
	for _, v := range os.Environ() {
		splitV := strings.SplitN(v, "=", 2) //nolint:mnd // changing this wouldn't improve anything, we'd just be silencing the linter
		envMap[splitV[0]] = splitV[1]
	}

	return envMap
}

func SampleConfig(projectName string) BondiConfig {
	return BondiConfig{
		UserService: UserService{
			ImageName:    projectName,
			Port:         8080, //nolint:mnd // this is a sample config, hardcoding is fine
			RegistryUser: &[]string{"optional"}[0],
			RegistryPass: &[]string{"optional"}[0],
			EnvVars: map[string]string{
				"ENV": "prod",
			},
			Servers: []Server{
				{
					IPAddress: "55.55.55.55",
					SSH: &ServerSSH{
						User:           "root",
						PrivateKeyPath: "private_key_path",
						PrivateKeyPass: "pass",
					},
				},
				{
					IPAddress: "55.55.55.56",
					SSH: &ServerSSH{
						User:           "root",
						PrivateKeyPath: "private_key_path",
						PrivateKeyPass: "pass",
					},
				},
			},
		},
		BondiServer: BondiServer{
			Version: "0.0.0",
		},
	}
}
