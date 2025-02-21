package cmd

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"

	"github.com/puravida-software/bondi/cli/internal/config"
	"github.com/spf13/cobra"
)

// deployCmd represents the deploy command.
var deployCmd = &cobra.Command{
	Use:   "deploy",
	Short: "Deploy the service",
	Long: `The deploy command handles deploying the service
to the configured servers.`,
	Run: func(_ *cobra.Command, args []string) {
		// Grabs the image tag from the first argument
		if len(args) < 1 {
			log.Fatalf("Please provide an image tag as an argument")
		}
		tag := args[0]

		fmt.Println("Deployment process initiated...")

		// Read the Bondi configuration
		cfg, err := config.ReadConfig()
		if err != nil {
			log.Fatalf("Error reading configuration: %v\n", err)
		}

		// TODO: use the same model for the deploy request payload
		// Create the deploy request payload
		payload := map[string]interface{}{
			"image_name":          cfg.UserService.ImageName,
			"tag":                 tag,
			"port":                cfg.UserService.Port,
			"env_vars":            cfg.UserService.EnvVars,
			"traefik_domain_name": cfg.Traefik.DomainName,
			"traefik_image":       cfg.Traefik.Image,
			"traefik_acme_email":  cfg.Traefik.ACMEEmail,
		}

		// Include the registry credentials if they are provided
		if cfg.UserService.RegistryUser != nil {
			payload["registry_user"] = *cfg.UserService.RegistryUser
		}
		if cfg.UserService.RegistryPass != nil {
			payload["registry_pass"] = *cfg.UserService.RegistryPass
		}

		payloadBytes, err := json.Marshal(payload)
		if err != nil {
			log.Fatalf("Error marshalling deployment payload: %v\n", err)
		}

		// Iterate over all servers defined in the configuration, calling the /deploy endpoint on each.
		for _, server := range cfg.UserService.Servers {
			url := fmt.Sprintf("http://%s:3030/deploy", server.IPAddress)
			fmt.Printf("Deploying to server: %s at %s\n", server.IPAddress, url)

			req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(payloadBytes))
			if err != nil {
				log.Fatalf("Error creating request for server %s: %v\n", server.IPAddress, err)
			}
			req.Header.Set("Content-Type", "application/json")

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				log.Fatalf("Error calling deploy endpoint on server %s: %v\n", server.IPAddress, err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != http.StatusOK {
				body, _ := io.ReadAll(resp.Body)
				log.Fatalf("Non-OK response from server %s: %s\n", server.IPAddress, string(body))
			}

			fmt.Printf("Deployment initiated on server %s\n", server.IPAddress)
		}
	},
}

func init() {
	// Add a flag to capture the image tag to deploy.
	deployCmd.Flags().String("tag", "", "Image tag to deploy")
	// The deployCmd is registered in root.go already.
}
