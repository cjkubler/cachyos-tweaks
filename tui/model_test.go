package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func assertViewBounds(t *testing.T, m *model, name string) string {
	t.Helper()
	view := m.View()
	lines := strings.Split(view, "\n")
	if len(lines) != m.h {
		t.Fatalf("%s: %dx%d view has %d lines", name, m.w, m.h, len(lines))
	}
	for i, line := range lines {
		if width := ansi.StringWidth(line); width > m.w {
			t.Fatalf("%s: %dx%d row %d is %d cells wide: %q",
				name, m.w, m.h, i, width, ansi.Strip(line))
		}
	}
	return view
}

func testModule(n int) *Module {
	mod := &Module{Name: "test", Title: "Test"}
	for i := 0; i < n; i++ {
		mod.Tweaks = append(mod.Tweaks, &Tweak{
			Module: "test", ID: string(rune('a' + i)), Title: "Tweak",
			Status: "off", Toggleable: true,
		})
	}
	return mod
}

func TestToggleAndStageAll(t *testing.T) {
	m := newModel()
	m.mod = testModule(3)
	m.buildRows()

	m.toggle(m.mod.Tweaks[0])
	if got := m.mod.Tweaks[0].Staged; got != "on" {
		t.Fatalf("staged = %q", got)
	}
	m.toggle(m.mod.Tweaks[0])
	if got := m.mod.Tweaks[0].Staged; got != "" {
		t.Fatalf("second toggle staged = %q", got)
	}

	m.stageAll("on")
	if got := m.mod.StagedCount(); got != 3 {
		t.Fatalf("staged count = %d", got)
	}
	m.discardStaged()
	if got := m.mod.StagedCount(); got != 0 {
		t.Fatalf("staged count after discard = %d", got)
	}
}

func TestBuildRowsUsesBackendCategories(t *testing.T) {
	m := newModel()
	m.mod = &Module{
		Name: "system",
		Tweaks: []*Tweak{
			{ID: "resident", Category: "Memory & swap"},
			{ID: "capacity", Category: "Memory & swap"},
			{ID: "uncategorized"},
		},
		Extras: []Extra{{ID: "report", Label: "Inspect"}},
	}
	m.buildRows()

	if len(m.rows) != 7 {
		t.Fatalf("categorized rows = %#v", m.rows)
	}
	want := []struct {
		kind  rowKind
		label string
	}{
		{rowSep, "Memory & swap"},
		{rowTweak, ""},
		{rowTweak, ""},
		{rowSep, "Other"},
		{rowTweak, ""},
		{rowSep, "Actions"},
		{rowExtra, ""},
	}
	for i, expected := range want {
		if m.rows[i].kind != expected.kind || m.rows[i].label != expected.label {
			t.Fatalf("row %d = %#v, want kind=%d label=%q",
				i, m.rows[i], expected.kind, expected.label)
		}
	}
}

func TestCursorScrollingKeepsSelectionVisible(t *testing.T) {
	m := newModel()
	m.scr = scrModule
	m.mod = testModule(12)
	m.buildRows()
	m.listH = 4

	for range 7 {
		m.move(1)
	}
	if m.cursor != 7 {
		t.Fatalf("cursor = %d", m.cursor)
	}
	if m.rowOffset != 4 {
		t.Fatalf("row offset = %d", m.rowOffset)
	}
}

func TestViewsFitTerminalHeight(t *testing.T) {
	for _, size := range [][2]int{
		{40, 10}, {60, 15}, {80, 18}, {120, 30}, {180, 40}, {240, 50},
	} {
		m := newModel()
		m.w, m.h = size[0], size[1]
		mod := testModule(12)
		m.suite = &Suite{Host: "test", Kernel: "test", Modules: []*Module{mod}}
		m.scr = scrMain

		assertViewBounds(t, m, "main")

		m.mod = mod
		m.scr = scrModule
		m.buildRows()
		mod.Tweaks[0].Staged = "on"
		assertViewBounds(t, m, "module")

		m.showHelp = true
		assertViewBounds(t, m, "help")
		m.showHelp = false
		m.scr = scrMain
		m.snapshotConfirm = true
		assertViewBounds(t, m, "snapshot confirmation")
		m.snapshotConfirm = false
		m.authPrompt = true
		assertViewBounds(t, m, "authorization prompt")
		m.authPrompt = false
		m.modal = true
		m.modalTitle = "Diagnostics"
		m.modalContent = "line one\nline two"
		m.modalTabs = []outputTab{
			{title: "USB4", content: "line one"},
			{title: "Devices", content: "line two"},
		}
		m.modalLayout()
		view := ansi.Strip(assertViewBounds(t, m, "output modal"))
		if m.h < 14 && (strings.Contains(view, "╭") || strings.Contains(view, "╰")) {
			t.Fatalf("compact output modal used a panel that could be clipped: %q", view)
		}
	}
}

func TestCaptureEventsAppearWhileModalRuns(t *testing.T) {
	m := newModel()
	m.w, m.h = 80, 20
	m.suite = &Suite{Host: "test", Kernel: "test", Modules: []*Module{testModule(1)}}
	m.modal = true
	m.modalRunning = true
	session := &captureSession{}
	m.captureSession = session

	_, cmd := m.onCaptureEvent(captureEventMsg{
		session: session,
		event:   captureEvent{text: "Touch the authenticator now.\n"},
		events:  make(chan captureEvent),
	})
	if cmd == nil {
		t.Fatal("stream did not request the next event")
	}
	if !m.modalRunning || !strings.Contains(m.modalContent, "Touch the authenticator now.") {
		t.Fatalf("running modal content = %q", m.modalContent)
	}

	_, cmd = m.onCaptureEvent(captureEventMsg{
		session: session,
		event:   captureEvent{done: true},
	})
	if cmd != nil || m.modalRunning {
		t.Fatal("completed capture is still running")
	}
}

func TestTabbedCaptureNavigation(t *testing.T) {
	m := newModel()
	m.w, m.h = 80, 20
	m.suite = &Suite{Host: "test", Kernel: "test", Modules: []*Module{testModule(1)}}
	m.modal = true
	m.modalRunning = true
	m.modalTabbed = true
	m.modalContent = "== USB4 ==\ndomain ok\n== GPUs ==\nexternal gpu ok\n"
	m.modalRaw = m.modalContent
	session := &captureSession{}
	m.captureSession = session

	_, _ = m.onCaptureEvent(captureEventMsg{
		session: session,
		event:   captureEvent{done: true},
	})
	if len(m.modalTabs) != 2 || strings.TrimSpace(m.vp.View()) != "domain ok" {
		t.Fatalf("completed diagnostic tabs = %#v, viewport %q", m.modalTabs, m.vp.View())
	}
	_, _ = m.onModalKey(tea.KeyMsg{Type: tea.KeyRight})
	if m.modalTab != 1 || strings.TrimSpace(m.vp.View()) != "external gpu ok" {
		t.Fatalf("selected diagnostic tab = %d, viewport %q", m.modalTab, m.vp.View())
	}
	view := m.View()
	if !strings.Contains(view, "1 USB4") || !strings.Contains(view, "2 GPUs") {
		t.Fatalf("tabbed modal did not render its tabs: %q", view)
	}
}

func TestFocusedClippedLabelMarqueesInPlace(t *testing.T) {
	label := "A much longer setting title"
	if got := marqueeText(label, 10, 0); got != "A much lon" {
		t.Fatalf("initial marquee = %q", got)
	}
	later := marqueeText(label, 10, 12)
	if later == "A much lon" || ansi.StringWidth(later) > 10 {
		t.Fatalf("moving marquee = %q", later)
	}
}

func TestSelectionAndHoverMarqueesResetIndependently(t *testing.T) {
	m := newModel()
	m.w, m.h = 80, 18
	first, second := testModule(1), testModule(1)
	first.Title = "A selected module with a long scrolling label"
	second.Title = "A hovered module with a long scrolling label"
	m.suite = &Suite{Host: "host", Kernel: "kernel", Modules: []*Module{first, second}}
	m.scr = scrMain
	_ = m.View()

	m.focusMarquee = 11
	m.hoverMarquee = 7
	_, _ = m.onMouse(tea.MouseMsg{
		X: m.listLeft, Y: m.listTop + 1,
		Action: tea.MouseActionMotion,
	})
	if m.focusMarquee != 11 || m.hoverMarquee != 0 || m.hover != 1 {
		t.Fatalf("hover reset focus=%d hover=%d row=%d",
			m.focusMarquee, m.hoverMarquee, m.hover)
	}

	_, _ = m.Update(marqueeTickMsg{})
	if m.focusMarquee != 12 || m.hoverMarquee != 1 {
		t.Fatalf("independent tick focus=%d hover=%d",
			m.focusMarquee, m.hoverMarquee)
	}
	m.move(1)
	if m.focusMarquee != 0 || m.hoverMarquee != 1 {
		t.Fatalf("selection reset focus=%d hover=%d",
			m.focusMarquee, m.hoverMarquee)
	}
}

func TestHeaderIncludesBuildRevision(t *testing.T) {
	previous := buildRevision
	buildRevision = "abc123def456"
	t.Cleanup(func() { buildRevision = previous })

	m := newModel()
	m.w, m.h = 80, 20
	m.suite = &Suite{Host: "host", Kernel: "kernel"}
	if got := m.hostInfo(); !strings.Contains(got, buildRevision) {
		t.Fatalf("header info %q does not contain revision %q", got, buildRevision)
	}
}

func TestManualSnapshotRequiresConfirmation(t *testing.T) {
	m := newModel()
	m.w, m.h = 80, 20
	m.scr = scrMain
	m.suite = &Suite{
		Snapshots: true,
		Modules:   []*Module{testModule(1)},
	}

	_, cmd := m.onKey("s")
	if cmd != nil || !m.snapshotConfirm || m.pendingCapture != nil {
		t.Fatal("snapshot skipped its confirmation modal")
	}

	_, cmd = m.onSnapshotConfirmKey("enter")
	if cmd == nil || m.pendingCapture == nil || m.snapshotConfirm {
		t.Fatal("confirmed snapshot did not request authorization")
	}
	if got := strings.Join(m.pendingCapture.args, " "); got != "snapshot create" {
		t.Fatalf("snapshot backend arguments = %q", got)
	}
	if !m.modal || m.modalRunning || m.modalTitle != "Create snapshot" {
		t.Fatalf("snapshot modal state = %#v", m)
	}
	if backendNeedsPrivilege() {
		if !m.authPrompt || !m.authChecking {
			t.Fatal("snapshot did not keep administrator authorization inside the TUI")
		}
		_, startCmd := m.onAuth(authMsg{})
		if startCmd == nil || m.pendingCapture != nil || !m.modalRunning || m.authPrompt {
			t.Fatal("successful authorization did not start the captured snapshot")
		}
	}
}

func TestManualSnapshotCancelDoesNotAuthorize(t *testing.T) {
	m := newModel()
	m.snapshotConfirm = true

	_, cmd := m.onSnapshotConfirmKey("esc")
	if cmd != nil || m.snapshotConfirm || m.pendingCapture != nil {
		t.Fatal("cancelled snapshot started backend work")
	}
}

func TestDiscardRequiresConfirmation(t *testing.T) {
	m := newModel()
	m.w, m.h = 60, 15
	m.mod = testModule(1)
	m.mod.Tweaks[0].Staged = "on"
	m.suite = &Suite{Modules: []*Module{m.mod}}
	m.scr = scrModule

	_, _ = m.onKey("d")
	if !m.discardConfirm || m.mod.StagedCount() != 1 {
		t.Fatal("discard key cleared staging without confirmation")
	}
	_, _ = m.onDiscardConfirmKey("esc")
	if m.discardConfirm || m.mod.StagedCount() != 1 {
		t.Fatal("cancelled discard did not preserve staging")
	}
	_, _ = m.onKey("d")
	_, _ = m.onDiscardConfirmKey("enter")
	if m.discardConfirm || m.mod.StagedCount() != 0 {
		t.Fatal("confirmed discard did not clear staging")
	}
}

func TestBackWithStagingUsesDiscardConfirmation(t *testing.T) {
	m := newModel()
	m.mod = testModule(1)
	m.mod.Tweaks[0].Staged = "on"
	m.suite = &Suite{Modules: []*Module{m.mod}}
	m.scr = scrModule

	_, _ = m.goBack()
	if !m.discardConfirm || !m.discardGoBack || m.scr != scrModule {
		t.Fatal("back with staging did not open a discard confirmation")
	}
	_, _ = m.onDiscardConfirmKey("enter")
	if m.discardConfirm || m.mod != nil || m.scr != scrMain {
		t.Fatal("confirmed back-discard did not return to the dashboard")
	}
}

func TestButtonHoverOnlyHighlightsClickableControls(t *testing.T) {
	m := newModel()
	m.footerY = 12
	m.buttons = []*button{
		{label: "Active", x0: 10, x1: 19},
		{label: "Disabled", dim: true, x0: 22, x1: 33},
	}

	m.updateButtonHover(14, 12)
	if m.hoverBtn != 0 {
		t.Fatalf("active button hover = %d", m.hoverBtn)
	}
	m.updateButtonHover(25, 12)
	if m.hoverBtn != -1 {
		t.Fatalf("disabled button hover = %d", m.hoverBtn)
	}
	m.updateButtonHover(1, 1)
	if m.hoverBtn != -1 {
		t.Fatalf("empty-area hover = %d", m.hoverBtn)
	}
}

func TestAuthorizationFailureStartsConfiguredSystemFlow(t *testing.T) {
	m := newModel()
	m.w, m.h = 80, 20
	m.modal = true
	m.authPrompt = true
	m.authChecking = true
	m.pendingCapture = &captureRequest{
		title: "Create snapshot", args: []string{"snapshot", "create"}, privileged: true,
	}

	_, cmd := m.onAuth(authMsg{err: os.ErrPermission})
	if cmd == nil || !m.authPrompt || !m.authChecking || m.authInput.Focused() {
		t.Fatal("failed sudo probe did not begin the configured authentication flow")
	}
	if m.modalRunning {
		t.Fatal("backend started before administrator authentication")
	}

	session := &sudoAuthSession{}
	m.authSession = session
	_, cmd = m.onAuthEvent(authEventMsg{
		session: session,
		event:   captureEvent{text: "Touch the configured authenticator now."},
		events:  make(chan captureEvent),
	})
	if cmd == nil || m.authInput.Focused() || m.authNeedsReply() {
		t.Fatal("authenticator-first prompt incorrectly requested a password response")
	}
	_, cmd = m.onAuthEvent(authEventMsg{
		session: session,
		event:   captureEvent{text: sudoAuthInputMarker},
		events:  make(chan captureEvent),
	})
	if cmd == nil || !m.authInput.Focused() || !m.authNeedsReply() {
		t.Fatal("sudo input request did not reveal the masked response field")
	}
	m.authInput.SetValue("secret")
	_, cmd = m.submitAuthentication()
	if cmd == nil || !m.authChecking || m.authInput.Value() != "" ||
		m.authReplies != 1 {
		t.Fatal("authentication response was not cleared and sent asynchronously")
	}
	if strings.Contains(authTranscript(m.authOutput, 80, 5), sudoAuthInputMarker) {
		t.Fatal("internal sudo response marker leaked into the visible transcript")
	}
}

func TestAuthorizationViewDoesNotLeadWithPassword(t *testing.T) {
	m := newModel()
	m.w, m.h = 80, 22
	m.suite = &Suite{Host: "test", Kernel: "test", Modules: []*Module{testModule(1)}}
	m.authPrompt = true
	m.authChecking = true
	m.authSession = &sudoAuthSession{}
	m.authOutput = "Please touch the configured security key."

	view := ansi.Strip(m.View())
	if !strings.Contains(view, "Please touch the configured security key") {
		t.Fatalf("configured authentication prompt is not visible: %q", view)
	}
	if strings.Contains(view, "hidden response") {
		t.Fatalf("password-style input appeared before sudo requested it: %q", view)
	}

	m.authOutput += sudoAuthInputMarker
	m.authPrompts = 1
	view = ansi.Strip(m.View())
	if !strings.Contains(view, "sudo is requesting a hidden response") {
		t.Fatalf("sudo fallback did not reveal masked input: %q", view)
	}
}

func TestStartupAuthorizationCanBeDeferred(t *testing.T) {
	m := newModel()
	t.Setenv(noStartupAuthEnv, "1")
	_, cmd := m.requestStartupAuthorization()
	if cmd != nil || m.authPrompt || m.authStartup {
		t.Fatal("--no-sudo still requested startup authorization")
	}

	if !backendNeedsPrivilege() {
		return
	}
	t.Setenv(noStartupAuthEnv, "")
	_, cmd = m.requestStartupAuthorization()
	if cmd == nil || !m.authPrompt || !m.authChecking || !m.authStartup {
		t.Fatal("default launch did not begin in-app startup authorization")
	}
	_, _ = m.onAuth(authMsg{})
	if m.authPrompt || m.authChecking || m.authStartup {
		t.Fatal("successful startup authorization did not return to the TUI")
	}
}

func TestReadOnlyExtraStartsWithoutAuthorization(t *testing.T) {
	m := newModel()
	m.w, m.h = 80, 20
	m.mod = &Module{
		Name: "egpu",
		Extras: []Extra{{
			Module: "egpu", ID: "diag", Label: "Run eGPU diagnostics",
			Capture: true, NeedsRoot: false,
		}},
	}
	m.buildRows()

	_, cmd := m.activate(1) // row 0 is the actions separator
	if cmd == nil || !m.modal || !m.modalRunning {
		t.Fatal("read-only diagnostic did not start in its output modal")
	}
	if m.authPrompt || m.pendingCapture != nil {
		t.Fatal("read-only diagnostic requested administrator authorization")
	}
}

func TestPolicyChoicesStageExclusively(t *testing.T) {
	m := newModel()
	m.mod = &Module{
		Name: "system",
		Tweaks: []*Tweak{
			{ID: "default", Status: "on", Toggleable: true, Group: "memory"},
			{ID: "resident", Status: "off", Toggleable: true, Group: "memory"},
			{ID: "capacity", Status: "off", Toggleable: true, Group: "memory"},
		},
	}
	m.buildRows()

	m.toggle(m.mod.Tweaks[0])
	if m.mod.StagedCount() != 0 {
		t.Fatal("active policy was staged off")
	}
	m.toggle(m.mod.Tweaks[1])
	if m.mod.Tweaks[1].Staged != "on" || m.mod.StagedCount() != 1 {
		t.Fatal("policy choice was not staged")
	}
	m.toggle(m.mod.Tweaks[2])
	if m.mod.Tweaks[1].Staged != "" || m.mod.Tweaks[2].Staged != "on" ||
		m.mod.StagedCount() != 1 {
		t.Fatal("policy choices were not mutually exclusive")
	}
	m.stageAll("on")
	if m.mod.StagedCount() != 1 {
		t.Fatal("bulk staging changed a mutually exclusive policy")
	}
}

func TestWideLayoutsRecordAccurateMouseGeometry(t *testing.T) {
	for _, size := range [][2]int{{150, 24}, {180, 40}, {240, 50}} {
		m := newModel()
		m.w, m.h = size[0], size[1]
		first, second := testModule(4), testModule(5)
		first.Title, second.Title = "First", "Second"
		m.suite = &Suite{Host: "host", Kernel: "kernel", Modules: []*Module{first, second}}
		m.scr = scrMain
		view := ansi.Strip(assertViewBounds(t, m, "wide main"))
		if !strings.Contains(view, ".------.") || !strings.Contains(view, "+++++") {
			t.Fatalf("%dx%d wide main omitted the project logo", m.w, m.h)
		}
		if m.listLeft <= logoPad {
			t.Fatalf("%dx%d module navigator did not follow the logo", m.w, m.h)
		}
		if got := m.rowAt(m.listLeft, m.listTop+1); got != 1 {
			t.Fatalf("%dx%d wide main mouse row = %d, want 1", m.w, m.h, got)
		}
	}

	m := newModel()
	m.w, m.h = 240, 50
	first := testModule(4)
	m.suite = &Suite{Host: "host", Kernel: "kernel", Modules: []*Module{first}}
	m.mod = first
	m.scr = scrModule
	m.buildRows()
	_ = m.View()
	if m.listLeft <= 0 {
		t.Fatal("wide module layout did not center its settings pane")
	}
	if got := m.rowAt(m.listLeft, m.listTop+1); got != 1 {
		t.Fatalf("wide module mouse row = %d, want 1", got)
	}
}

func TestStagingDoesNotMoveModuleDashboard(t *testing.T) {
	for _, width := range []int{80, 180} {
		m := newModel()
		m.w, m.h = width, 30
		m.mod = testModule(4)
		m.mod.Title = "Stable dashboard"
		m.suite = &Suite{Host: "host", Kernel: "kernel", Modules: []*Module{m.mod}}
		m.scr = scrModule
		m.buildRows()

		_ = m.View()
		unstagedTop := m.listTop
		m.mod.Tweaks[0].Staged = "on"
		_ = m.View()
		if m.listTop != unstagedTop {
			t.Fatalf("width %d: staged dashboard moved from row %d to %d",
				width, unstagedTop, m.listTop)
		}
	}
}

func TestDocumentCenterLoadsRendersAndNavigates(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CACHYOS_TWEAKS_SH", filepath.Join(root, "tweaks.sh"))
	for _, spec := range projectDocumentSpecs {
		content := "# " + spec.title + "\n\nDocument body for " + spec.filename + ".\n"
		if err := os.WriteFile(filepath.Join(root, spec.filename), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	modulePath := filepath.Join(root, "modules", "system", "memory", "README.md")
	if err := os.MkdirAll(filepath.Dir(modulePath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(modulePath, []byte("# Memory and swap\n\nModule help.\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	m := newModel()
	m.w, m.h = 80, 20
	m.scr = scrMain
	module := testModule(1)
	module.Documents = []HelpDocument{{
		Module: "test", Category: "General OS", Title: "Memory & swap",
		Path: "modules/system/memory/README.md",
	}}
	m.suite = &Suite{Host: "test", Kernel: "test", Modules: []*Module{module}}

	_, cmd := m.onKey("i")
	if cmd != nil || m.scr != scrDocuments ||
		len(m.documents) != len(projectDocumentSpecs)+1 {
		t.Fatalf("document center did not open: screen=%d docs=%d", m.scr, len(m.documents))
	}
	if content := m.docVP.View(); !strings.Contains(content, "Overview") ||
		!strings.Contains(content, "Document body") {
		t.Fatalf("rendered document = %q", content)
	}

	m.docVP.LineDown(3)
	_, _ = m.onKey("down")
	if m.docTab != 1 || m.docVP.YOffset != 0 {
		t.Fatalf("topic switch = %d, offset = %d", m.docTab, m.docVP.YOffset)
	}
	if !strings.Contains(ansi.Strip(m.docVP.View()), "Memory and swap") {
		t.Fatalf("module document was not loaded: %q", m.docVP.View())
	}

	view := m.View()
	if lines := strings.Count(view, "\n") + 1; lines != m.h {
		t.Fatalf("document view has %d lines, want %d", lines, m.h)
	}
	if len(m.docTabs) == 0 {
		t.Fatal("document topics did not record mouse hitboxes")
	}
	tab := m.docTabs[0]
	_, _ = m.onDocumentMouse(tea.MouseMsg{
		X: tab.x0, Y: tab.y, Button: tea.MouseButtonLeft, Action: tea.MouseActionPress,
	})
	if m.docTab != 0 {
		t.Fatalf("clicked topic selected %d", m.docTab)
	}
}

func TestDocumentViewsFitTerminalHeight(t *testing.T) {
	for _, size := range [][2]int{
		{40, 10}, {60, 15}, {80, 18}, {120, 30}, {180, 40}, {240, 50},
	} {
		m := newModel()
		m.w, m.h = size[0], size[1]
		m.suite = &Suite{Host: "test", Kernel: "test", Modules: []*Module{testModule(1)}}
		m.documents = []document{{
			category: "Start here", title: "Overview", filename: "README.md",
			body: "# Hello\n\n" + strings.Repeat("word ", 100),
		}}
		m.scr = scrDocuments
		m.layoutDocument(true)
		assertViewBounds(t, m, "document")
		if m.w >= 200 && m.docVP.Width > 100 {
			t.Fatalf("wide document reading surface is %d columns", m.docVP.Width)
		}
	}
}

func TestConfirmationIsScrollableAtConstrainedSizes(t *testing.T) {
	m := newModel()
	m.w, m.h = 40, 10
	m.mod = testModule(12)
	for i, tweak := range m.mod.Tweaks {
		tweak.Title = fmt.Sprintf("Tweak number %02d with a long title", i+1)
		tweak.Staged = "on"
	}
	m.suite = &Suite{Host: "host", Kernel: "kernel", Modules: []*Module{m.mod}}
	m.scr = scrConfirm
	m.buildConfirm()

	top := ansi.Strip(assertViewBounds(t, m, "constrained confirmation"))
	if !strings.Contains(top, "Tweak number 01") ||
		m.confirmVP.TotalLineCount() <= m.confirmVP.Height {
		t.Fatalf("confirmation did not expose a scrollable operation list: %q", top)
	}
	if strings.Contains(top, "╭") || strings.Contains(top, "╰") {
		t.Fatalf("compact confirmation used a panel that could be clipped: %q", top)
	}
	_, _ = m.onKey("G")
	bottom := ansi.Strip(assertViewBounds(t, m, "scrolled confirmation"))
	if !strings.Contains(bottom, "Snapshots:") {
		t.Fatalf("confirmation could not scroll to its final safety note: %q", bottom)
	}
}

func TestConstrainedPromptsKeepPrimaryInputVisible(t *testing.T) {
	m := newModel()
	m.w, m.h = 40, 10
	m.suite = &Suite{Host: "host", Kernel: "kernel", Modules: []*Module{testModule(1)}}
	m.authPrompt = true
	m.authChecking = true
	m.authSession = &sudoAuthSession{}
	m.authPrompts = 1
	view := ansi.Strip(assertViewBounds(t, m, "compact auth"))
	if !strings.Contains(view, "hidden response") ||
		!strings.Contains(view, "Type the requested response") {
		t.Fatalf("compact authorization hid its response field: %q", view)
	}

	m.authPrompt = false
	m.configPrompt = true
	view = ansi.Strip(assertViewBounds(t, m, "compact config"))
	if !strings.Contains(view, "Country code") {
		t.Fatalf("compact configuration hid its input: %q", view)
	}
}

func TestModuleDetailsRemainReachableInCompactLayout(t *testing.T) {
	m := newModel()
	m.w, m.h = 40, 10
	m.mod = testModule(1)
	m.mod.Tweaks[0].Desc = "A safety-critical tradeoff that must remain readable."
	m.suite = &Suite{Host: "host", Kernel: "kernel", Modules: []*Module{m.mod}}
	m.scr = scrModule
	m.buildRows()

	_, _ = m.onKey("right")
	if !m.modal || m.modalRunning ||
		!strings.Contains(ansi.Strip(m.vp.View()), "safety-critical tradeoff") {
		t.Fatal("compact module did not open its selected-row details")
	}
	assertViewBounds(t, m, "compact details")
}

func TestCapturedOutputIsSanitizedBoundedAndCancelable(t *testing.T) {
	raw := "\x1b]11;red\ahello\x00\nworld\x1b[31m!\x1b[0m"
	if got := sanitizeCapturedText(raw); got != "hello\nworld!" {
		t.Fatalf("sanitized output = %q", got)
	}

	m := newModel()
	m.w, m.h = 80, 20
	m.modal = true
	m.modalRunning = true
	m.modalCancelable = true
	session := &captureSession{done: make(chan struct{})}
	m.captureSession = session
	m.cancelRunningCapture()
	if m.modalRunning || m.captureSession != nil ||
		!strings.Contains(ansi.Strip(m.modalContent), "Action cancelled") {
		t.Fatal("read-only capture cancellation did not reach a completed state")
	}
	select {
	case <-session.done:
	default:
		t.Fatal("capture cancellation did not signal the stream")
	}
}

func TestRefreshClearsOnlyStaleStagedIntent(t *testing.T) {
	m := newModel()
	old := testModule(1)
	old.Tweaks[0].Staged = "on"
	m.suite = &Suite{Modules: []*Module{old}}
	m.mod = old
	m.scr = scrModule
	m.saveStaged()

	fresh := testModule(1)
	fresh.Tweaks[0].Status = "on"
	_, _ = m.onDump(dumpMsg{suite: &Suite{Modules: []*Module{fresh}}})
	if fresh.Tweaks[0].Staged != "" || !strings.Contains(m.note, "changed during refresh") {
		t.Fatal("refresh silently reinterpreted stale staged state")
	}
}

func TestPromptedExtraCollectsInputBeforeRunning(t *testing.T) {
	m := newModel()
	m.w, m.h = 80, 20
	m.mod = &Module{
		Name: "system",
		Extras: []Extra{{
			Module: "system", ID: "ssh-import-keys", Label: "Add authorized keys",
			Capture: true, NeedsRoot: false,
			Prompt: "GitHub username — or gitlab:USER, an https:// URL, or a public key line",
		}},
	}
	m.suite = &Suite{Host: "host", Kernel: "kernel", Modules: []*Module{m.mod}}
	m.buildRows()

	_, cmd := m.activate(1) // row 0 is the actions separator
	if cmd == nil || !m.configPrompt || m.configSpec == nil || m.pendingCapture == nil {
		t.Fatal("prompted action did not open its input prompt")
	}
	if m.modalRunning {
		t.Fatal("prompted action started before its input was collected")
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "GitHub username") {
		t.Fatalf("prompt view does not show the backend wording: %q", view)
	}

	m.configInput.SetValue("   ")
	_, _ = m.submitConfiguration()
	if m.configError == "" || !m.configPrompt {
		t.Fatal("blank input was accepted")
	}

	request := m.pendingCapture
	m.configInput.SetValue("  octocat ")
	_, cmd = m.submitConfiguration()
	if cmd == nil || m.configPrompt || !m.modal || !m.modalRunning {
		t.Fatal("valid input did not start the unprivileged action")
	}
	found := false
	for _, env := range request.env {
		if env == "CACHYOS_TWEAKS_EXTRA_INPUT=octocat" {
			found = true
		}
	}
	if !found {
		t.Fatalf("collected input did not reach the backend environment: %#v", request.env)
	}
}

func TestMainMenuUpdateRunsOnlyOnPortableInstalls(t *testing.T) {
	m := newModel()
	m.w, m.h = 80, 20
	m.scr = scrMain
	m.suite = &Suite{Host: "host", Kernel: "kernel", Modules: []*Module{testModule(1)}}

	t.Setenv("CACHYOS_TWEAKS_PORTABLE_ROOT", "")
	_, cmd := m.onKey("u")
	if cmd != nil || m.modal || m.pendingCapture != nil || m.note == "" {
		t.Fatal("non-portable install offered a self-update")
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "[ Update ]") {
		t.Fatalf("main menu does not render the update control: %q", view)
	}

	t.Setenv("CACHYOS_TWEAKS_PORTABLE_ROOT", t.TempDir())
	_, cmd = m.onKey("u")
	if cmd == nil || !m.modal || !m.modalRunning ||
		m.modalTitle != "Update Tweaks for CachyOS" {
		t.Fatal("portable install did not start the update from the main menu")
	}
	if m.authPrompt || m.captureRefresh {
		t.Fatal("suite update requested privilege or a state refresh it does not need")
	}
}

func TestDocumentsRejectSymlinkEscapesAndOversizeFiles(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "outside.md")
	if err := os.WriteFile(outside, []byte("secret outside content"), 0o644); err != nil {
		t.Fatal(err)
	}
	moduleDir := filepath.Join(root, "modules", "test")
	if err := os.MkdirAll(moduleDir, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(moduleDir, "escape.md")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	doc := readDocument(root, "Hardware", "Escape", "modules/test/escape.md")
	if strings.Contains(doc.body, "secret outside content") ||
		!strings.Contains(doc.body, "unavailable") {
		t.Fatalf("symlinked document escaped the module root: %q", doc.body)
	}

	large := filepath.Join(moduleDir, "large.md")
	if err := os.WriteFile(large, []byte(strings.Repeat("x", maxDocumentSize+1)), 0o644); err != nil {
		t.Fatal(err)
	}
	doc = readDocument(root, "Hardware", "Large", "modules/test/large.md")
	if !strings.Contains(doc.body, "unavailable") ||
		!strings.Contains(doc.body, "exceeds") {
		t.Fatalf("oversize document was not bounded: %q", doc.body)
	}
}
