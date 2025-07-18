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

// dockerCmd represents the docker command
var dockerCmd = &cobra.Command{
	Use:   "docker",
	Short: "Docker container management commands",
	Long:  `Docker command provides subcommands to manage Docker containers including listing running containers and viewing logs.`,
}

// dockerPsCmd represents the docker ps command
var dockerPsCmd = &cobra.Command{
	Use:   "ps",
	Short: "List all running containers",
	Long:  `The ps command lists all running Docker containers using 'docker ps'.`,
	Run: func(_ *cobra.Command, _ []string) {
		cfg, err := config.ReadConfig()
		if err != nil {
			log.Fatal(err)
		}

		var output string
		for _, server := range cfg.UserService.Servers {
			remoteRun := ssh.NewServerRemoteRun(&server)
			remoteDocker := docker.NewRemoteDocker(&server, remoteRun)

			// TODO: format the output to be more readable taking into account the server IP address
			psOutput, err := remoteDocker.Ps()
			if err != nil {
				log.Fatal(err)
			}
			output += fmt.Sprintf("[docker ps] Server: %s\n", server.IPAddress)
			output += psOutput
		}
		fmt.Print(output)
	},
}

// dockerLogsCmd represents the docker logs command
var dockerLogsCmd = &cobra.Command{
	Use:   "logs [container-name]",
	Short: "Show logs of a container",
	Long:  `The logs command shows the logs of a specified container using 'docker logs [container-name]'.`,
	Args:  cobra.ExactArgs(1),
	Run: func(_ *cobra.Command, args []string) {
		containerName := strings.TrimSpace(args[0])
		if containerName == "" {
			fmt.Println("Error: container name cannot be empty")
			return
		}

		cfg, err := config.ReadConfig()
		if err != nil {
			log.Fatal(err)
		}

		var output string
		for _, server := range cfg.UserService.Servers {
			remoteRun := ssh.NewServerRemoteRun(&server)
			remoteDocker := docker.NewRemoteDocker(&server, remoteRun)

			logsOutput, err := remoteDocker.Logs(containerName)
			if err != nil {
				log.Fatal(err)
			}

			output += fmt.Sprintf("[docker logs] Server: %s\n", server.IPAddress)
			output += logsOutput
		}
		fmt.Print(output)
	},
}

func init() {
	// Add subcommands to docker command
	dockerCmd.AddCommand(dockerPsCmd)
	dockerCmd.AddCommand(dockerLogsCmd)
}
