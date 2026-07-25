package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/charmbracelet/x/term"
)

const terminalRelaunchEnv = "CACHYOS_TWEAKS_TERMINAL"

type terminalLauncher struct {
	name string
	args func(string) []string
}

// Ordered from desktop-neutral helpers through common CachyOS terminals.
// Keeping this here instead of delegating to a shell also makes paths with
// spaces safe.
var terminalLaunchers = []terminalLauncher{
	{"xdg-terminal-exec", func(exe string) []string { return []string{"--", exe} }},
	{"konsole", func(exe string) []string { return []string{"-e", exe} }},
	{"ptyxis", func(exe string) []string { return []string{"--standalone", "--", exe} }},
	{"kgx", func(exe string) []string { return []string{"--", exe} }},
	{"gnome-terminal", func(exe string) []string { return []string{"--wait", "--", exe} }},
	{"xfce4-terminal", func(exe string) []string { return []string{"--disable-server", "-x", exe} }},
	{"mate-terminal", func(exe string) []string { return []string{"--", exe} }},
	{"cosmic-term", func(exe string) []string { return []string{"-e", exe} }},
	{"kitty", func(exe string) []string { return []string{exe} }},
	{"ghostty", func(exe string) []string { return []string{"-e", exe} }},
	{"alacritty", func(exe string) []string { return []string{"-e", exe} }},
	{"foot", func(exe string) []string { return []string{exe} }},
	{"wezterm", func(exe string) []string { return []string{"start", "--", exe} }},
	{"xterm", func(exe string) []string { return []string{"-e", exe} }},
}

func hasTerminal() bool {
	return term.IsTerminal(os.Stdin.Fd()) && term.IsTerminal(os.Stdout.Fd())
}

func executablePath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("cannot locate the tweaks UI executable: %w", err)
	}
	exe, err = filepath.Abs(exe)
	if err != nil {
		return "", fmt.Errorf("cannot resolve the tweaks UI executable: %w", err)
	}
	return exe, nil
}

func findTerminal(exe string, lookPath func(string) (string, error)) (string, []string, error) {
	for _, launcher := range terminalLaunchers {
		path, err := lookPath(launcher.name)
		if err == nil {
			return path, launcher.args(exe), nil
		}
	}
	return "", nil, errors.New(
		"no supported terminal emulator found (install xdg-terminal-exec, Konsole, Ptyxis, GNOME Console, kitty, Alacritty, foot, WezTerm, or xterm)",
	)
}

// prepareTerminal opens a terminal when the binary was started from a desktop
// launcher or file manager. The child comes back through main with a real TTY,
// so authentication and Bubble Tea both have somewhere to interact.
func prepareTerminal() (bool, error) {
	if hasTerminal() {
		return false, nil
	}
	if os.Getenv(terminalRelaunchEnv) != "" {
		return false, errors.New("the selected terminal did not attach a usable TTY")
	}

	exe, err := executablePath()
	if err != nil {
		return false, err
	}
	path, args, err := findTerminal(exe, exec.LookPath)
	if err != nil {
		return false, err
	}
	cmd := exec.Command(path, args...)
	cmd.Env = append(os.Environ(), terminalRelaunchEnv+"=1")
	if err := cmd.Start(); err != nil {
		return false, fmt.Errorf("could not open %s: %w", filepath.Base(path), err)
	}
	if err := cmd.Process.Release(); err != nil {
		return false, fmt.Errorf("could not detach %s: %w", filepath.Base(path), err)
	}
	return true, nil
}

func exitStartup(err error) {
	fmt.Fprintf(os.Stderr, "tweaks-tui: %v\n", err)
	// A terminal we opened would otherwise vanish before a startup error can
	// be read. Do not pause for ordinary shell launches.
	if os.Getenv(terminalRelaunchEnv) != "" && hasTerminal() {
		fmt.Fprint(os.Stderr, "Press Enter to close…")
		_, _ = fmt.Fscanln(os.Stdin, new(string))
	}
	os.Exit(1)
}
