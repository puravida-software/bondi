package docker

import (
	"fmt"
	"strings"

	"github.com/puravida-software/bondi/cli/internal/config"
	"github.com/puravida-software/bondi/cli/internal/ssh"
)

type RemoteDocker struct {
	server    *config.Server
	remoteRun *ssh.ServerRemoteRun
}

func NewRemoteDocker(server *config.Server, remoteRun *ssh.ServerRemoteRun) *RemoteDocker {
	return &RemoteDocker{server: server, remoteRun: remoteRun}
}

func (d *RemoteDocker) GetDockerVersion() (string, error) {
	versionCmd := "docker --version"
	versionOutput, err := d.remoteRun.RemoteRun(versionCmd)
	if err != nil {
		return "", err
	}

	return versionOutput, nil
}

func (d *RemoteDocker) Ps() (string, error) {
	psCmd := "docker ps"
	psOutput, err := d.remoteRun.RemoteRun(psCmd)
	if err != nil {
		return "", err
	}

	return psOutput, nil
}

func (d *RemoteDocker) Logs(containerName string) (string, error) {
	logsCmd := fmt.Sprintf("docker logs %s", containerName)
	logsOutput, err := d.remoteRun.RemoteRun(logsCmd)
	if err != nil {
		return "", err
	}

	return logsOutput, nil
}

func (d *RemoteDocker) GetRunningVersion() (string, error) {
	versionCmd := "docker ps --filter name=bondi --format '{{.Image}}'"
	versionOutput, err := d.remoteRun.RemoteRun(versionCmd)
	if err != nil {
		return "", err
	}

	runningVersion := strings.TrimPrefix(versionOutput, "mlopez1506/bondi-server:")
	runningVersion = strings.TrimSpace(runningVersion)

	return runningVersion, nil
}

func (d *RemoteDocker) Stop() error {
	stopCmd := "docker stop bondi"
	_, err := d.remoteRun.RemoteRun(stopCmd)
	return err
}
