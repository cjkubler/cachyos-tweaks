package main

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestBackendCommandElevationBoundary(t *testing.T) {
	t.Setenv("CACHYOS_TWEAKS_SH", "/opt/cachyos tweaks/tweaks.sh")
	t.Setenv("CACHYOS_TWEAKS_DEV", "1")
	direct := backendCommand(false, nil, "dump")
	if want := []string{"bash", "/opt/cachyos tweaks/tweaks.sh", "dump"}; !reflect.DeepEqual(direct.Args, want) {
		t.Fatalf("direct backend arguments = %#v, want %#v", direct.Args, want)
	}

	if os.Geteuid() != 0 {
		t.Setenv("CACHYOS_TWEAKS_DEV", "")
		elevated := backendCommand(true, []string{"EXAMPLE=1"}, "dump")
		want := []string{"sudo", "--non-interactive", "--", "env", "EXAMPLE=1", "bash", "/opt/cachyos tweaks/tweaks.sh", "dump"}
		if !reflect.DeepEqual(elevated.Args, want) {
			t.Fatalf("elevated backend arguments = %#v, want %#v", elevated.Args, want)
		}
	}
}

func record(fields ...string) string {
	return strings.Join(fields, fieldSep) + recordSep
}

func TestParseDump(t *testing.T) {
	out := record("SUITE", "1", "host", "kernel") +
		record("MODULE", "fw13", "Framework 13") +
		record("DOC", "fw13", "Hardware", "Framework 13", "modules/devices/framework-13.md") +
		record("TWEAK", "fw13", "wifi", "Wi-Fi", "off", "1", "Description", "memory-policy", "Memory & swap") +
		record("EXTRA", "fw13", "diag", "Diagnose", "0", "1", "Read only", "0", "1")

	suite, err := parseDump(out)
	if err != nil {
		t.Fatal(err)
	}
	if !suite.Snapshots || suite.Host != "host" || len(suite.Modules) != 1 {
		t.Fatalf("suite = %#v", suite)
	}
	mod := suite.Modules[0]
	if len(mod.Documents) != 1 || mod.Documents[0].Category != "Hardware" ||
		mod.Documents[0].Path != "modules/devices/framework-13.md" {
		t.Fatalf("module documents = %#v", mod.Documents)
	}
	if len(mod.Tweaks) != 1 || !mod.Tweaks[0].Toggleable {
		t.Fatalf("module tweaks = %#v", mod.Tweaks)
	}
	if mod.Tweaks[0].Group != "memory-policy" {
		t.Fatalf("tweak group = %q", mod.Tweaks[0].Group)
	}
	if mod.Tweaks[0].Category != "Memory & swap" {
		t.Fatalf("tweak category = %q", mod.Tweaks[0].Category)
	}
	if len(mod.Extras) != 1 || !mod.Extras[0].Capture || mod.Extras[0].NeedsRoot ||
		!mod.Extras[0].Tabbed {
		t.Fatalf("module extras = %#v", mod.Extras)
	}
}

func TestParseOutputTabs(t *testing.T) {
	output := "== USB4 ==\ndomain0 ok\n\n== GPUs ==\ncard0 internal\ncard1 external\n"
	tabs := parseOutputTabs(output)
	if len(tabs) != 2 || tabs[0].title != "USB4" ||
		tabs[1].content != "card0 internal\ncard1 external" {
		t.Fatalf("output tabs = %#v", tabs)
	}
	if tabs := parseOutputTabs("plain output"); tabs != nil {
		t.Fatalf("plain output unexpectedly became tabs: %#v", tabs)
	}

	output = "preamble\n== USB4 ==\none\n== USB4 ==\ntwo\n==  ==\nkept\n"
	tabs = parseOutputTabs(output)
	if len(tabs) != 3 || tabs[0].title != "Output" ||
		tabs[1].title != "USB4" || tabs[2].title != "USB4 (2)" ||
		!strings.Contains(tabs[2].content, "==  ==") {
		t.Fatalf("malformed/repeated output tabs = %#v", tabs)
	}
}

func TestParseDumpRejectsBrokenProtocol(t *testing.T) {
	tests := map[string]string{
		"missing suite":    record("MODULE", "fw13", "Framework 13"),
		"duplicate module": record("SUITE", "0", "h", "k") + record("MODULE", "x", "X") + record("MODULE", "x", "X"),
		"orphan tweak":     record("SUITE", "0", "h", "k") + record("TWEAK", "x", "id", "title", "off", "1", "desc"),
		"orphan document":  record("SUITE", "0", "h", "k") + record("DOC", "x", "Hardware", "X", "modules/x.md"),
		"unsafe document": record("SUITE", "0", "h", "k") + record("MODULE", "x", "X") +
			record("DOC", "x", "Hardware", "X", "../README.md"),
		"duplicate document": record("SUITE", "0", "h", "k") + record("MODULE", "x", "X") +
			record("DOC", "x", "Hardware", "X", "modules/x.md") +
			record("DOC", "x", "Hardware", "X again", "modules/x.md"),
		"duplicate document globally": record("SUITE", "0", "h", "k") +
			record("MODULE", "x", "X") +
			record("DOC", "x", "Hardware", "X", "modules/x.md") +
			record("MODULE", "y", "Y") +
			record("DOC", "y", "Hardware", "X", "modules/x.md"),
		"duplicate tweak": record("SUITE", "0", "h", "k") + record("MODULE", "x", "X") +
			record("TWEAK", "x", "id", "One", "off", "1", "desc") +
			record("TWEAK", "x", "id", "Two", "off", "1", "desc"),
		"duplicate extra": record("SUITE", "0", "h", "k") + record("MODULE", "x", "X") +
			record("EXTRA", "x", "run", "Run", "0", "1", "desc") +
			record("EXTRA", "x", "run", "Run", "0", "1", "desc"),
		"invalid status": record("SUITE", "0", "h", "k") + record("MODULE", "x", "X") +
			record("TWEAK", "x", "id", "One", "maybe", "1", "desc"),
		"invalid category": record("SUITE", "0", "h", "k") + record("MODULE", "x", "X") +
			record("TWEAK", "x", "id", "One", "off", "1", "desc", "", " Memory"),
		"invalid boolean": record("SUITE", "0", "h", "k") + record("MODULE", "x", "X") +
			record("EXTRA", "x", "run", "Run", "2", "1", "desc"),
		"extra fields": record("SUITE", "0", "h", "k", "unexpected"),
		"noncanonical document": record("SUITE", "0", "h", "k") + record("MODULE", "x", "X") +
			record("DOC", "x", "Hardware", "X", "modules/a/../x.md"),
		"suite not first": record("MODULE", "x", "X") + record("SUITE", "0", "h", "k"),
		"unknown record":  record("SUITE", "0", "h", "k") + record("WAT", "x"),
	}
	for name, out := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := parseDump(out); err == nil {
				t.Fatal("parseDump unexpectedly succeeded")
			}
		})
	}
}

func TestBoundedCommandOutput(t *testing.T) {
	cmd := exec.Command("bash", "-c", "printf '%0200d' 0; printf error >&2")
	stdout, stderr, overflow, err := boundedCommandOutput(cmd, 64, 64)
	if err != nil {
		t.Fatal(err)
	}
	if !overflow || len(stdout) != 64 || string(stderr) != "error" {
		t.Fatalf("bounded output = stdout:%d stderr:%q overflow:%v",
			len(stdout), stderr, overflow)
	}
}

func TestCapturedActionCanBeCancelledWithoutBlockingTheStream(t *testing.T) {
	tempDir := t.TempDir()
	script := filepath.Join(tempDir, "backend.sh")
	if err := os.WriteFile(script, []byte(
		"printf 'started\\n'\n"+
			"while :; do printf 'more output\\n'; sleep 0.01; done\n",
	), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CACHYOS_TWEAKS_SH", script)
	t.Setenv("CACHYOS_TWEAKS_DEV", "1")

	started := captureBackend(captureRequest{args: []string{"ignored"}})().(captureStartedMsg)
	first := <-started.events
	if first.done || !strings.Contains(first.text, "started") {
		t.Fatalf("first capture event = %#v", first)
	}
	started.session.cancel()

	timeout := time.After(3 * time.Second)
	for {
		select {
		case _, ok := <-started.events:
			if !ok {
				return
			}
		case <-timeout:
			t.Fatal("cancelled capture did not close its event stream")
		}
	}
}

func TestLoadDumpDoesNotRequireElevation(t *testing.T) {
	tempDir := t.TempDir()
	script := filepath.Join(tempDir, "backend.sh")
	payload := record("SUITE", "0", "host", "kernel") +
		record("MODULE", "test", "Test module")
	source := "#!/bin/sh\nprintf '%s' '" + payload + "'\n"
	if err := os.WriteFile(script, []byte(source), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CACHYOS_TWEAKS_SH", script)
	t.Setenv("CACHYOS_TWEAKS_DEV", "")

	msg := loadDump().(dumpMsg)
	if msg.err != nil || msg.suite == nil || msg.suite.Host != "host" {
		t.Fatalf("unprivileged dump = %#v", msg)
	}
}

func TestCaptureExtraStreamsBeforeCompletion(t *testing.T) {
	tempDir := t.TempDir()
	script := filepath.Join(tempDir, "backend.sh")
	signal := filepath.Join(tempDir, "continue")
	t.Cleanup(func() { _ = os.WriteFile(signal, nil, 0o600) })
	err := os.WriteFile(script, []byte(
		"printf 'Touch the authenticator now.\\n'\n"+
			"while [ ! -e "+strconv.Quote(signal)+" ]; do sleep 0.01; done\n"+
			"printf 'Authentication passed.\\n'\n",
	), 0o600)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("CACHYOS_TWEAKS_SH", script)
	t.Setenv("CACHYOS_TWEAKS_DEV", "1")

	started, ok := captureExtra("u2f", "test")().(captureStartedMsg)
	if !ok {
		t.Fatal("captureExtra did not start a stream")
	}

	first := <-started.events
	if first.done || first.text != "Touch the authenticator now.\n" {
		t.Fatalf("first event = %#v", first)
	}
	if err := os.WriteFile(signal, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	second := <-started.events
	if second.done || second.text != "Authentication passed.\n" {
		t.Fatalf("second event = %#v", second)
	}
	done := <-started.events
	if !done.done || done.err != nil {
		t.Fatalf("done event = %#v", done)
	}
}

func TestAuthCommandOffersConfiguredMethodBeforeInputFallback(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bash", "-c",
		"printf 'Approve the configured authenticator first.\\n"+
			sudoAuthInputMarker+"'; IFS= read -r reply; "+
			"test \"$reply\" = secret; printf '\\nauthenticated\\n'",
	)
	session, events, err := startAuthCommand(cmd)
	if err != nil {
		t.Fatal(err)
	}
	defer session.cancel()

	var output string
	for !strings.Contains(output, sudoAuthInputMarker) {
		event := <-events
		if event.done {
			t.Fatalf("authentication ended before requesting fallback input: %#v", event)
		}
		output += event.text
	}
	if !strings.Contains(output, "configured authenticator first") {
		t.Fatalf("configured-method guidance was not streamed first: %q", output)
	}
	if _, err := io.WriteString(session.input, "secret\n"); err != nil {
		t.Fatal(err)
	}
	for {
		event := <-events
		output += event.text
		if event.done {
			if event.err != nil {
				t.Fatal(event.err)
			}
			break
		}
	}
	if !strings.Contains(output, "authenticated") || strings.Contains(output, "secret") {
		t.Fatalf("authentication transcript = %q", output)
	}
}
