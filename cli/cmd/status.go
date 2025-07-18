package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/puravida-software/bondi/cli/internal/config"
	"github.com/spf13/cobra"
)

// ContainerStatus represents the response from the status endpoint
type ContainerStatus struct {
	ImageName    string    `json:"image_name"`
	Tag          string    `json:"tag"`
	CreatedAt    time.Time `json:"created_at"`
	RestartCount int64     `json:"restart_count"`
	Status       string    `json:"status"`
}

// statusCmd represents the status command.
var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Get the status of the bondi_service container",
	Long: `The status command retrieves information about the bondi_service container
from all configured servers, including image name, tag, creation time, restart count, and status.`,
	Run: func(_ *cobra.Command, args []string) {
		statusPerServer := make(map[string]ContainerStatus)

		cfg, err := config.ReadConfig()
		if err != nil {
			log.Fatalf("Error reading configuration: %v\n", err)
		}

		// Iterate over all servers defined in the configuration, calling the /status endpoint on each.
		for _, server := range cfg.UserService.Servers {
			url := fmt.Sprintf("http://%s:3030/api/v1/status", server.IPAddress)

			req, err := http.NewRequest(http.MethodGet, url, nil)
			if err != nil {
				log.Printf("Error creating request for server %s: %v\n", server.IPAddress, err)
				continue
			}

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				log.Printf("Error calling status endpoint on server %s: %v\n", server.IPAddress, err)
				continue
			}
			defer resp.Body.Close()

			if resp.StatusCode == http.StatusNotFound {
				fmt.Printf("Status: Container not found\n")
				continue
			}

			if resp.StatusCode != http.StatusOK {
				body, _ := io.ReadAll(resp.Body)
				log.Printf("Non-OK response from server %s: %s\n", server.IPAddress, string(body))
				continue
			}

			// Parse the response
			var status ContainerStatus
			if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
				log.Printf("Error decoding response from server %s: %v\n", server.IPAddress, err)
				continue
			}

			statusPerServer[server.IPAddress] = status
		}

		// Print the status of all servers in JSON format
		jsonOutput, err := json.MarshalIndent(statusPerServer, "", "    ")
		if err != nil {
			log.Printf("Error marshaling status to JSON: %v\n", err)
			return
		}
		fmt.Println(string(jsonOutput))
	},
}

func init() {
	// The statusCmd is registered in root.go
}
