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

	// Execute the template with env vars
	var b bytes.Buffer
	t := template.Must(template.New("config").Parse(string(fileBytes)))
	err = t.Execute(&b, envMap)
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
