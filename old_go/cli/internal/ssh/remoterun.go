package ssh

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"net"
	"os"
	"path/filepath"

	"github.com/puravida-software/bondi/cli/internal/config"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

type ServerRemoteRun struct {
	User               string
	Addr               string
	PrivateKeyContents string
	PrivateKeyPass     string
}

func NewServerRemoteRun(server *config.Server) *ServerRemoteRun {
	return &ServerRemoteRun{
		User:               server.SSH.User,
		Addr:               server.IPAddress,
		PrivateKeyContents: server.SSH.PrivateKeyContents,
		PrivateKeyPass:     server.SSH.PrivateKeyPass,
	}
}

func (s *ServerRemoteRun) RemoteRun(cmd string) (string, error) {
	return RemoteRun(s.User, s.Addr, s.PrivateKeyContents, s.PrivateKeyPass, cmd)
}

// RemoteRun executes a command on a remote server via SSH.
// It now uses known_hosts file validation for the server's host key.
func RemoteRun(user string, addr string, privateKeyContents string, privateKeyPass string, cmd string) (string, error) {
	decodedKey, err := base64.StdEncoding.DecodeString(privateKeyContents)
	if err != nil {
		return "", fmt.Errorf("failed to decode private key: %w", err)
	}
	// Parse the private key (with passphrase)
	key, err := ssh.ParsePrivateKeyWithPassphrase(decodedKey, []byte(privateKeyPass))
	if err != nil {
		return "", fmt.Errorf("failed to parse private key: %w", err)
	}

	// Create a HostKeyCallback based on the user's known_hosts file.
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("failed to get home directory: %w", err)
	}
	knownHostsPath := filepath.Join(homeDir, ".ssh", "known_hosts")
	hostKeyCallback, err := knownhosts.New(knownHostsPath)
	if err != nil {
		return "", fmt.Errorf("failed to create host key callback, verify your known_hosts file is present: %w", err)
	}

	// Authentication configuration with host key validation.
	config := &ssh.ClientConfig{
		User:            user,
		HostKeyCallback: hostKeyCallback,
		Auth: []ssh.AuthMethod{
			ssh.PublicKeys(key),
		},
	}

	// Connect to the remote SSH server.
	client, err := ssh.Dial("tcp", net.JoinHostPort(addr, "22"), config)
	if err != nil {
		return "", fmt.Errorf("failed to connect to server: %w", err)
	}

	// Create a new session for running the command.
	session, err := client.NewSession()
	if err != nil {
		return "", fmt.Errorf("failed to create session: %w", err)
	}
	defer session.Close()

	var b bytes.Buffer
	session.Stdout = &b

	// Run the remote command.
	err = session.Run(cmd)
	if err != nil {
		return "", fmt.Errorf("failed to run command: %w", err)
	}
	return b.String(), nil
}
