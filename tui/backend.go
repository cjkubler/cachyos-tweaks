package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// Wire format of `tweaks.sh dump`: records separated by \x1e, fields by
// \x1f. Descriptions span lines freely; neither byte occurs in text.
const (
	fieldSep      = "\x1f"
	recordSep     = "\x1e"
	maxDumpOutput = 8 << 20
)

var protocolIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

type Tweak struct {
	Module     string
	ID         string
	Title      string
	Status     string // on | off | drifted | unmanaged | n/a
	Toggleable bool
	Desc       string
	Group      string // non-empty means a mutually exclusive policy choice
	Category   string // optional backend-owned section heading
	Staged     string // "", "on", "off" — frontend-side staging only
}

type Extra struct {
	Module    string
	ID        string
	Label     string
	Disabled  bool
	Capture   bool // output-only: run captured and show in a modal
	NeedsRoot bool
	Tabbed    bool
	Desc      string
}

type HelpDocument struct {
	Module   string
	Category string
	Title    string
	Path     string
}

type Module struct {
	Name      string
	Title     string
	Documents []HelpDocument
	Tweaks    []*Tweak
	Extras    []Extra
}

type Suite struct {
	Snapshots bool
	Host      string
	Kernel    string
	Modules   []*Module
}

// parseOutputTabs turns backend section headings of the form "== Name ==" into
// navigable output tabs. Ordinary captured actions remain a single viewport.
func parseOutputTabs(output string) []outputTab {
	var tabs []outputTab
	title := "Output"
	var lines []string
	sawHeading := false
	titleCounts := map[string]int{}
	flush := func() {
		if title == "" || (len(tabs) == 0 && !sawHeading &&
			strings.TrimSpace(strings.Join(lines, "\n")) == "") {
			lines = nil
			return
		}
		displayTitle := title
		titleCounts[title]++
		if titleCounts[title] > 1 {
			displayTitle = fmt.Sprintf("%s (%d)", title, titleCounts[title])
		}
		tabs = append(tabs, outputTab{
			title: displayTitle, content: strings.TrimSpace(strings.Join(lines, "\n")),
		})
		lines = nil
	}
	for _, line := range strings.Split(output, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "== ") && strings.HasSuffix(trimmed, " ==") {
			nextTitle := strings.TrimSpace(
				strings.TrimSuffix(strings.TrimPrefix(trimmed, "== "), " =="),
			)
			if nextTitle == "" || len(nextTitle) > 80 {
				lines = append(lines, line)
				continue
			}
			flush()
			title = nextTitle
			sawHeading = true
			continue
		}
		lines = append(lines, line)
	}
	flush()
	if !sawHeading || len(tabs) < 2 {
		return nil
	}
	return tabs
}

func (m *Module) StagedCount() int {
	n := 0
	for _, t := range m.Tweaks {
		if t.Staged != "" {
			n++
		}
	}
	return n
}

// Enrollment state for the u2f module is encoded in which extras exist:
// an "enroll" action is offered exactly while nothing is enrolled.
func (m *Module) U2FUnenrolled() bool {
	if m.Name != "u2f" {
		return false
	}
	for _, e := range m.Extras {
		if e.ID == "enroll" {
			return true
		}
	}
	return false
}

func scriptPath() string {
	if p := os.Getenv("CACHYOS_TWEAKS_SH"); p != "" {
		return p
	}
	if exe, err := os.Executable(); err == nil {
		p := filepath.Join(filepath.Dir(exe), "..", "tweaks.sh")
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return "./tweaks.sh"
}

func backendNeedsPrivilege() bool {
	return os.Geteuid() != 0 && os.Getenv("CACHYOS_TWEAKS_DEV") == ""
}

// backendCommand keeps the Bubble Tea process unprivileged and elevates only
// the shell backend that reads protected state or changes the system.
func backendCommand(privileged bool, commandEnv []string, args ...string) *exec.Cmd {
	scriptArgs := append([]string{scriptPath()}, args...)
	if !privileged || !backendNeedsPrivilege() {
		cmd := exec.Command("bash", scriptArgs...)
		cmd.Env = append(os.Environ(), commandEnv...)
		if !privileged {
			cmd.Env = append(cmd.Env, "CACHYOS_TWEAKS_UNPRIVILEGED=1")
		}
		return cmd
	}
	sudoArgs := []string{"--non-interactive", "--", "env"}
	sudoArgs = append(sudoArgs, commandEnv...)
	sudoArgs = append(sudoArgs, "bash")
	sudoArgs = append(sudoArgs, scriptArgs...)
	return exec.Command("sudo", sudoArgs...)
}

type authMsg struct {
	err error
}

const sudoAuthInputMarker = "__CACHYOS_TWEAKS_AUTH_INPUT__"

type sudoAuthSession struct {
	cmd    *exec.Cmd
	input  io.WriteCloser
	done   chan struct{}
	exited chan struct{}
	once   sync.Once
}

func (s *sudoAuthSession) cancel() {
	if s == nil {
		return
	}
	if s.input != nil {
		_ = s.input.Close()
	}
	s.once.Do(func() {
		if s.done != nil {
			close(s.done)
		}
	})
	if s.cmd != nil && s.cmd.Process != nil {
		terminateProcessGroup(s.cmd, s.exited)
	}
}

type authStartedMsg struct {
	session *sudoAuthSession
	events  <-chan captureEvent
	err     error
}

type authEventMsg struct {
	session *sudoAuthSession
	event   captureEvent
	events  <-chan captureEvent
}

type authInputMsg struct {
	session *sudoAuthSession
	err     error
}

type authRefreshTickMsg struct{}
type authRefreshMsg struct{ err error }

func scheduleAuthRefresh() tea.Cmd {
	return tea.Tick(60*time.Second, func(time.Time) tea.Msg {
		return authRefreshTickMsg{}
	})
}

func refreshBackendAuthorization() tea.Cmd {
	if !backendNeedsPrivilege() {
		return func() tea.Msg { return authRefreshMsg{} }
	}
	return func() tea.Msg {
		return authRefreshMsg{
			err: exec.Command("sudo", "--non-interactive", "-v").Run(),
		}
	}
}

// probeBackendAuthorization checks an existing timestamp without invoking an
// interactive PAM conversation.
func probeBackendAuthorization() tea.Cmd {
	if !backendNeedsPrivilege() {
		return func() tea.Msg { return authMsg{} }
	}
	return func() tea.Msg {
		err := exec.Command("sudo", "--non-interactive", "-v").Run()
		return authMsg{err: err}
	}
}

// startInteractiveAuthentication begins sudo immediately instead of asking
// for a password first. This preserves the host PAM stack's configured order:
// security keys, fingerprint readers, and other methods get their normal
// opportunity before a password fallback. -S changes only where an eventual
// hidden response is read; it does not replace or reorder PAM.
func startInteractiveAuthentication() tea.Cmd {
	if !backendNeedsPrivilege() {
		return func() tea.Msg { return authStartedMsg{} }
	}
	return func() tea.Msg {
		cmd := exec.Command("sudo", "-S", "-p", sudoAuthInputMarker, "-v")
		session, events, err := startAuthCommand(cmd)
		return authStartedMsg{session: session, events: events, err: err}
	}
}

func startAuthCommand(cmd *exec.Cmd) (*sudoAuthSession, <-chan captureEvent, error) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{
			Pdeathsig: syscall.SIGTERM,
			Setpgid:   true,
		}
	}
	input, err := cmd.StdinPipe()
	if err != nil {
		return nil, nil, err
	}
	reader, writer := io.Pipe()
	cmd.Stdout = writer
	cmd.Stderr = writer
	if err := cmd.Start(); err != nil {
		_ = input.Close()
		_ = reader.Close()
		_ = writer.Close()
		return nil, nil, err
	}

	events := make(chan captureEvent, 32)
	session := &sudoAuthSession{
		cmd: cmd, input: input, done: make(chan struct{}), exited: make(chan struct{}),
	}
	go func() {
		streamCommand(cmd, reader, writer, events, session.done, session.exited)
		_ = input.Close()
	}()
	return session, events, nil
}

func waitAuthEvent(session *sudoAuthSession, events <-chan captureEvent) tea.Cmd {
	return func() tea.Msg {
		event, ok := <-events
		if !ok {
			event = captureEvent{done: true}
		}
		return authEventMsg{session: session, event: event, events: events}
	}
}

func sendAuthenticationInput(session *sudoAuthSession, response string) tea.Cmd {
	return func() tea.Msg {
		if session == nil || session.input == nil {
			return authInputMsg{session: session, err: errors.New("authentication session is not running")}
		}
		_, err := io.WriteString(session.input, response+"\n")
		return authInputMsg{session: session, err: err}
	}
}

func parseDump(out string) (*Suite, error) {
	s := &Suite{}
	byName := map[string]*Module{}
	seenDocuments := map[string]bool{}
	seenTweaks := map[string]bool{}
	seenExtras := map[string]bool{}
	sawSuite := false
	for _, rec := range strings.Split(out, recordSep) {
		rec = strings.TrimLeft(rec, "\r\n")
		if rec == "" {
			continue
		}
		f := strings.Split(rec, fieldSep)
		if !sawSuite && f[0] != "SUITE" {
			return nil, fmt.Errorf("first dump record is not SUITE")
		}
		switch f[0] {
		case "SUITE":
			if len(f) != 4 || (f[1] != "0" && f[1] != "1") ||
				f[2] == "" || f[3] == "" {
				return nil, fmt.Errorf("malformed SUITE record")
			}
			if sawSuite {
				return nil, fmt.Errorf("duplicate SUITE record")
			}
			sawSuite = true
			s.Snapshots = f[1] == "1"
			s.Host, s.Kernel = f[2], f[3]
		case "MODULE":
			if len(f) != 3 || !protocolIDPattern.MatchString(f[1]) || f[2] == "" {
				return nil, fmt.Errorf("malformed MODULE record")
			}
			if f[1] == "" || byName[f[1]] != nil {
				return nil, fmt.Errorf("empty or duplicate MODULE: %q", f[1])
			}
			module := &Module{Name: f[1], Title: f[2]}
			s.Modules = append(s.Modules, module)
			byName[module.Name] = module
		case "DOC":
			if len(f) != 5 {
				return nil, fmt.Errorf("malformed DOC record")
			}
			m := byName[f[1]]
			if m == nil {
				return nil, fmt.Errorf("DOC before MODULE: %s", f[1])
			}
			if f[2] == "" || f[3] == "" || !safeDocumentPath(f[4]) {
				return nil, fmt.Errorf("invalid DOC record for module %s", f[1])
			}
			documentKey := filepath.Clean(filepath.FromSlash(f[4]))
			if seenDocuments[documentKey] {
				return nil, fmt.Errorf("duplicate DOC record for module %s", f[1])
			}
			seenDocuments[documentKey] = true
			m.Documents = append(m.Documents, HelpDocument{
				Module: f[1], Category: f[2], Title: f[3], Path: f[4],
			})
		case "TWEAK":
			if len(f) < 7 || len(f) > 9 {
				return nil, fmt.Errorf("malformed TWEAK record")
			}
			m := byName[f[1]]
			if m == nil {
				return nil, fmt.Errorf("TWEAK before MODULE: %s", f[1])
			}
			if !protocolIDPattern.MatchString(f[2]) || f[3] == "" ||
				!validTweakStatus(f[4]) || (f[5] != "0" && f[5] != "1") {
				return nil, fmt.Errorf("invalid TWEAK record for module %s", f[1])
			}
			tweakKey := f[1] + fieldSep + f[2]
			if seenTweaks[tweakKey] {
				return nil, fmt.Errorf("duplicate TWEAK record: %s/%s", f[1], f[2])
			}
			seenTweaks[tweakKey] = true
			group := ""
			if len(f) >= 8 {
				group = f[7]
				if group != "" && !protocolIDPattern.MatchString(group) {
					return nil, fmt.Errorf("invalid TWEAK group for %s/%s", f[1], f[2])
				}
			}
			category := ""
			if len(f) >= 9 {
				category = f[8]
				if !validTweakCategory(category) {
					return nil, fmt.Errorf("invalid TWEAK category for %s/%s", f[1], f[2])
				}
			}
			m.Tweaks = append(m.Tweaks, &Tweak{
				Module: f[1], ID: f[2], Title: f[3],
				Status: f[4], Toggleable: f[5] == "1", Desc: f[6],
				Group: group, Category: category,
			})
		case "EXTRA":
			if len(f) < 7 || len(f) > 9 {
				return nil, fmt.Errorf("malformed EXTRA record")
			}
			m := byName[f[1]]
			if m == nil {
				return nil, fmt.Errorf("EXTRA before MODULE: %s", f[1])
			}
			if !protocolIDPattern.MatchString(f[2]) || f[3] == "" ||
				(f[4] != "0" && f[4] != "1") ||
				(f[5] != "0" && f[5] != "1") {
				return nil, fmt.Errorf("invalid EXTRA record for module %s", f[1])
			}
			if len(f) >= 8 && f[7] != "0" && f[7] != "1" {
				return nil, fmt.Errorf("invalid EXTRA privilege flag for module %s", f[1])
			}
			if len(f) >= 9 && f[8] != "0" && f[8] != "1" {
				return nil, fmt.Errorf("invalid EXTRA tab flag for module %s", f[1])
			}
			extraKey := f[1] + fieldSep + f[2]
			if seenExtras[extraKey] {
				return nil, fmt.Errorf("duplicate EXTRA record: %s/%s", f[1], f[2])
			}
			seenExtras[extraKey] = true
			needsRoot := true
			if len(f) >= 8 {
				needsRoot = f[7] == "1"
			}
			tabbed := len(f) >= 9 && f[8] == "1"
			m.Extras = append(m.Extras, Extra{
				Module: f[1], ID: f[2], Label: f[3],
				Disabled: f[4] == "1", Capture: f[5] == "1",
				Desc: f[6], NeedsRoot: needsRoot, Tabbed: tabbed,
			})
		default:
			return nil, fmt.Errorf("unknown dump record: %q", f[0])
		}
	}
	if !sawSuite {
		return nil, fmt.Errorf("dump returned no SUITE record")
	}
	if len(s.Modules) == 0 {
		return nil, fmt.Errorf("dump returned no modules")
	}
	return s, nil
}

func validTweakStatus(status string) bool {
	switch status {
	case "on", "off", "drifted", "unmanaged", "n/a":
		return true
	default:
		return false
	}
}

func validTweakCategory(category string) bool {
	return len(category) <= 64 &&
		category == strings.TrimSpace(category) &&
		!strings.ContainsAny(category, "\r\n")
}

type dumpMsg struct {
	suite *Suite
	err   error
}

func loadDump() tea.Msg {
	cmd := exec.Command("bash", scriptPath(), "dump")
	out, stderr, overflow, err := boundedCommandOutput(cmd, maxDumpOutput, 64<<10)
	if overflow {
		return dumpMsg{err: fmt.Errorf("reading suite state failed: output exceeded %d bytes", maxDumpOutput)}
	}
	if err != nil {
		detail := err.Error()
		if len(stderr) > 0 {
			detail = strings.TrimSpace(string(stderr))
		}
		return dumpMsg{err: fmt.Errorf("reading suite state failed: %s", detail)}
	}
	suite, perr := parseDump(string(out))
	return dumpMsg{suite: suite, err: perr}
}

type cappedBuffer struct {
	buffer   bytes.Buffer
	limit    int
	overflow bool
}

func (b *cappedBuffer) Write(p []byte) (int, error) {
	if b.limit < 0 {
		return len(p), nil
	}
	remaining := b.limit - b.buffer.Len()
	if remaining > 0 {
		write := minInt(remaining, len(p))
		_, _ = b.buffer.Write(p[:write])
	}
	if len(p) > remaining {
		b.overflow = true
	}
	return len(p), nil
}

func boundedCommandOutput(cmd *exec.Cmd, stdoutLimit, stderrLimit int) ([]byte, []byte, bool, error) {
	stdout := &cappedBuffer{limit: stdoutLimit}
	stderr := &cappedBuffer{limit: stderrLimit}
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	err := cmd.Run()
	return stdout.buffer.Bytes(), stderr.buffer.Bytes(),
		stdout.overflow || stderr.overflow, err
}

func currentRegdom() string {
	out, err := exec.Command("iw", "reg", "get").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "country ") {
			continue
		}
		code := strings.TrimSuffix(strings.Fields(line)[1], ":")
		if len(code) == 2 && code != "00" {
			return strings.ToUpper(code)
		}
	}
	return ""
}

type captureEvent struct {
	text string
	err  error
	done bool
}

type captureStartedMsg struct {
	session *captureSession
	events  <-chan captureEvent
}

type captureEventMsg struct {
	session *captureSession
	event   captureEvent
	events  <-chan captureEvent
}

type captureSession struct {
	cmd    *exec.Cmd
	done   chan struct{}
	exited chan struct{}
	once   sync.Once
}

func (s *captureSession) cancel() {
	if s == nil {
		return
	}
	s.once.Do(func() {
		if s.done != nil {
			close(s.done)
		}
	})
	if s.cmd != nil && s.cmd.Process != nil {
		terminateProcessGroup(s.cmd, s.exited)
	}
}

func terminateProcessGroup(cmd *exec.Cmd, exited <-chan struct{}) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	if cmd.SysProcAttr != nil && cmd.SysProcAttr.Setpgid {
		pid := cmd.Process.Pid
		_ = syscall.Kill(-pid, syscall.SIGTERM)
		// Give shell traps a short opportunity to remove their temporary
		// files, then guarantee an uncooperative descendant cannot outlive
		// the in-app cancellation.
		go func() {
			timer := time.NewTimer(1500 * time.Millisecond)
			defer timer.Stop()
			select {
			case <-exited:
				return
			case <-timer.C:
				_ = syscall.Kill(-pid, syscall.SIGKILL)
			}
		}()
		return
	}
	_ = cmd.Process.Kill()
}

func waitCaptureEvent(session *captureSession, events <-chan captureEvent) tea.Cmd {
	return func() tea.Msg {
		event, ok := <-events
		if !ok {
			event = captureEvent{done: true}
		}
		return captureEventMsg{session: session, event: event, events: events}
	}
}

// captureBackend runs an output-only action without leaving the alternate
// screen. Output is delivered as it is written so prompts are visible while
// the child is waiting for an authenticator or device.
func captureBackend(request captureRequest) tea.Cmd {
	return func() tea.Msg {
		commandEnv := append([]string{"CACHYOS_TWEAKS_NONINTERACTIVE=1"}, request.env...)
		cmd := backendCommand(request.privileged, commandEnv, request.args...)
		if request.input != "" {
			cmd.Stdin = strings.NewReader(request.input)
		}
		reader, writer := io.Pipe()
		cmd.Stdout = writer
		cmd.Stderr = writer

		events := make(chan captureEvent, 32)
		session := &captureSession{
			cmd: cmd, done: make(chan struct{}), exited: make(chan struct{}),
		}
		cmd.SysProcAttr = &syscall.SysProcAttr{
			Pdeathsig: syscall.SIGTERM,
			Setpgid:   true,
		}
		if err := cmd.Start(); err != nil {
			_ = reader.Close()
			_ = writer.Close()
			events <- captureEvent{err: err, done: true}
			close(events)
			return captureStartedMsg{session: session, events: events}
		}

		go streamCommand(cmd, reader, writer, events, session.done, session.exited)
		return captureStartedMsg{session: session, events: events}
	}
}

func captureExtra(module, id string) tea.Cmd {
	return captureBackend(captureRequest{
		title: "Action", args: []string{"extra", module, id},
	})
}

func streamCommand(
	cmd *exec.Cmd,
	reader *io.PipeReader,
	writer *io.PipeWriter,
	events chan<- captureEvent,
	done <-chan struct{},
	exited chan<- struct{},
) {
	waitDone := make(chan error, 1)
	go func() {
		err := cmd.Wait()
		close(exited)
		_ = writer.Close()
		waitDone <- err
	}()

	buffer := make([]byte, 4096)
	var readErr error
	for {
		n, err := reader.Read(buffer)
		if n > 0 {
			if !sendCaptureEvent(events, captureEvent{text: string(buffer[:n])}, done) {
				break
			}
		}
		if err != nil {
			if !errors.Is(err, io.EOF) {
				readErr = err
			}
			break
		}
	}
	_ = reader.Close()

	err := <-waitDone
	if err == nil && readErr != nil {
		err = readErr
	}
	_ = sendCaptureEvent(events, captureEvent{err: err, done: true}, done)
	close(events)
}

func sendCaptureEvent(events chan<- captureEvent, event captureEvent, done <-chan struct{}) bool {
	select {
	case events <- event:
		return true
	case <-done:
		return false
	}
}
