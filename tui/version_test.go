package main

import (
	"runtime/debug"
	"testing"
)

func TestRevisionFromSettings(t *testing.T) {
	settings := []debug.BuildSetting{
		{Key: "vcs.revision", Value: "ABCDEF0123456789ABCDEF0123456789ABCDEF01"},
		{Key: "vcs.modified", Value: "true"},
	}
	if got, want := revisionFromSettings(settings), "abcdef012345+dirty"; got != want {
		t.Fatalf("revision = %q, want %q", got, want)
	}
	if got := revisionFromSettings(nil); got != "" {
		t.Fatalf("empty revision = %q", got)
	}
}
