package main

import (
	"errors"
	"slices"
	"testing"
)

func u2fModule(extraIDs ...string) *Module {
	mod := &Module{Name: "u2f", Title: "U2F"}
	for _, id := range extraIDs {
		mod.Extras = append(mod.Extras, Extra{Module: "u2f", ID: id, Label: id})
	}
	return mod
}

func TestConnectedFIDODevicesMatchesBackendFilter(t *testing.T) {
	out := "/dev/hidraw3: vendor=0x0483, product=0x5741 (Flipper Devices Inc. U2F Token)\n" +
		"pcsc://slot0: vendor=0x0000, product=0x0000 (Smart Card Reader)\n" +
		"/dev/hidraw0: vendor=0x1ea8, product=0xf829 (Thetis Security Key(F829))\n"
	if got, want := connectedFIDODevices(out), []string{"hidraw0", "hidraw3"}; !slices.Equal(got, want) {
		t.Fatalf("devices = %v, want %v", got, want)
	}
}

func TestU2FDevicesReadsPerDeviceActions(t *testing.T) {
	mod := u2fModule("test", "add-key-hidraw3", "add-key-hidraw0", "remove-key-0123456789ab", "unenroll")
	if got, want := mod.U2FDevices(), []string{"hidraw0", "hidraw3"}; !slices.Equal(got, want) {
		t.Fatalf("devices = %v, want %v", got, want)
	}
	if got := u2fModule("enroll").U2FDevices(); len(got) != 0 {
		t.Fatalf("placeholder enroll row counted as a device: %v", got)
	}
}

func TestUnpluggedAuthenticatorReloadsU2FScreen(t *testing.T) {
	m := newModel()
	m.mod = u2fModule("enroll-hidraw0", "enroll-hidraw3")
	m.scr = scrModule
	m.loading = false
	m.buildRows()

	m.onDevices(devicesMsg{devices: []string{"hidraw0", "hidraw3"}})
	if m.loading {
		t.Fatal("reloaded although the connected devices were unchanged")
	}
	m.onDevices(devicesMsg{err: errors.New("fido2-token missing")})
	if m.loading {
		t.Fatal("reloaded on a failed device poll")
	}
	m.onDevices(devicesMsg{devices: []string{"hidraw0"}})
	if !m.loading {
		t.Fatal("unplugging an authenticator did not reload the U2F screen")
	}
}

func TestDevicePollingStaysOffOtherScreens(t *testing.T) {
	m := newModel()
	m.mod = u2fModule("enroll-hidraw0")
	m.scr = scrMain
	if m.watchingFIDODevices() {
		t.Fatal("polled devices outside the U2F screen")
	}
	m.scr = scrModule
	m.modalRunning = true
	if m.watchingFIDODevices() {
		t.Fatal("polled devices while an action was running")
	}
}
