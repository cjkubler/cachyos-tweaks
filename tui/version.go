package main

import (
	"runtime/debug"
	"strings"
)

var buildRevision = readBuildRevision()

func readBuildRevision() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return ""
	}
	return revisionFromSettings(info.Settings)
}

func revisionFromSettings(settings []debug.BuildSetting) string {
	var revision string
	modified := false
	for _, setting := range settings {
		switch setting.Key {
		case "vcs.revision":
			revision = setting.Value
		case "vcs.modified":
			modified = setting.Value == "true"
		}
	}
	if revision == "" {
		return ""
	}
	revision = revision[:minInt(len(revision), 12)]
	if modified {
		revision += "+dirty"
	}
	return strings.ToLower(revision)
}
