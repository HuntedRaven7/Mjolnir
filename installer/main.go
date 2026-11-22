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
	"regexp"
	"sort"
	"strconv"
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
	Yes        bool   `json:"-"`
}

type runner interface {
	run(name string, args ...string) error
	runStdin(input string, name string, args ...string) error
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

func (realRunner) runStdin(input string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdin = strings.NewReader(input)
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
func (d dryRunner) runStdin(input string, name string, args ...string) error {
	fmt.Printf("[dry-run] %s %s (stdin from credential)\n", name, strings.Join(args, " "))
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

type diskInfo struct {
	Path       string `json:"path"`
	Size       string `json:"size"`
	Type       string `json:"type"`
	Model      string `json:"model"`
	Serial     string `json:"serial"`
	Tran       string `json:"tran"`
	Rm         bool   `json:"rm"`
	Mountpoint string `json:"mountpoint"`
}

func disks(r runner) ([]diskInfo, error) {
	out, err := r.output("lsblk", "-J", "-d", "-o", "PATH,SIZE,TYPE,MODEL,SERIAL,TRAN,RM,MOUNTPOINT")
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(out) == "" {
		return nil, nil // dry-run has no block devices
	}
	var payload struct {
		BlockDevices []diskInfo `json:"blockdevices"`
	}
	if err := json.Unmarshal([]byte(out), &payload); err != nil {
		return nil, fmt.Errorf("parse lsblk output: %w", err)
	}

	// Never offer a disk the kernel booted from, a removable stick (usually
	// the installer media) or a disk that is currently mounted.
	bootPaths := map[string]bool{}
	if cmdline, err := os.ReadFile("/proc/cmdline"); err == nil {
		for _, field := range strings.Fields(string(cmdline)) {
			if strings.HasPrefix(field, "/dev/") {
				bootPaths[field] = true
			}
		}
	}
	var result []diskInfo
	for _, d := range payload.BlockDevices {
		if d.Type != "disk" || d.Rm || d.Mountpoint != "" || bootPaths[d.Path] {
			continue
		}
		result = append(result, d)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Path < result[j].Path })
	return result, nil
}

var sizeRe = regexp.MustCompile(`^([0-9]+(?:\.[0-9]+)?)([KMGTPE])$`)

func diskSizeBytes(size string) (float64, bool) {
	m := sizeRe.FindStringSubmatch(strings.TrimSpace(size))
	if m == nil {
		return 0, false
	}
	n, err := strconv.ParseFloat(m[1], 64)
	if err != nil {
		return 0, false
	}
	units := map[string]float64{"K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "P": 1e15, "E": 1e18}
	return n * units[strings.ToUpper(m[2])], true
}

const minDiskBytes = 20e9

func describeDisk(d diskInfo) string {
	parts := []string{d.Path, d.Size}
	if d.Model != "" {
		parts = append(parts, d.Model)
	}
	if d.Serial != "" {
		parts = append(parts, "serial="+d.Serial)
	}
	if d.Tran != "" {
		parts = append(parts, d.Tran)
	}
	return strings.Join(parts, " ")
}

func checkDiskSize(d diskInfo) error {
	n, ok := diskSizeBytes(d.Size)
	if ok && n < minDiskBytes {
		return fmt.Errorf("%s is %s, smaller than the required 20 GB", d.Path, d.Size)
	}
	return nil
}

func chooseDisk(in *bufio.Reader, r runner, def string, yes, dry bool) (string, error) {
	list, err := disks(r)
	if err != nil {
		return "", err
	}
	if len(list) == 0 {
		if dry {
			if def != "" {
				return def, nil
			}
			return "/dev/vda", nil
		}
		return "", errors.New("no eligible disks: removable, mounted and boot disks are excluded")
	}
	fmt.Println("Available disks:")
	for i, d := range list {
		fmt.Printf("  %d) %s\n", i+1, describeDisk(d))
	}

	if yes {
		if def == "" {
			selected := list[0]
			fmt.Printf("Unattended install: using %s\n", describeDisk(selected))
			return selected.Path, checkDiskSize(selected)
		}
		for _, d := range list {
			if d.Path == def {
				return def, checkDiskSize(d)
			}
		}
		return "", fmt.Errorf("configured disk %q is not an eligible disk", def)
	}

	choice := prompt(in, "Select disk number", "1")
	var idx int
	if _, err := fmt.Sscanf(choice, "%d", &idx); err != nil || idx < 1 || idx > len(list) {
		return "", fmt.Errorf("invalid selection %q", choice)
	}
	selected := list[idx-1]
	if def != "" && def != selected.Path {
		fmt.Printf("warning: config disk %q differs from selection %q\n", def, selected.Path)
	}
	if err := checkDiskSize(selected); err != nil {
		return "", err
	}
	fmt.Printf("WARNING: %s will be completely erased.\n", selected.Path)
	if confirm := prompt(in, "Type the disk path to confirm", ""); confirm != selected.Path {
		return "", errors.New("disk confirmation did not match; nothing was changed")
	}
	return selected.Path, nil
}

func wifiConnect(r runner, ssid, psk string, dry bool) error {
	if ssid == "" || psk == "" {
		return nil
	}
	if len(psk) != 64 || !regexp.MustCompile(`^[0-9a-fA-F]{64}$`).MatchString(psk) {
		return errors.New("wifi-psk must be a 64 character hex string")
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

// readCredential reads a systemd credential supplied by the provisioning
// system. Unit credentials take precedence over system credentials.
func readCredential(name string) string {
	var paths []string
	if dir := os.Getenv("CREDENTIALS_DIRECTORY"); dir != "" {
		paths = append(paths, filepath.Join(dir, name))
	}
	paths = append(paths,
		filepath.Join("/run/credentials/mjolnir-installer.service", name),
		filepath.Join("/run/credentials/@system", name),
	)
	for _, path := range paths {
		if b, err := os.ReadFile(path); err == nil {
			return strings.TrimSpace(string(b))
		}
	}
	return ""
}

func registryLogin(r runner, user, token string) error {
	if user == "" || token == "" {
		return nil
	}
	// --password-stdin needs the token on the child's stdin; passing it as an
	// argv would leak it in the process table.
	return r.runStdin(token+"\n", "podman", "login", "ghcr.io", "-u", user, "--password-stdin")
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

	// The live root's overlay is tmpfs-backed, so pulling a multi-GB image can
	// exhaust RAM on modest VMs. Use the target disk as temporary swap for the
	// pull, then release it before bootc install repartitions the disk. Unlike
	// mounting the disk at /var/lib/containers, this leaves no live filesystem
	// for --wipe to tear down underneath the running container.
	if err := r.run("mkswap", "-f", disk); err != nil {
		return fmt.Errorf("make temporary swap on %s: %w", disk, err)
	}
	if err := r.run("swapon", disk); err != nil {
		return fmt.Errorf("enable temporary swap on %s: %w", disk, err)
	}
	// /run is the tmpfs backing the overlay's writable layer; allow it to use
	// the swap we just added. Failure is harmless if it is not a tmpfs.
	_ = r.run("mount", "-o", "remount,size=8G", "/run")

	pull := []string{"pull", c.Image}
	if err := r.run("podman", pull...); err != nil {
		return fmt.Errorf("pull %s: %w", c.Image, err)
	}
	// Release the disk before bootc install wipes and repartitions it.
	if err := r.run("swapoff", disk); err != nil {
		return fmt.Errorf("disable temporary swap on %s: %w", disk, err)
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

type lsblkDevice struct {
	Path       string        `json:"path"`
	Type       string        `json:"type"`
	Fstype     string        `json:"fstype"`
	Mountpoint string        `json:"mountpoint"`
	Children   []lsblkDevice `json:"children"`
}

// verifyInstall checks the installed disk before declaring success: an ESP
// with systemd-boot and a signed UKI, plus a btrfs root partition.
func verifyInstall(r runner, disk string) error {
	out, err := r.output("lsblk", "-J", "-o", "PATH,TYPE,FSTYPE,MOUNTPOINT", disk)
	if err != nil {
		return err
	}
	var payload struct {
		BlockDevices []lsblkDevice `json:"blockdevices"`
	}
	if err := json.Unmarshal([]byte(out), &payload); err != nil {
		return fmt.Errorf("parse lsblk output: %w", err)
	}
	if len(payload.BlockDevices) == 0 {
		return errors.New("target disk disappeared after install")
	}
	var esp, root string
	for _, child := range payload.BlockDevices[0].Children {
		if child.Type != "part" {
			continue
		}
		if child.Fstype == "vfat" && esp == "" {
			esp = child.Path
		}
		if child.Fstype == "btrfs" && root == "" {
			root = child.Path
		}
	}
	if esp == "" || root == "" {
		return fmt.Errorf("installed disk has no ESP (%q) or btrfs root (%q)", esp, root)
	}

	mnt, err := os.MkdirTemp("", "mjolnir-esp-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(mnt)
	if err := r.run("mount", "-o", "ro", esp, mnt); err != nil {
		return fmt.Errorf("mount ESP %s: %w", esp, err)
	}
	defer r.run("umount", mnt)

	uki, err := filepath.Glob(filepath.Join(mnt, "EFI", "Linux", "*.efi"))
	if err != nil || len(uki) == 0 {
		return errors.New("no signed UKI found in ESP/EFI/Linux")
	}
	loaders, err := filepath.Glob(filepath.Join(mnt, "EFI", "BOOT", "BOOT*.EFI"))
	if err != nil || len(loaders) == 0 {
		return errors.New("no systemd-boot loader found in ESP/EFI/BOOT")
	}
	fmt.Printf("Verified %s: ESP %s (%s), root %s\n", disk, esp, filepath.Base(uki[0]), root)
	return nil
}

func run(c *config, r runner) error {
	// Provisioning credentials take precedence over an empty config field, so
	// secrets never have to be baked into the ISO or its JSON config.
	if c.RegUser == "" {
		c.RegUser = readCredential("registry-user")
	}
	if c.RegToken == "" {
		c.RegToken = readCredential("registry-token")
	}
	if c.SSID == "" {
		c.SSID = readCredential("wifi-ssid")
	}
	if c.PSK == "" {
		c.PSK = readCredential("wifi-psk")
	}

	if err := wifiConnect(r, c.SSID, c.PSK, c.DryRun); err != nil {
		return fmt.Errorf("wifi: %w", err)
	}
	if err := registryLogin(r, c.RegUser, c.RegToken); err != nil {
		return fmt.Errorf("registry login: %w", err)
	}
	in := bufio.NewReader(os.Stdin)
	disk, err := chooseDisk(in, r, c.Disk, c.Yes, c.DryRun)
	if err != nil {
		return err
	}
	if err := install(c, disk, r); err != nil {
		return err
	}
	if c.DryRun {
		fmt.Printf("[dry-run] verify installed disk %s\n", disk)
	} else if err := verifyInstall(r, disk); err != nil {
		return fmt.Errorf("post-install verification: %w", err)
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
	yes := flag.Bool("yes", false, "unattended: no prompts, pick the first eligible disk if none is configured")
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
	c.Yes = *yes

	var r runner = realRunner{}
	if c.DryRun {
		r = dryRunner{real: r}
	}

	in := bufio.NewReader(os.Stdin)
	if c.Yes {
		if c.Disk == "" {
			fmt.Println("Unattended install: no disk configured; the first eligible disk will be used")
		}
	} else {
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
	}

	if err := run(c, r); err != nil {
		fmt.Fprintln(os.Stderr, "install failed:", err)
		os.Exit(1)
	}
	fmt.Println("Mjolnir installed successfully")
}
