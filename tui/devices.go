package main

import (
	"context"
	"os/exec"
	"regexp"
	"slices"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// The U2F screen lists one action per connected authenticator, so it has to
// follow plugging and unplugging without a relaunch.
const devicePollInterval = time.Second

var (
	fidoDeviceLine  = regexp.MustCompile(`^/dev/(hidraw[0-9]+):`)
	fidoDeviceExtra = regexp.MustCompile(`^(?:enroll|add-key)-(hidraw[0-9]+)$`)
)

type devicePollTickMsg struct{}

type devicesMsg struct {
	devices []string
	err     error
}

func devicePollTick() tea.Cmd {
	return tea.Tick(devicePollInterval, func(time.Time) tea.Msg { return devicePollTickMsg{} })
}

// connectedFIDODevices parses `fido2-token -L` the way the backend does:
// only hidraw paths count, so the result matches the backend's actions.
func connectedFIDODevices(out string) []string {
	var devices []string
	for _, line := range strings.Split(out, "\n") {
		if match := fidoDeviceLine.FindStringSubmatch(line); match != nil {
			devices = append(devices, match[1])
		}
	}
	slices.Sort(devices)
	return slices.Compact(devices)
}

func pollFIDODevices() tea.Msg {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "fido2-token", "-L").Output()
	if err != nil {
		return devicesMsg{err: err}
	}
	return devicesMsg{devices: connectedFIDODevices(string(out))}
}

// U2FDevices reports the authenticators the last backend dump saw, read from
// its per-device enroll/add actions.
func (m *Module) U2FDevices() []string {
	var devices []string
	for _, e := range m.Extras {
		if match := fidoDeviceExtra.FindStringSubmatch(e.ID); match != nil {
			devices = append(devices, match[1])
		}
	}
	slices.Sort(devices)
	return slices.Compact(devices)
}

func (m *model) watchingFIDODevices() bool {
	return m.scr == scrModule && m.mod != nil && m.mod.Name == "u2f" &&
		!m.loading && !m.modal && !m.modalRunning &&
		!m.authChecking && m.authSession == nil
}

func (m *model) onDevicePollTick() (tea.Model, tea.Cmd) {
	if !m.watchingFIDODevices() {
		return m, devicePollTick()
	}
	return m, pollFIDODevices
}

func (m *model) onDevices(msg devicesMsg) (tea.Model, tea.Cmd) {
	if msg.err != nil || !m.watchingFIDODevices() ||
		slices.Equal(msg.devices, m.mod.U2FDevices()) {
		return m, devicePollTick()
	}
	model, cmd := m.refresh(true)
	return model, tea.Batch(cmd, devicePollTick())
}
