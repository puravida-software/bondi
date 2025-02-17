package docker

import (
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
