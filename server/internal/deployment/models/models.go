package models

type DeployInput struct {
	ImageName    string            `json:"image_name"`
	Tag          string            `json:"tag"`
	Port         int               `json:"port"`
	RegistryUser *string           `json:"registry_user"`
	RegistryPass *string           `json:"registry_pass"`
	EnvVars      map[string]string `json:"env_vars"`
}
