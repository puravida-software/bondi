package cmd

import (
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/goccy/go-yaml"
	"github.com/puravida-software/bondi/cli/internal/config"
	"github.com/spf13/cobra"
)

// initCmd represents the init command.
var initCmd = &cobra.Command{
	Use:   "init",
	Short: "Initialise configuration or environment",
	Long: `The init command sets up the initial configuration and prepares
the necessary configuration files for the service.`,
	Run: func(_ *cobra.Command, _ []string) {
		if _, err := os.Stat(config.ConfigFileName); err == nil {
			fmt.Println("Bondi already initialised, nothing else to do!")
			return
		}
		fmt.Println("Initialising Bondi!")

		// Create the config file
		configFile, err := os.Create(config.ConfigFileName)
		if err != nil {
			log.Fatal("Error creating config file:", err)
		}

		folderPath, err := os.Getwd()
		if err != nil {
			log.Fatal("Error getting working directory:", err)
		}

		parts := strings.Split(folderPath, "/")
		folder := parts[len(parts)-1]

		sampleConfig := sampleConfig(folder)

		bytes, err := yaml.Marshal(sampleConfig)
		if err != nil {
			log.Fatal("Error marshalling sample config:", err)
		}

		// Write the config file
		_, err = configFile.Write(bytes)
		if err != nil {
			log.Fatal("Error writing config file:", err)
		}

		fmt.Println("Bondi initialised successfully!")
	},
}

func sampleConfig(projectName string) config.BondiConfig {
	return config.BondiConfig{
		UserService: config.UserService{
			ImageName:    projectName,
			Port:         8080, //nolint:mnd // this is a sample config, hardcoding is fine
			RegistryUser: &[]string{"optional"}[0],
			RegistryPass: &[]string{"optional"}[0],
			EnvVars: map[string]string{
				"ENV": "prod",
			},
			Servers: []config.Server{
				{
					IPAddress: "55.55.55.55",
					SSH: &config.ServerSSH{
						User:           "root",
						PrivateKeyPath: "private_key_path",
						PrivateKeyPass: "pass",
					},
				},
				{
					IPAddress: "55.55.55.56",
					SSH: &config.ServerSSH{
						User:           "root",
						PrivateKeyPath: "private_key_path",
						PrivateKeyPass: "pass",
					},
				},
			},
		},
		BondiServer: config.BondiServer{
			Version: "0.0.0",
		},
	}
}
