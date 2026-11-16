package localapi

import (
	"bytes"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/OrangeMagician/codex-account-bridge/internal/codex"
	"github.com/OrangeMagician/codex-account-bridge/internal/config"
)

const label = "com.orangemagician.codex-account-bridge.local-api"

type Status struct {
	Enabled bool   `json:"enabled"`
	Running bool   `json:"running"`
	Account string `json:"account"`
	Listen  string `json:"listen"`
	Client  string `json:"client"`
	Model   string `json:"model"`
}

func agentPath() (string, error) {
	home, err := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", label+".plist"), err
}
func domain() string { return fmt.Sprintf("gui/%d", os.Getuid()) }
func jobLoaded() bool {
	return exec.Command("/bin/launchctl", "print", domain()+"/"+label).Run() == nil
}

func GetStatus(paths config.Paths) (Status, error) {
	status := Status{Listen: "127.0.0.1:8787", Client: "127.0.0.1", Model: Model}
	settings, err := config.ReadAPISettings(paths)
	if err != nil {
		return status, err
	}
	status.Account = settings.Account
	if runtime.GOOS != "darwin" {
		return status, nil
	}
	path, err := agentPath()
	if err != nil {
		return status, err
	}
	if _, err = os.Lstat(path); errors.Is(err, os.ErrNotExist) {
		return status, nil
	} else if err != nil {
		return status, err
	}
	status.Enabled = true
	data, err := exec.Command("/usr/bin/plutil", "-extract", "ProgramArguments", "json", "-o", "-", path).Output()
	var args []string
	if err != nil || json.Unmarshal(data, &args) != nil || len(args) != 7 || args[1] != "api" || args[2] != "serve" {
		return status, errors.New("invalid CAB API launch agent")
	}
	status.Listen, status.Client = args[4], args[6]
	data, err = exec.Command("/bin/launchctl", "print", domain()+"/"+label).Output()
	status.Running = err == nil && strings.Contains(string(data), "\n\tstate = running\n")
	return status, nil
}

func xmlString(v string) string {
	var b bytes.Buffer
	_ = xml.EscapeText(&b, []byte(v))
	return "<string>" + b.String() + "</string>"
}

func Start(paths config.Paths, listen, client string) error {
	if runtime.GOOS != "darwin" {
		return errors.New("use cab api serve on this platform")
	}
	if err := CheckNetwork(listen, client); err != nil {
		return err
	}
	settings, err := config.ReadAPISettings(paths)
	if err != nil {
		return err
	}
	cfg, err := config.Load(paths)
	if err != nil {
		return err
	}
	account, ok := cfg.Find(settings.Account)
	if !ok || account.Home != settings.Home {
		return errors.New("select a registered API account first")
	}
	path, err := agentPath()
	if err != nil {
		return err
	}
	if _, err := os.Lstat(path); err == nil || jobLoaded() {
		return errors.New("stop the configured API service before starting it again")
	}
	listener, err := net.Listen("tcp", listen)
	if err != nil {
		return err
	}
	listener.Close()
	binary, err := os.Executable()
	if err != nil {
		return err
	}
	binary, err = filepath.EvalSymlinks(binary)
	if err != nil {
		return err
	}
	official, err := codex.FindReal("codex")
	if err != nil {
		return err
	}
	args := ""
	for _, arg := range []string{binary, "api", "serve", "--listen", listen, "--client", client} {
		args += xmlString(arg)
	}
	env := ""
	for _, v := range [][2]string{{"CAB_CONFIG_HOME", paths.ConfigDir}, {"CAB_DATA_HOME", paths.DataDir}, {"CAB_REAL_CODEX", official}, {"PATH", os.Getenv("PATH")}} {
		env += "<key>" + v[0] + "</key>" + xmlString(v[1])
	}
	plist := "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>Label</key>" + xmlString(label) + "<key>ProgramArguments</key><array>" + args + "</array><key>EnvironmentVariables</key><dict>" + env + "</dict><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer></dict></plist>"
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = file.WriteString(plist)
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		os.Remove(path)
		return err
	}
	if out, err := exec.Command("/bin/launchctl", "bootstrap", domain(), path).CombinedOutput(); err != nil {
		os.Remove(path)
		return fmt.Errorf("launchctl bootstrap: %s", strings.TrimSpace(string(out)))
	}
	deadline := time.Now().Add(6 * time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", listen, 200*time.Millisecond)
		if err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err := Stop(); err != nil {
		return fmt.Errorf("API listener failed to start: %w", err)
	}
	return errors.New("API listener failed to start")
}

func Stop() error {
	if runtime.GOOS != "darwin" {
		return errors.New("stop the foreground cab api serve process")
	}
	path, err := agentPath()
	if err != nil {
		return err
	}
	if jobLoaded() {
		if out, err := exec.Command("/bin/launchctl", "bootout", domain()+"/"+label).CombinedOutput(); err != nil {
			return fmt.Errorf("launchctl bootout: %s", strings.TrimSpace(string(out)))
		}
	}
	if err = os.Remove(path); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
