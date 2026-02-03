package cmd

import (
	"fmt"
	"log"
	"strings"

	"github.com/puravida-software/bondi/cli/internal/config"
	"github.com/puravida-software/bondi/cli/internal/docker"
	"github.com/puravida-software/bondi/cli/internal/ssh"
	"github.com/spf13/cobra"
)

// setupCmd represents the setup command.
var setupCmd = &cobra.Command{
	Use:   "setup",
	Short: "Setup the environment for running the Bondi server and your services",
	Long: `The setup command configures the servers and prepares all
the dependencies required for the Bondi server and your services. It verifies Docker is installed,
installs it otherwise, and runs the Bondi server.`,
	Run: func(_ *cobra.Command, _ []string) {
		fmt.Println("Setting up the servers...")

		// Read configuration.
		cfg, err := config.ReadConfig()
		if err != nil {
			log.Fatal(err)
		}

		// For each server, check if Docker is installed,
		// install it if missing, and then run the Bondi server docker image.
		for _, server := range cfg.UserService.Servers {
			fmt.Printf("Processing server: %s\n", server.IPAddress)

			remoteRun := ssh.NewServerRemoteRun(&server)
			remoteDocker := docker.NewRemoteDocker(&server, remoteRun)

			// Check whether Docker is installed on the server.
			versionOutput, err := remoteDocker.GetDockerVersion()
			if err != nil || strings.Contains(versionOutput, "command not found") {
				fmt.Printf("Docker not found on server %s\nError: %v\nInstalling Docker...\n", server.IPAddress, err)
				// Install Docker using the official installation script.
				installCmd := `curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh`
				installOutput, err := remoteRun.RemoteRun(installCmd)
				if err != nil {
					log.Fatalf("Failed to install Docker on server %s: %v. Output: %s", server.IPAddress, err, installOutput)
				}
				fmt.Printf("Docker installed on server %s: %s\n", server.IPAddress, installOutput)
			} else {
				fmt.Printf("Docker is already installed on server %s: %s\n", server.IPAddress, versionOutput)
			}

			// TODO: extract this to a function
			// Create ACME file on server if it doesn't exist.
			acmeDir := "/etc/traefik/acme"
			acmeFile := acmeDir + "/acme.json"
			if _, err := remoteRun.RemoteRun("test -f " + acmeFile); err != nil {
				// Create directory and file, set ownership to root:root, and set permissions to 600
				acmeFileOutput, err := remoteRun.RemoteRun(fmt.Sprintf(
					"sudo mkdir -p %s && "+
						"sudo touch %s && "+
						"sudo chown root:root %s && "+
						"sudo chmod 600 %s",
					acmeDir, acmeFile, acmeFile, acmeFile))
				if err != nil {
					log.Fatalf("Failed to create ACME file on server %s: %v. Output: %s", server.IPAddress, err, acmeFileOutput)
				}
				fmt.Printf("ACME file created on server %s: %s\n", server.IPAddress, acmeFileOutput)
			} else {
				// If file exists, ensure it has correct permissions
				acmeFileOutput, err := remoteRun.RemoteRun(fmt.Sprintf(
					"sudo chown root:root %s && "+
						"sudo chmod 600 %s",
					acmeFile, acmeFile))
				if err != nil {
					log.Fatalf("Failed to set permissions on ACME file on server %s: %v. Output: %s", server.IPAddress, err, acmeFileOutput)
				}
				fmt.Printf("ACME file permissions updated on server %s: %s\n", server.IPAddress, acmeFile)
			}

			// Check if Bondi server is already running
			runningVersion, err := remoteDocker.GetRunningVersion()
			if err != nil {
				log.Fatalf("Failed to check if bondi-server Docker image is running on %s: %v", server.IPAddress, err)
			}

			if runningVersion != "" && runningVersion == cfg.BondiServer.Version {
				fmt.Printf("bondi-server Docker image is already running on server %s: %s, skipping...\n", server.IPAddress, runningVersion)
				continue
			} else if runningVersion != "" && runningVersion != cfg.BondiServer.Version {
				fmt.Printf("bondi-server Docker image version mismatch on server %s: running %s, want %s, stopping current server to run the new version...\n", server.IPAddress, runningVersion, cfg.BondiServer.Version)
				err := remoteDocker.Stop()
				if err != nil {
					log.Fatalf("Failed to stop bondi-server Docker image on %s: %v", server.IPAddress, err)
				}
				fmt.Printf("Stopped bondi-server Docker image on server %s\n", server.IPAddress)
			}

			// Run the Bondi server docker image.
			// Adjust the docker run parameters as needed for port mappings, environment variables, etc.
			runCmd := "docker run -d --name bondi -p 3030:3030 -v /var/run/docker.sock:/var/run/docker.sock --group-add $(stat -c %g /var/run/docker.sock) --rm mlopez1506/bondi-server:" + cfg.BondiServer.Version
			runOutput, err := remoteRun.RemoteRun(runCmd)
			if err != nil {
				log.Fatalf("Failed to run bondi-server docker image on server %s: %v. Output: %s", server.IPAddress, err, runOutput)
			}
			fmt.Printf("bondi-server docker image started on server %s: %s\n", server.IPAddress, runOutput)
		}
	},
}
