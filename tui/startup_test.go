package main

import (
	"errors"
	"os"
	"reflect"
	"testing"
)

func TestConfigureLaunchNoSudo(t *testing.T) {
	t.Setenv(noStartupAuthEnv, "")
	help, err := configureLaunch([]string{"--no-sudo"})
	if err != nil || help || os.Getenv(noStartupAuthEnv) != "1" {
		t.Fatalf("configureLaunch = help:%v err:%v env:%q",
			help, err, os.Getenv(noStartupAuthEnv))
	}
	if _, err := configureLaunch([]string{"--unknown"}); err == nil {
		t.Fatal("unknown launch option was accepted")
	}
}

func lookupOnly(found ...string) func(string) (string, error) {
	available := make(map[string]bool, len(found))
	for _, name := range found {
		available[name] = true
	}
	return func(name string) (string, error) {
		if available[name] {
			return "/usr/bin/" + name, nil
		}
		return "", errors.New("not found")
	}
}

func TestFindTerminalPrefersDesktopNeutralLauncher(t *testing.T) {
	path, args, err := findTerminal("/tmp/tweaks UI", lookupOnly("alacritty", "xdg-terminal-exec"))
	if err != nil {
		t.Fatal(err)
	}
	if path != "/usr/bin/xdg-terminal-exec" {
		t.Fatalf("path = %q", path)
	}
	if want := []string{"--", "/tmp/tweaks UI"}; !reflect.DeepEqual(args, want) {
		t.Fatalf("args = %#v, want %#v", args, want)
	}
}

func TestFindTerminalUsesKnownFallbackArguments(t *testing.T) {
	path, args, err := findTerminal("/tmp/tweaks-tui", lookupOnly("alacritty"))
	if err != nil {
		t.Fatal(err)
	}
	if path != "/usr/bin/alacritty" {
		t.Fatalf("path = %q", path)
	}
	if want := []string{"-e", "/tmp/tweaks-tui"}; !reflect.DeepEqual(args, want) {
		t.Fatalf("args = %#v, want %#v", args, want)
	}
}
