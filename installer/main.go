// SPDX-License-Identifier: Apache-2.0
// Mjolnir installer: a small static Go binary for the live ISO. It pulls the
// bootc image from a registry and installs it to disk with `bootc install`.
// All external commands are executed as argv through a runner; no shell is used.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

const defaultImage = "ghcr.io/huntedraven7/mjolnir:stable"

type config struct {
	Image      string `json:"image"`
	Disk       string `json:"disk"`
	SSID       string `json:"ssid"`
	PSK        string `json:"psk"`
	RegUser    string `json:"registryUser"`
	RegToken   string `json:"registryToken"`
	Role       string `json:"role"`
	Hostname   string `json:"hostname"`
	Timezone   string `json:"timezone"`
	DryRun     bool   `json:"dryRun"`
	Reboot     bool   `json:"reboot"`
	Filesystem string `json:"filesystem"`
}

type runner interface {
	run(name string, args ...string) error
	output(name string, args ...string) (string, error)
}

type realRunner struct{}

func (realRunner) run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func (realRunner) output(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).Output()
	return strings.TrimSpace(string(out)), err
}

type dryRunner struct{ real runner }

func (d dryRunner) run(name string, args ...string) error {
	fmt.Printf("[dry-run] %s %s\n", name, strings.Join(args, " "))
	return nil
}
func (d dryRunner) output(name string, args ...string) (string, error) {
	fmt.Printf("[dry-run] %s %s\n", name, strings.Join(args, " "))
	return "", nil
}

func prompt(in *bufio.Reader, label, def string) string {
	if def != "" {
		fmt.Printf("%s [%s]: ", label, def)
	} else {
		fmt.Printf("%s: ", label)
	}
	line, _ := in.ReadString('\n')
	line = strings.TrimSpace(line)
	if line == "" {
		return def
	}
	return line
}

func loadConfig(path string) (*config, error) {
	if path == "" {
		return &config{Image: defaultImage, Filesystem: "btrfs"}, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, err
	}
	if c.Image == "" {
		c.Image = defaultImage
	}
	if c.Filesystem == "" {
		c.Filesystem = "btrfs"
	}
	return &c, nil
}

func disks(r runner) ([]string, error) {
	out, err := r.output("lsblk", "-dn", "-o", "PATH,SIZE,TYPE")
	if err != nil {
		return nil, err
	}
	var result []string
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 3 && fields[2] == "disk" {
			result = append(result, fields[0]+" ("+fields[1]+")")
		}
	}
	return result, nil
}

func chooseDisk(in *bufio.Reader, r runner, def string) (string, error) {
	list, err := disks(r)
	if err != nil {
		return "", err
	}
	if len(list) == 0 {
		return "", errors.New("no block devices found")
	}
	sort.Strings(list)
	fmt.Println("Available disks:")
	for i, d := range list {
		fmt.Printf("  %d) %s\n", i+1, d)
	}
	choice := prompt(in, "Select disk number", "1")
	var idx int
	if _, err := fmt.Sscanf(choice, "%d", &idx); err != nil || idx < 1 || idx > len(list) {
		return "", fmt.Errorf("invalid selection %q", choice)
	}
	if def != "" && def != list[idx-1] {
		fmt.Printf("warning: config disk %q differs from selection %q\n", def, list[idx-1])
	}
	return strings.Fields(list[idx-1])[0], nil
}

func wifiConnect(r runner, ssid, psk string, dry bool) error {
	if ssid == "" || psk == "" {
		return nil
	}
	if dry {
		fmt.Printf("[dry-run] write WiFi keyfile for %s and nmcli up\n", ssid)
		return nil
	}
	// The live ISO uses NetworkManager; write a keyfile and bring it up.
	const dir = "/etc/NetworkManager/system-connections"
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	path := filepath.Join(dir, ssid+".nmconnection")
	body := fmt.Sprintf("[connection]\nid=%s\ntype=wifi\nautoconnect=true\n\n[wifi]\nmode=infrastructure\nssid=%s\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n", ssid, ssid, psk)
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		return err
	}
	if err := r.run("nmcli", "connection", "reload"); err != nil {
		return err
	}
	if err := r.run("nmcli", "connection", "up", ssid); err != nil {
		return err
	}
	return nil
}

func registryLogin(r runner, user, token string) error {
	if user == "" || token == "" {
		return nil
	}
	return r.run("podman", "login", "ghcr.io", "-u", user, "--password-stdin")
}

func newMachineID() string {
	b := make([]byte, 16)
	f, err := os.Open("/dev/urandom")
	if err != nil {
		return "4f1a2b3c5d6e7f8091a2b3c4d5e6f708"
	}
	defer f.Close()
	if _, err := io.ReadFull(f, b); err != nil {
		return "4f1a2b3c5d6e7f8091a2b3c4d5e6f708"
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func install(c *config, disk string, r runner) error {
	if err := r.run("wipefs", "--all", "--force", disk); err != nil {
		return fmt.Errorf("wipe %s: %w", disk, err)
	}
	pull := []string{"pull", c.Image}
	if err := r.run("podman", pull...); err != nil {
		return fmt.Errorf("pull %s: %w", c.Image, err)
	}
	args := []string{
		"run", "--rm", "--privileged", "--pid=host",
		"-v", "/dev:/dev",
		"-v", "/var/lib/containers:/var/lib/containers",
		"--security-opt", "label=type:unconfined_t",
		c.Image,
		"bootc", "install", "to-disk",
		"--composefs-backend",
		"--wipe", "--filesystem", c.Filesystem,
		"--bootloader", "systemd",
		"--karg", "systemd.firstboot=no",
		"--karg", "quiet",
		"--karg", "systemd.volatile=yes",
		"--karg", "systemd.machine_id=" + newMachineID(),
		disk,
	}
	if err := r.run("podman", args...); err != nil {
		return fmt.Errorf("bootc install: %w", err)
	}
	return nil
}

func run(c *config, r runner) error {
	if err := wifiConnect(r, c.SSID, c.PSK, c.DryRun); err != nil {
		return fmt.Errorf("wifi: %w", err)
	}
	if err := registryLogin(r, c.RegUser, c.RegToken); err != nil {
		return fmt.Errorf("registry login: %w", err)
	}
	disk := c.Disk
	if disk == "" {
		in := bufio.NewReader(os.Stdin)
		var err error
		disk, err = chooseDisk(in, r, "")
		if err != nil {
			return err
		}
	}
	if err := install(c, disk, r); err != nil {
		return err
	}
	if c.Hostname != "" {
		fmt.Printf("Provision hostname %q and role %q on first boot via systemd credentials.\n", c.Hostname, c.Role)
	}
	if c.Reboot {
		return r.run("systemctl", "reboot")
	}
	return nil
}

func main() {
	configPath := flag.String("config", "", "JSON config file (skips interactive prompts for values it sets)")
	dryRun := flag.Bool("dry-run", false, "print commands without executing them")
	version := flag.Bool("version", false, "print version")
	flag.Parse()

	if *version {
		fmt.Println("mjolnir-installer 0.1.0")
		return
	}

	c, err := loadConfig(*configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		os.Exit(1)
	}
	if *dryRun {
		c.DryRun = true
	}

	var r runner = realRunner{}
	if c.DryRun {
		r = dryRunner{real: r}
	}

	in := bufio.NewReader(os.Stdin)
	if c.Image == "" || *configPath == "" {
		c.Image = prompt(in, "Image reference", c.Image)
	}
	if c.SSID == "" && *configPath == "" {
		if strings.EqualFold(prompt(in, "Configure WiFi?", "n"), "y") {
			c.SSID = prompt(in, "WiFi SSID", "")
			c.PSK = prompt(in, "WPA PSK (64 hex chars)", "")
		}
	}
	if c.RegUser == "" && *configPath == "" {
		if strings.EqualFold(prompt(in, "Private registry?", "n"), "y") {
			c.RegUser = prompt(in, "Registry user", "")
			c.RegToken = prompt(in, "Registry token", "")
		}
	}
	if c.Role == "" && *configPath == "" {
		c.Role = prompt(in, "Node role (control-plane/worker)", "worker")
	}

	if err := run(c, r); err != nil {
		fmt.Fprintln(os.Stderr, "install failed:", err)
		os.Exit(1)
	}
	fmt.Println("Mjolnir installed successfully")
}
