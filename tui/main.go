// Charm (Bubble Tea) frontend for Tweaks for CachyOS.
//
// This binary is a pure frontend: all detection, staging semantics, state
// tracking and mutation live in tweaks.sh and its modules. It talks to the
// suite over three subcommands — `dump` (machine-readable state), `batch`
// (staged changes on stdin, snapshot-wrapped) and `extra` (module actions) —
// while keeping interaction inside the TUI.
//
// Launched automatically by `./tweaks.sh` when built, or directly from a
// terminal/file manager; build it with `./tweaks.sh build-tui`.
package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

const noStartupAuthEnv = "CACHYOS_TWEAKS_NO_STARTUP_AUTH"

func configureLaunch(args []string) (bool, error) {
	showHelp := false
	for _, arg := range args {
		switch arg {
		case "--no-sudo":
			if err := os.Setenv(noStartupAuthEnv, "1"); err != nil {
				return false, err
			}
		case "-h", "--help":
			showHelp = true
		default:
			return false, fmt.Errorf("unknown option %q (try --help)", arg)
		}
	}
	return showHelp, nil
}

func main() {
	showHelp, err := configureLaunch(os.Args[1:])
	if err != nil {
		exitStartup(err)
	}
	if showHelp {
		fmt.Println("Usage: tweaks-tui [--no-sudo]")
		fmt.Println("  --no-sudo  skip startup authorization; ask only when an action needs it")
		return
	}

	relaunched, err := prepareTerminal()
	if err != nil {
		exitStartup(err)
	}
	if relaunched {
		return
	}

	// Deep slate-teal terminal background for the app's lifetime (OSC 11;
	// OSC 111 restores the terminal's own default on exit). Terminals
	// without support ignore both.
	fmt.Print("\x1b]11;#0c141b\x07")
	p := tea.NewProgram(newModel(), tea.WithAltScreen(), tea.WithMouseAllMotion())
	_, err = p.Run()
	fmt.Print("\x1b]111\x07")
	if err != nil {
		fmt.Fprintf(os.Stderr, "tweaks-tui: %v\n", err)
		os.Exit(1)
	}
}
