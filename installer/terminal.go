// SPDX-License-Identifier: Apache-2.0
// Serial consoles do not negotiate a window size, so Bubble Tea would render
// into a 0x0 terminal. Give the active serial console a usable geometry before
// starting the forms, the same way knuckle does.
package main

import (
	"os"
	"os/exec"
	"strings"
)

// terminalAvailable reports whether stdin is a character device. The live ISO
// service connects stdin to a TTY; CI and provisioning runs do not.
func terminalAvailable() bool {
	info, err := os.Stdin.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func prepareSerialTerminal() {
	data, err := os.ReadFile("/sys/class/tty/console/active")
	if err != nil {
		return
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return
	}
	name := fields[len(fields)-1]
	for _, prefix := range []string{"ttyS", "ttyUSB", "ttyACM", "ttyAMA"} {
		if strings.HasPrefix(name, prefix) {
			// Best effort: a container or a headless VM may not have stty.
			_ = exec.Command("stty", "-F", "/dev/console", "rows", "40", "cols", "80").Run()
			return
		}
	}
}
