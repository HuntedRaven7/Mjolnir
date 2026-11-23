// SPDX-License-Identifier: Apache-2.0
// Interactive installer forms. The TUI only collects configuration: the
// install itself is always performed by the same headless run() pipeline.
package main

import (
	"errors"
	"fmt"
	"strings"

	"github.com/charmbracelet/huh"
)

// collectConfig walks the user through the install settings using full-screen
// forms, then stores the chosen disk in c so run() can proceed without any
// further prompts. It is only called when a real terminal is available.
func collectConfig(c *config, r runner) error {
	prepareSerialTerminal()

	role := c.Role
	if role == "" {
		role = "worker"
	}
	filesystem := c.Filesystem
	if filesystem == "" {
		filesystem = "btrfs"
	}
	configureWiFi := c.SSID != ""
	configureRegistry := c.RegUser != ""

	settings := huh.NewForm(huh.NewGroup(
		huh.NewInput().
			Title("Image reference").
			Description("OCI image to install from the registry").
			Value(&c.Image).
			Validate(nonEmpty("image reference")),
		huh.NewSelect[string]().
			Title("Node role").
			Description("Control plane runs kubeadm and the fleet controller").
			Options(
				huh.NewOption("worker", "worker"),
				huh.NewOption("control-plane", "control-plane"),
			).
			Value(&role),
		huh.NewInput().
			Title("Hostname").
			Description("Leave empty to derive it from the role").
			Value(&c.Hostname),
		huh.NewInput().
			Title("Timezone").
			Description("Leave empty for UTC").
			Value(&c.Timezone),
		huh.NewSelect[string]().
			Title("Root filesystem").
			Options(
				huh.NewOption("btrfs", "btrfs"),
				huh.NewOption("ext4", "ext4"),
				huh.NewOption("xfs", "xfs"),
			).
			Value(&filesystem),
		huh.NewConfirm().
			Title("Encrypt root with TPM2 (LUKS)?").
			Value(&c.Encrypted),
		huh.NewConfirm().
			Title("Configure WiFi?").
			Value(&configureWiFi),
		huh.NewConfirm().
			Title("Use a private registry?").
			Value(&configureRegistry),
	))

	if err := settings.Run(); err != nil {
		return fmt.Errorf("installer settings: %w", err)
	}
	c.Role = role
	c.Filesystem = filesystem

	if configureWiFi {
		wifi := huh.NewForm(huh.NewGroup(
			huh.NewInput().Title("WiFi SSID").Value(&c.SSID).Validate(nonEmpty("SSID")),
			huh.NewInput().
				Title("WPA PSK (64 hex characters)").
				EchoMode(huh.EchoModePassword).
				Value(&c.PSK).
				Validate(func(s string) error {
					if len(s) != 64 || !hex64.MatchString(s) {
						return errors.New("PSK must be exactly 64 hex characters")
					}
					return nil
				}),
		))
		if err := wifi.Run(); err != nil {
			return fmt.Errorf("WiFi settings: %w", err)
		}
	}

	if configureRegistry {
		registry := huh.NewForm(huh.NewGroup(
			huh.NewInput().Title("Registry user").Value(&c.RegUser).Validate(nonEmpty("registry user")),
			huh.NewInput().
				Title("Registry token").
				EchoMode(huh.EchoModePassword).
				Value(&c.RegToken).
				Validate(nonEmpty("registry token")),
		))
		if err := registry.Run(); err != nil {
			return fmt.Errorf("registry settings: %w", err)
		}
	}

	list, err := disks(r)
	if err != nil {
		return err
	}
	if len(list) == 0 {
		if c.DryRun {
			c.Disk = "/dev/vda"
			c.Yes = true
			return nil
		}
		return errors.New("no eligible disks: removable, mounted and boot disks are excluded")
	}
	options := make([]huh.Option[string], 0, len(list))
	for _, d := range list {
		options = append(options, huh.NewOption(describeDisk(d), d.Path))
	}
	selected := list[0].Path
	if c.Disk != "" {
		selected = c.Disk
	}
	confirmation := ""

	diskForm := huh.NewForm(huh.NewGroup(
		huh.NewSelect[string]().
			Title("Target disk").
			Description("The selected disk will be completely erased").
			Options(options...).
			Value(&selected),
		huh.NewInput().
			Title("Type the disk path to confirm").
			Value(&confirmation).
			Validate(func(s string) error {
				if s != selected {
					return fmt.Errorf("type %q exactly", selected)
				}
				return nil
			}),
	))

	if err := diskForm.Run(); err != nil {
		return fmt.Errorf("disk selection: %w", err)
	}
	for _, d := range list {
		if d.Path == selected {
			if err := checkDiskSize(d); err != nil {
				return err
			}
		}
	}
	c.Disk = selected
	// Disk choice and confirmation are already done inside the TUI.
	c.Yes = true
	return nil
}

func nonEmpty(label string) func(string) error {
	return func(s string) error {
		if strings.TrimSpace(s) == "" {
			return fmt.Errorf("%s is required", label)
		}
		return nil
	}
}
