package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/help"
	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/progress"
	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

const (
	maxCapturedOutput = 1 << 20
	maxAuthTranscript = 64 << 10
)

type screen int

const (
	scrLoading screen = iota
	scrMain
	scrModule
	scrConfirm
	scrDocuments
)

type rowKind int

const (
	rowTweak rowKind = iota
	rowExtra
	rowSep
)

type row struct {
	kind  rowKind
	tweak *Tweak
	extra *Extra
	label string
}

// Footer button; x0/x1 are the clickable span recorded at render time.
type button struct {
	label  string
	action string
	dim    bool
	x0, x1 int
}

type captureRequest struct {
	title      string
	args       []string
	input      string
	env        []string
	privileged bool
	refresh    bool
	prompt     *promptSpec // non-nil: collect one input line before running
	tabbed     bool
	cancelable bool
}

// promptSpec describes the single line of input a backend request needs
// before it can run. The validated value reaches the backend as envVar=value.
type promptSpec struct {
	title       string
	heading     string
	detail      string
	hint        string
	inputPrompt string
	placeholder string
	envVar      string
	charLimit   int
	initial     string
	validate    func(string) (value, problem string)
}

func regdomPrompt() *promptSpec {
	return &promptSpec{
		title:       "Wi-Fi regulatory domain",
		heading:     "Choose the wireless country code",
		detail:      "This controls the permitted Wi-Fi channels and transmit limits.",
		hint:        "Use the two-letter ISO code for your current country.",
		inputPrompt: "Country code › ",
		placeholder: "US",
		envVar:      "CACHYOS_TWEAKS_REGDOM",
		charLimit:   2,
		initial:     currentRegdom(),
		validate: func(raw string) (string, string) {
			value := strings.ToUpper(strings.TrimSpace(raw))
			if len(value) != 2 || value[0] < 'A' || value[0] > 'Z' ||
				value[1] < 'A' || value[1] > 'Z' {
				return "", "Enter a two-letter ISO country code."
			}
			return value, ""
		},
	}
}

// extraPrompt adapts a backend-declared action prompt: the backend owns the
// wording and the validation; the frontend only refuses an empty value.
func extraPrompt(label, heading string) *promptSpec {
	return &promptSpec{
		title:       label,
		heading:     heading,
		hint:        "The action validates the value and reports any problem.",
		inputPrompt: "› ",
		envVar:      "CACHYOS_TWEAKS_EXTRA_INPUT",
		charLimit:   512,
		validate: func(raw string) (string, string) {
			value := strings.TrimSpace(raw)
			if value == "" {
				return "", "Enter a value first."
			}
			return value, ""
		},
	}
}

type outputTab struct {
	title   string
	content string
}

type marqueeTickMsg time.Time

type stagedState struct {
	target string
	status string
}

func marqueeTick() tea.Cmd {
	return tea.Tick(180*time.Millisecond, func(t time.Time) tea.Msg {
		return marqueeTickMsg(t)
	})
}

type model struct {
	scr      screen
	suite    *Suite
	err      error
	w, h     int
	spin     spinner.Model
	help     help.Model
	keys     keyMap
	progress progress.Model
	loading  bool

	modCursor    int
	mod          *Module
	rows         []row
	cursor       int
	hover        int
	hoverBtn     int
	note         string
	showHelp     bool
	rowOffset    int
	modOffset    int
	listH        int
	focusMarquee int
	hoverMarquee int

	// Staging to re-apply after a refresh that shouldn't lose it.
	keepStaged map[string]stagedState

	// Output modal for capture-mode actions (diagnostics, key test, ...).
	modal           bool
	modalTitle      string
	modalRunning    bool
	modalContent    string
	modalRaw        string
	modalTruncated  bool
	modalCancelable bool
	modalTabbed     bool
	modalTabs       []outputTab
	modalTab        int
	modalTabHover   int
	modalTabHits    []tabHitbox
	vp              viewport.Model
	pendingCapture  *captureRequest
	captureSession  *captureSession
	snapshotConfirm bool
	discardConfirm  bool
	discardGoBack   bool
	captureRefresh  bool

	authPrompt   bool
	authChecking bool
	authStartup  bool
	authReady    bool
	authInput    textinput.Model
	authError    string
	authSession  *sudoAuthSession
	authOutput   string
	authPrompts  int
	authReplies  int

	configPrompt bool
	configInput  textinput.Model
	configError  string
	configSpec   *promptSpec

	// Offline document center. Glamour renders the selected source into its
	// own viewport whenever the terminal width or active topic changes.
	documents    []document
	docTab       int
	docHover     int
	docRenderW   int
	docNavOffset int
	docVP        viewport.Model
	docTabs      []tabHitbox

	confirmOps   []string
	confirmLines []string
	confirmVP    viewport.Model

	// Geometry recorded by View for mouse mapping.
	listTop  int
	listLeft int
	listW    int
	footerY  int
	buttons  []*button
}

func newModel() *model {
	sp := spinner.New(spinner.WithSpinner(spinner.MiniDot))
	sp.Style = sAccent
	h := help.New()
	h.Styles.ShortKey = sAccent
	h.Styles.FullKey = sAccent
	h.Styles.ShortDesc = sSubtle
	h.Styles.FullDesc = sSubtle
	p := progress.New(
		progress.WithGradient(string(cAccent), string(cGreen)),
		progress.WithoutPercentage(),
	)
	ti := textinput.New()
	ti.Placeholder = "Type the requested response"
	ti.Prompt = "› "
	ti.EchoMode = textinput.EchoPassword
	ti.EchoCharacter = '•'
	ti.CharLimit = 256
	ti.Width = 36
	ci := textinput.New()
	ci.Placeholder = "US"
	ci.Prompt = "Country code › "
	ci.CharLimit = 2
	ci.Width = 18
	return &model{
		scr: scrLoading, spin: sp, hover: -1, hoverBtn: -1, docHover: -1, loading: true,
		vp: viewport.New(0, 0), docVP: viewport.New(0, 0),
		confirmVP: viewport.New(0, 0),
		help:      h, keys: newKeyMap(), progress: p, authInput: ti, configInput: ci,
	}
}

func (m *model) Init() tea.Cmd {
	return tea.Batch(m.spin.Tick, marqueeTick(), loadDump)
}

// ---------------------------------------------------------------------------
// Row plumbing
// ---------------------------------------------------------------------------

func moduleHasTweakCategories(mod *Module) bool {
	if mod == nil {
		return false
	}
	for _, tweak := range mod.Tweaks {
		if tweak.Category != "" {
			return true
		}
	}
	return false
}

func tweakDisplayCategory(tweak *Tweak) string {
	if tweak != nil && tweak.Category != "" {
		return tweak.Category
	}
	return "Other"
}

func (m *model) buildRows() {
	m.rows = m.rows[:0]
	if m.mod == nil {
		return
	}
	categorized := moduleHasTweakCategories(m.mod)
	lastCategory := ""
	for _, t := range m.mod.Tweaks {
		if categorized {
			category := tweakDisplayCategory(t)
			if category != lastCategory {
				m.rows = append(m.rows, row{kind: rowSep, label: category})
				lastCategory = category
			}
		}
		m.rows = append(m.rows, row{kind: rowTweak, tweak: t})
	}
	if len(m.mod.Extras) > 0 {
		m.rows = append(m.rows, row{kind: rowSep, label: "Actions"})
		for i := range m.mod.Extras {
			m.rows = append(m.rows, row{kind: rowExtra, extra: &m.mod.Extras[i]})
		}
	}
}

func (m *model) selectable(i int) bool {
	return i >= 0 && i < len(m.rows) && m.rows[i].kind != rowSep
}

func (m *model) ensureSelectable() {
	if len(m.rows) == 0 {
		m.cursor = 0
		return
	}
	if m.cursor >= len(m.rows) {
		m.cursor = len(m.rows) - 1
	}
	if m.cursor < 0 {
		m.cursor = 0
	}
	for i := 0; i < len(m.rows) && !m.selectable(m.cursor); i++ {
		m.cursor = (m.cursor + 1) % len(m.rows)
	}
}

func (m *model) move(delta int) {
	n := len(m.rows)
	if m.scr == scrMain {
		n = len(m.suite.Modules)
		if n > 0 {
			m.modCursor = ((m.modCursor+delta)%n + n) % n
			m.focusMarquee = 0
			m.keepCursorVisible()
		}
		return
	}
	if n == 0 {
		return
	}
	i := m.cursor
	for {
		i = ((i+delta)%n + n) % n
		if m.selectable(i) || i == m.cursor {
			break
		}
	}
	m.cursor = i
	m.focusMarquee = 0
	m.keepCursorVisible()
}

func (m *model) keepCursorVisible() {
	if m.listH < 1 {
		return
	}
	cursor, offset := m.cursor, &m.rowOffset
	if m.scr == scrMain {
		cursor, offset = m.modCursor, &m.modOffset
	}
	if cursor < *offset {
		*offset = cursor
	}
	if cursor >= *offset+m.listH {
		*offset = cursor - m.listH + 1
	}
	if *offset < 0 {
		*offset = 0
	}
}

func (m *model) nthSelectable(n int) int {
	seen := 0
	for i := range m.rows {
		if !m.selectable(i) {
			continue
		}
		seen++
		if seen == n {
			return i
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// Staging
// ---------------------------------------------------------------------------

func (m *model) toggle(t *Tweak) {
	if !t.Toggleable {
		m.note = "not applicable on this system"
		return
	}
	if t.Group != "" {
		if t.Staged != "" {
			t.Staged = ""
			return
		}
		if t.Status == "on" {
			m.note = "this policy is already active"
			return
		}
		for _, peer := range m.mod.Tweaks {
			if peer.Group == t.Group {
				peer.Staged = ""
			}
		}
		if t.Status == "drifted" {
			t.Staged = "off"
		} else {
			t.Staged = "on"
		}
		return
	}
	switch {
	case t.Staged != "":
		t.Staged = ""
	case t.Status == "off":
		t.Staged = "on"
	default:
		t.Staged = "off"
	}
}

func (m *model) stageAll(want string) {
	for _, t := range m.mod.Tweaks {
		if !t.Toggleable || t.Group != "" {
			continue
		}
		effective := "on"
		if t.Status == "off" {
			effective = "off"
		}
		if effective == want {
			t.Staged = ""
		} else {
			t.Staged = want
		}
	}
}

func (m *model) discardStaged() {
	for _, t := range m.mod.Tweaks {
		t.Staged = ""
	}
}

func (m *model) saveStaged() {
	m.keepStaged = map[string]stagedState{}
	if m.mod == nil {
		return
	}
	for _, t := range m.mod.Tweaks {
		if t.Staged != "" {
			m.keepStaged[t.ID] = stagedState{target: t.Staged, status: t.Status}
		}
	}
}

func (m *model) buildConfirm() {
	m.confirmOps = m.confirmOps[:0]
	lines := []string{"The following will change:"}
	anyOn := false
	for _, t := range m.mod.Tweaks {
		if t.Staged == "on" {
			anyOn = true
		}
	}
	if anyOn && m.mod.U2FUnenrolled() {
		lines = append(lines, sBold.Render("• Enroll the connected authenticator first")+
			" (required; approve twice on the key)")
	}
	for _, t := range m.mod.Tweaks {
		if t.Staged == "" {
			continue
		}
		m.confirmOps = append(m.confirmOps,
			fmt.Sprintf("%s\t%s\t%s", m.mod.Name, t.ID, t.Staged))
		bullet := sAccent.Render("•")
		annotation := ""
		switch t.Status {
		case "drifted":
			bullet = sBad.Render("•")
			annotation = sBad.Render("  (file was edited after apply — those edits will be overwritten)")
		case "unmanaged":
			bullet = sWarn.Render("•")
			annotation = sWarn.Render("  (externally applied; the known block is stripped safely)")
		}
		change := "turn " + t.Staged
		if t.Group != "" {
			if t.Staged == "on" {
				change = "select preset"
			} else {
				change = "restore defaults"
			}
		}
		lines = append(lines, fmt.Sprintf("%s %s: %s%s",
			bullet, strings.TrimRight(t.Title, " "), sBold.Render(change), annotation))
	}
	lines = append(lines, "")
	if m.suite.Snapshots {
		lines = append(lines, sSubtle.Render("A snapper pre/post snapshot pair will wrap these changes."))
	} else {
		lines = append(lines, sSubtle.Render("Snapshots: snapper not configured; skipping."))
	}
	m.confirmLines = lines
	m.layoutConfirm(true)
}

// ---------------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------------

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		m.help.Width = msg.Width
		m.authInput.Width = minInt(maxInt(msg.Width-24, 16), 48)
		m.configInput.Width = minInt(maxInt(msg.Width-24, 16), 48)
		m.hover = -1
		m.hoverBtn = -1
		m.docHover = -1
		m.modalTabHover = -1
		m.focusMarquee = 0
		m.hoverMarquee = 0
		m.buttons = nil
		m.docTabs = nil
		m.modalTabHits = nil
		if m.modal && !m.modalRunning {
			m.modalLayout()
		}
		if m.scr == scrConfirm {
			m.layoutConfirm(false)
		}
		if m.scr == scrDocuments {
			m.layoutDocument(false)
		}
		return m, nil

	case spinner.TickMsg:
		if !m.loading && !m.modalRunning && !m.authChecking {
			return m, nil
		}
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd

	case marqueeTickMsg:
		m.focusMarquee++
		m.hoverMarquee++
		return m, marqueeTick()

	case dumpMsg:
		return m.onDump(msg)

	case authMsg:
		return m.onAuth(msg)

	case authStartedMsg:
		return m.onAuthStarted(msg)

	case authEventMsg:
		return m.onAuthEvent(msg)

	case authInputMsg:
		if msg.session != m.authSession {
			return m, nil
		}
		if msg.err != nil {
			if m.authReplies > 0 {
				m.authReplies--
			}
			m.authError = "Could not send the authentication response: " + msg.err.Error()
			m.authInput.Focus()
			return m, textinput.Blink
		}
		return m, nil

	case authRefreshTickMsg:
		if !m.authReady {
			return m, nil
		}
		return m, refreshBackendAuthorization()

	case authRefreshMsg:
		if msg.err != nil {
			m.authReady = false
			return m, nil
		}
		return m, scheduleAuthRefresh()

	case captureStartedMsg:
		if !m.modal || !m.modalRunning {
			msg.session.cancel()
			return m, nil
		}
		m.captureSession = msg.session
		return m, waitCaptureEvent(msg.session, msg.events)

	case captureEventMsg:
		return m.onCaptureEvent(msg)

	case tea.KeyMsg:
		if m.configPrompt {
			return m.onConfigKey(msg)
		}
		if m.authPrompt {
			return m.onAuthKey(msg)
		}
		if m.showHelp {
			if key.Matches(msg, m.keys.Quit) {
				return m, tea.Quit
			}
			if key.Matches(msg, m.keys.Help, m.keys.Back) {
				m.showHelp = false
			}
			return m, nil
		}
		if key.Matches(msg, m.keys.Help) {
			m.showHelp = true
			return m, nil
		}
		if m.discardConfirm {
			return m.onDiscardConfirmKey(msg.String())
		}
		if m.snapshotConfirm {
			return m.onSnapshotConfirmKey(msg.String())
		}
		if m.modal {
			return m.onModalKey(msg)
		}
		return m.onKey(msg.String())

	case tea.MouseMsg:
		if m.configPrompt {
			return m.onConfigMouse(msg)
		}
		if m.authPrompt {
			return m.onAuthMouse(msg)
		}
		if m.showHelp {
			if msg.Button == tea.MouseButtonLeft && msg.Action == tea.MouseActionPress {
				m.showHelp = false
			}
			return m, nil
		}
		if m.modal {
			return m.onModalMouse(msg)
		}
		if m.discardConfirm {
			return m.onDiscardConfirmMouse(msg)
		}
		if m.snapshotConfirm {
			return m.onSnapshotConfirmMouse(msg)
		}
		return m.onMouse(msg)
	}
	return m, nil
}

// ---------------------------------------------------------------------------
// Output modal (capture-mode actions)
// ---------------------------------------------------------------------------

// modalLayout wraps the captured output to the modal width and sizes the
// viewport to the content (capped to the screen).
func (m *model) modalLayout() {
	w := minInt(m.w-10, 100)
	if w < 24 {
		w = maxInt(m.w-4, 10)
	}
	content := m.modalContent
	if len(m.modalTabs) > 0 && m.modalTab >= 0 && m.modalTab < len(m.modalTabs) {
		content = m.modalTabs[m.modalTab].content
	}
	wrapped := lipgloss.NewStyle().Width(w).Render(content)
	m.vp.Width = w
	tabRows := 0
	if len(m.modalTabs) > 0 {
		tabRows = outputTabRowCount(m.modalTabs, w) + 1
	}
	available := maxInt(m.h-9-tabRows, 4)
	if m.h < 14 {
		available = m.h - 4 - tabRows
		if m.modalRunning {
			available -= 2
		}
		available = maxInt(available, 1)
	}
	m.vp.Height = minInt(available, maxInt(lipgloss.Height(wrapped), 1))
	m.vp.SetContent(wrapped)
}

func (m *model) closeModal() {
	m.captureSession.cancel()
	m.captureSession = nil
	m.modal = false
	m.modalRunning = false
	m.modalContent = ""
	m.modalRaw = ""
	m.modalTruncated = false
	m.modalCancelable = false
	m.modalTabbed = false
	m.modalTabs = nil
	m.modalTab = 0
	m.modalTabHover = -1
	m.modalTabHits = nil
	m.hoverBtn = -1
	m.vp.SetContent("")
	m.vp.GotoTop()
}

func (m *model) cancelRunningCapture() {
	if !m.modalRunning || !m.modalCancelable {
		return
	}
	m.captureSession.cancel()
	m.captureSession = nil
	m.pendingCapture = nil
	m.modalRunning = false
	m.captureRefresh = false
	m.modalContent = strings.TrimRight(sanitizeCapturedText(m.modalRaw), "\n")
	if m.modalContent != "" {
		m.modalContent += "\n\n"
	}
	m.modalContent += sWarn.Render("Action cancelled.")
	m.modalTabbed = false
	m.modalTabs = nil
	m.modalLayout()
}

func sanitizeCapturedText(raw string) string {
	raw = strings.ToValidUTF8(raw, "�")
	raw = ansi.Strip(raw)
	raw = strings.ReplaceAll(raw, "\r\n", "\n")
	raw = strings.ReplaceAll(raw, "\r", "\n")
	return strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' || r >= ' ' {
			return r
		}
		return -1
	}, raw)
}

func appendBoundedTail(existing, addition string, limit int) string {
	combined := existing + addition
	if len(combined) <= limit {
		return combined
	}
	return combined[len(combined)-limit:]
}

func (m *model) layoutConfirm(reset bool) {
	if m.w < 1 || m.h < 1 {
		return
	}
	panelW := minInt(maxInt(m.w-4, 20), 104)
	contentW := maxInt(panelW-6, 1)
	contentH := maxInt(m.h-8, 1)
	if m.h < 14 {
		contentW = maxInt(m.w-4, 1)
		contentH = maxInt(m.h-4, 1)
	}
	wrapped := ansi.Wordwrap(strings.Join(m.confirmLines, "\n"), contentW, "")
	changed := m.confirmVP.Width != contentW
	m.confirmVP.Width = contentW
	m.confirmVP.Height = contentH
	if changed || reset {
		m.confirmVP.SetContent(wrapped)
	}
	if reset {
		m.confirmVP.GotoTop()
	}
}

func (m *model) onCaptureEvent(msg captureEventMsg) (tea.Model, tea.Cmd) {
	if msg.session == nil || msg.session != m.captureSession {
		return m, nil
	}
	if msg.event.text != "" {
		remaining := maxCapturedOutput - len(m.modalRaw)
		if remaining > 0 {
			if len(msg.event.text) > remaining {
				m.modalRaw += msg.event.text[:remaining]
				m.modalTruncated = true
			} else {
				m.modalRaw += msg.event.text
			}
		} else {
			m.modalTruncated = true
		}
		m.modalContent = sanitizeCapturedText(m.modalRaw)
		m.modalLayout()
		m.vp.GotoBottom()
	}
	if !msg.event.done {
		return m, waitCaptureEvent(msg.session, msg.events)
	}

	m.captureSession = nil
	m.modalRunning = false
	m.modalContent = strings.TrimRight(m.modalContent, "\n")
	if m.modalTruncated {
		m.modalContent += "\n\n" +
			sWarn.Render("Output was truncated after 1 MiB.")
	}
	if msg.event.err != nil {
		if m.modalContent != "" {
			m.modalContent += "\n\n"
		}
		m.modalContent += sBad.Render("The action exited with an error.")
	}
	if m.modalContent == "" {
		m.modalContent = sSubtle.Render("(no output)")
	}
	if m.modalTabbed {
		m.modalTabs = parseOutputTabs(m.modalContent)
		m.modalTab = 0
		m.modalTabHover = -1
	}
	m.modalLayout()
	if m.captureRefresh {
		m.captureRefresh = false
		return m, loadDump
	}
	return m, nil
}

func (m *model) onAuth(msg authMsg) (tea.Model, tea.Cmd) {
	if msg.err != nil {
		m.authChecking = true
		m.authSession = nil
		m.authOutput = ""
		m.authPrompts = 0
		m.authReplies = 0
		m.authError = ""
		m.authInput.SetValue("")
		m.authInput.Blur()
		return m, tea.Batch(m.spin.Tick, startInteractiveAuthentication())
	}
	return m.finishAuthorization()
}

func (m *model) onAuthStarted(msg authStartedMsg) (tea.Model, tea.Cmd) {
	if !m.authPrompt {
		msg.session.cancel()
		return m, nil
	}
	if msg.err != nil {
		m.authChecking = false
		m.authSession = nil
		m.authError = "Could not start the system authentication flow: " + msg.err.Error()
		return m, nil
	}
	if msg.session == nil {
		return m.finishAuthorization()
	}
	m.authSession = msg.session
	m.authChecking = true
	m.authError = ""
	m.authOutput = ""
	m.authPrompts = 0
	m.authReplies = 0
	m.authInput.SetValue("")
	m.authInput.Blur()
	return m, waitAuthEvent(msg.session, msg.events)
}

func (m *model) onAuthEvent(msg authEventMsg) (tea.Model, tea.Cmd) {
	if msg.session == nil || msg.session != m.authSession {
		return m, nil
	}
	neededBefore := m.authNeedsReply()
	if msg.event.text != "" {
		m.authOutput = appendBoundedTail(m.authOutput, msg.event.text, maxAuthTranscript)
		m.authPrompts = strings.Count(m.authOutput, sudoAuthInputMarker)
	}
	if !msg.event.done {
		if m.authNeedsReply() {
			m.authInput.Focus()
		} else {
			m.authInput.Blur()
		}
		next := waitAuthEvent(msg.session, msg.events)
		if !neededBefore && m.authNeedsReply() {
			return m, tea.Batch(next, textinput.Blink)
		}
		return m, next
	}

	m.authSession = nil
	m.authChecking = false
	m.authInput.SetValue("")
	m.authInput.Blur()
	if msg.event.err != nil {
		m.authError = "System authentication did not succeed. Try again or cancel."
		return m, nil
	}
	return m.finishAuthorization()
}

func (m *model) authNeedsReply() bool {
	return m.authSession != nil && m.authPrompts > m.authReplies
}

func (m *model) finishAuthorization() (tea.Model, tea.Cmd) {
	startRefresh := !m.authReady
	m.authReady = true
	m.authSession = nil
	m.authOutput = ""
	m.authPrompts = 0
	m.authReplies = 0
	if m.authStartup {
		m.authStartup = false
		m.authPrompt = false
		m.authChecking = false
		m.authError = ""
		m.authInput.SetValue("")
		m.authInput.Blur()
		m.note = "administrator access ready"
		if startRefresh {
			return m, scheduleAuthRefresh()
		}
		return m, nil
	}
	model, cmd := m.startPendingCapture()
	if startRefresh {
		return model, tea.Batch(cmd, scheduleAuthRefresh())
	}
	return model, cmd
}

func (m *model) requestStartupAuthorization() (tea.Model, tea.Cmd) {
	if os.Getenv(noStartupAuthEnv) == "1" || !backendNeedsPrivilege() {
		return m, nil
	}
	m.authStartup = true
	m.authPrompt = true
	m.authChecking = true
	m.authError = ""
	m.authOutput = ""
	m.authPrompts = 0
	m.authReplies = 0
	m.authInput.SetValue("")
	m.authInput.Blur()
	return m, tea.Batch(m.spin.Tick, probeBackendAuthorization())
}

func (m *model) startPendingCapture() (tea.Model, tea.Cmd) {
	if m.pendingCapture == nil {
		return m, nil
	}
	request := *m.pendingCapture
	m.pendingCapture = nil
	m.authPrompt = false
	m.authChecking = false
	m.authError = ""
	m.authSession = nil
	m.authOutput = ""
	m.authPrompts = 0
	m.authReplies = 0
	m.authInput.SetValue("")
	m.authInput.Blur()
	m.modalRunning = true
	m.modalContent = ""
	m.modalRaw = ""
	m.modalTruncated = false
	m.modalCancelable = request.cancelable
	m.modalTabbed = request.tabbed
	m.modalTabs = nil
	m.modalTab = 0
	m.modalTabHover = -1
	m.captureRefresh = request.refresh
	return m, tea.Batch(m.spin.Tick, tea.EnableMouseAllMotion, captureBackend(request))
}

func (m *model) requestCapture(title string, args ...string) (tea.Model, tea.Cmd) {
	return m.requestBackend(captureRequest{
		title: title, args: args, privileged: true,
	})
}

func (m *model) requestBackend(request captureRequest) (tea.Model, tea.Cmd) {
	m.modal = true
	m.modalTitle = request.title
	m.modalRunning = false
	m.modalContent = ""
	m.modalRaw = ""
	m.modalTruncated = false
	m.modalCancelable = request.cancelable
	m.modalTabbed = request.tabbed
	m.modalTabs = nil
	m.modalTab = 0
	m.modalTabHover = -1
	m.pendingCapture = &request
	m.hoverBtn = -1
	if request.prompt != nil {
		spec := request.prompt
		m.configPrompt = true
		m.configError = ""
		m.configSpec = spec
		m.configInput.Prompt = spec.inputPrompt
		m.configInput.Placeholder = spec.placeholder
		m.configInput.CharLimit = spec.charLimit
		m.configInput.SetValue(spec.initial)
		m.configInput.Focus()
		return m, textinput.Blink
	}
	return m.authorizePending()
}

func (m *model) authorizePending() (tea.Model, tea.Cmd) {
	if m.pendingCapture == nil {
		return m, nil
	}
	request := m.pendingCapture
	if !request.privileged || !backendNeedsPrivilege() {
		return m.startPendingCapture()
	}
	m.authPrompt = true
	m.authChecking = true
	m.authError = ""
	m.authOutput = ""
	m.authPrompts = 0
	m.authReplies = 0
	m.authInput.SetValue("")
	m.authInput.Blur()
	return m, tea.Batch(m.spin.Tick, probeBackendAuthorization())
}

func (m *model) cancelPendingAction() {
	startup := m.authStartup
	m.authSession.cancel()
	m.authSession = nil
	m.authStartup = false
	m.pendingCapture = nil
	m.configPrompt = false
	m.configError = ""
	m.configSpec = nil
	m.configInput.SetValue("")
	m.authPrompt = false
	m.authChecking = false
	m.authError = ""
	m.authOutput = ""
	m.authPrompts = 0
	m.authReplies = 0
	m.authInput.SetValue("")
	m.authInput.Blur()
	m.closeModal()
	if startup {
		m.note = "continuing without startup authorization"
	}
}

func (m *model) submitAuthentication() (tea.Model, tea.Cmd) {
	if m.authSession == nil {
		if m.authChecking {
			return m, nil
		}
		m.authChecking = true
		m.authError = ""
		m.authOutput = ""
		m.authPrompts = 0
		m.authReplies = 0
		m.authInput.SetValue("")
		m.authInput.Blur()
		return m, tea.Batch(m.spin.Tick, startInteractiveAuthentication())
	}
	if !m.authNeedsReply() || m.authInput.Value() == "" {
		return m, nil
	}
	response := m.authInput.Value()
	m.authInput.SetValue("")
	m.authReplies++
	m.authError = ""
	return m, sendAuthenticationInput(m.authSession, response)
}

func (m *model) onAuthKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c":
		m.authSession.cancel()
		return m, tea.Quit
	case "esc":
		m.cancelPendingAction()
		return m, nil
	case "enter":
		return m.submitAuthentication()
	}
	if !m.authNeedsReply() {
		return m, nil
	}
	var cmd tea.Cmd
	m.authInput, cmd = m.authInput.Update(msg)
	return m, cmd
}

func (m *model) onAuthMouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	if msg.Action == tea.MouseActionMotion {
		m.updateButtonHover(msg.X, msg.Y)
		return m, nil
	}
	if msg.Button == tea.MouseButtonLeft && msg.Action == tea.MouseActionPress {
		if b := m.buttonAt(msg.X, msg.Y); b != nil && !b.dim {
			if b.action == "auth-submit" {
				return m.submitAuthentication()
			}
			m.cancelPendingAction()
		}
	}
	return m, nil
}

func (m *model) submitConfiguration() (tea.Model, tea.Cmd) {
	spec := m.configSpec
	if spec == nil || m.pendingCapture == nil {
		m.cancelPendingAction()
		return m, nil
	}
	value, problem := spec.validate(m.configInput.Value())
	if problem != "" {
		m.configError = problem
		return m, nil
	}
	m.pendingCapture.env = append(m.pendingCapture.env, spec.envVar+"="+value)
	m.pendingCapture.prompt = nil
	m.configPrompt = false
	m.configError = ""
	m.configSpec = nil
	m.configInput.SetValue("")
	m.configInput.Blur()
	return m.authorizePending()
}

func (m *model) onConfigKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit
	case "esc":
		m.cancelPendingAction()
		return m, nil
	case "enter":
		return m.submitConfiguration()
	}
	var cmd tea.Cmd
	m.configInput, cmd = m.configInput.Update(msg)
	return m, cmd
}

func (m *model) onConfigMouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	if msg.Action == tea.MouseActionMotion {
		m.updateButtonHover(msg.X, msg.Y)
		return m, nil
	}
	if msg.Button == tea.MouseButtonLeft && msg.Action == tea.MouseActionPress {
		if b := m.buttonAt(msg.X, msg.Y); b != nil && !b.dim {
			if b.action == "config-submit" {
				return m.submitConfiguration()
			}
			m.cancelPendingAction()
		}
	}
	return m, nil
}

func (m *model) onSnapshotConfirmKey(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "enter", "y":
		m.snapshotConfirm = false
		m.hoverBtn = -1
		return m.requestCapture("Create snapshot", "snapshot", "create")
	case "esc", "n", "q":
		m.snapshotConfirm = false
		m.hoverBtn = -1
		return m, nil
	case "ctrl+c":
		return m, tea.Quit
	}
	return m, nil
}

func (m *model) onSnapshotConfirmMouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	if msg.Action == tea.MouseActionMotion {
		m.updateButtonHover(msg.X, msg.Y)
		return m, nil
	}
	if msg.Button == tea.MouseButtonLeft && msg.Action == tea.MouseActionPress {
		if b := m.buttonAt(msg.X, msg.Y); b != nil && !b.dim {
			return m.onSnapshotConfirmKey(b.action)
		}
	}
	return m, nil
}

func (m *model) onDiscardConfirmKey(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "enter", "y":
		m.discardStaged()
		m.discardConfirm = false
		m.hoverBtn = -1
		if m.discardGoBack {
			m.discardGoBack = false
			return m.goBack()
		}
		m.note = "staged changes discarded"
	case "esc", "n", "q":
		m.discardConfirm = false
		m.discardGoBack = false
		m.hoverBtn = -1
	case "ctrl+c":
		return m, tea.Quit
	}
	return m, nil
}

func (m *model) onDiscardConfirmMouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	if msg.Action == tea.MouseActionMotion {
		m.updateButtonHover(msg.X, msg.Y)
		return m, nil
	}
	if msg.Button == tea.MouseButtonLeft && msg.Action == tea.MouseActionPress {
		if b := m.buttonAt(msg.X, msg.Y); b != nil && !b.dim {
			return m.onDiscardConfirmKey(b.action)
		}
	}
	return m, nil
}

func (m *model) onModalKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c":
		if m.modalRunning && !m.modalCancelable {
			return m, nil
		}
		m.captureSession.cancel()
		return m, tea.Quit
	case "esc", "q", "enter":
		if m.modalRunning && m.modalCancelable &&
			(msg.String() == "esc" || msg.String() == "q") {
			m.cancelRunningCapture()
		} else if !m.modalRunning {
			m.closeModal()
		}
		return m, nil
	case "left", "h", "shift+tab", "[":
		if !m.modalRunning && len(m.modalTabs) > 0 {
			m.selectModalTab(m.modalTab - 1)
			return m, nil
		}
	case "right", "l", "tab", "]":
		if !m.modalRunning && len(m.modalTabs) > 0 {
			m.selectModalTab(m.modalTab + 1)
			return m, nil
		}
	case "1", "2", "3", "4", "5", "6", "7", "8", "9":
		if !m.modalRunning && len(m.modalTabs) > 0 {
			m.selectModalTab(int(msg.String()[0] - '1'))
			return m, nil
		}
	}
	if m.modalRunning {
		return m, nil
	}
	var cmd tea.Cmd
	m.vp, cmd = m.vp.Update(msg)
	return m, cmd
}

func (m *model) openSelectedDetails() {
	if !m.selectable(m.cursor) {
		return
	}
	r := m.rows[m.cursor]
	m.modal = true
	m.modalRunning = false
	m.modalCancelable = false
	m.modalTabbed = false
	m.modalTabs = nil
	m.modalRaw = ""
	m.modalTruncated = false
	if r.kind == rowTweak {
		m.modalTitle = strings.TrimSpace(r.tweak.Title)
		m.modalContent = tweakDetails(r.tweak)
	} else {
		m.modalTitle = strings.TrimSpace(r.extra.Label)
		m.modalContent = extraDetails(r.extra)
	}
	m.modalLayout()
	m.vp.GotoTop()
}

func (m *model) onModalMouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	if msg.Action == tea.MouseActionMotion {
		m.updateButtonHover(msg.X, msg.Y)
		m.modalTabHover = m.modalTabAt(msg.X, msg.Y)
		return m, nil
	}
	if msg.Button == tea.MouseButtonLeft && msg.Action == tea.MouseActionPress {
		if b := m.buttonAt(msg.X, msg.Y); b != nil && !b.dim {
			if m.modalRunning {
				m.cancelRunningCapture()
			} else {
				m.closeModal()
			}
			return m, nil
		}
		if i := m.modalTabAt(msg.X, msg.Y); i >= 0 && !m.modalRunning {
			m.selectModalTab(i)
		}
		return m, nil
	}
	if m.modalRunning {
		return m, nil
	}
	var cmd tea.Cmd
	m.vp, cmd = m.vp.Update(msg)
	return m, cmd
}

func (m *model) selectModalTab(index int) {
	if len(m.modalTabs) == 0 {
		return
	}
	index = ((index % len(m.modalTabs)) + len(m.modalTabs)) % len(m.modalTabs)
	if index == m.modalTab {
		return
	}
	m.modalTab = index
	m.modalTabHover = -1
	m.modalLayout()
	m.vp.GotoTop()
}

func (m *model) modalTabAt(x, y int) int {
	for i, hit := range m.modalTabHits {
		if y == hit.y && x >= hit.x0 && x <= hit.x1 {
			return i
		}
	}
	return -1
}

func (m *model) onDump(msg dumpMsg) (tea.Model, tea.Cmd) {
	initial := m.suite == nil
	m.loading = false
	if msg.err != nil {
		if m.suite == nil {
			m.err = msg.err
			m.scr = scrLoading
		} else {
			m.note = msg.err.Error()
		}
		return m, nil
	}
	m.err = nil
	m.suite = msg.suite
	if m.modCursor >= len(m.suite.Modules) {
		m.modCursor = len(m.suite.Modules) - 1
	}
	if m.mod != nil {
		var found *Module
		for _, mod := range m.suite.Modules {
			if mod.Name == m.mod.Name {
				found = mod
			}
		}
		if found == nil {
			m.mod = nil
			m.scr = scrMain
		} else {
			m.mod = found
			stageChanged := false
			for _, t := range found.Tweaks {
				if saved, ok := m.keepStaged[t.ID]; ok && t.Toggleable {
					if t.Status == saved.status {
						t.Staged = saved.target
					} else {
						stageChanged = true
					}
				}
			}
			if stageChanged {
				m.note = "system state changed during refresh; affected staged changes were cleared"
			}
			m.buildRows()
			m.ensureSelectable()
			m.hover = -1
			m.focusMarquee = 0
			m.hoverMarquee = 0
		}
	}
	m.keepStaged = nil
	if m.scr == scrLoading {
		m.scr = scrMain
	}
	if initial {
		return m.requestStartupAuthorization()
	}
	return m, nil
}

func (m *model) refresh(preserveStaged bool) (tea.Model, tea.Cmd) {
	if preserveStaged {
		m.saveStaged()
	} else {
		m.keepStaged = nil
	}
	m.loading = true
	return m, tea.Batch(m.spin.Tick, loadDump)
}

// activate runs the selected row: stage a tweak or launch an action.
func (m *model) activate(i int) (tea.Model, tea.Cmd) {
	if !m.selectable(i) {
		return m, nil
	}
	if m.cursor != i {
		m.focusMarquee = 0
	}
	m.cursor = i
	r := m.rows[i]
	switch r.kind {
	case rowTweak:
		m.toggle(r.tweak)
	case rowExtra:
		if r.extra.Disabled {
			m.note = "not available right now — see the description"
			return m, nil
		}
		var prompt *promptSpec
		if r.extra.Prompt != "" {
			prompt = extraPrompt(r.extra.Label, r.extra.Prompt)
		}
		return m.requestBackend(captureRequest{
			title: r.extra.Label, args: []string{"extra", r.extra.Module, r.extra.ID},
			privileged: r.extra.NeedsRoot, refresh: !r.extra.Capture, tabbed: r.extra.Tabbed,
			cancelable: r.extra.Capture, prompt: prompt,
		})
	}
	return m, nil
}

func (m *model) goBack() (tea.Model, tea.Cmd) {
	if m.mod != nil && m.mod.StagedCount() > 0 {
		m.discardConfirm = true
		m.discardGoBack = true
		m.hoverBtn = -1
		return m, nil
	}
	if m.mod != nil {
		m.discardStaged()
	}
	m.mod = nil
	m.rows = nil
	m.scr = scrMain
	m.hover = -1
	m.hoverBtn = -1
	m.rowOffset = 0
	return m, nil
}

func (m *model) onKey(k string) (tea.Model, tea.Cmd) {
	if k == "ctrl+c" {
		return m, tea.Quit
	}
	if m.suite == nil {
		switch k {
		case "q", "esc":
			return m, tea.Quit
		case "r":
			if m.err != nil {
				m.err = nil
				m.loading = true
				return m, tea.Batch(m.spin.Tick, loadDump)
			}
		}
		return m, nil
	}

	// Any handled key clears the transient note; handlers may set a new one.
	note := m.note
	m.note = ""
	switch m.scr {
	case scrDocuments:
		switch k {
		case "up", "k", "shift+tab", "[":
			m.selectDocument(m.docTab - 1)
		case "down", "j", "tab", "]":
			m.selectDocument(m.docTab + 1)
		case "left", "h":
			m.selectDocumentCategory(-1)
		case "right", "l":
			m.selectDocumentCategory(1)
		case "pgup":
			m.docVP.HalfViewUp()
		case "pgdown", " ":
			m.docVP.HalfViewDown()
		case "home", "g":
			m.docVP.GotoTop()
		case "end", "G":
			m.docVP.GotoBottom()
		case "esc", "q", "backspace":
			m.scr = scrMain
			m.docHover = -1
			m.hoverBtn = -1
		}
		return m, nil

	case scrConfirm:
		switch k {
		case "up", "k":
			m.confirmVP.LineUp(1)
		case "down", "j":
			m.confirmVP.LineDown(1)
		case "pgup":
			m.confirmVP.HalfViewUp()
		case "pgdown", " ":
			m.confirmVP.HalfViewDown()
		case "home", "g":
			m.confirmVP.GotoTop()
		case "end", "G":
			m.confirmVP.GotoBottom()
		case "enter", "y":
			m.scr = scrModule
			input := strings.Join(m.confirmOps, "\n") + "\n"
			var prompt *promptSpec
			for _, op := range m.confirmOps {
				fields := strings.Split(op, "\t")
				if len(fields) == 3 && fields[1] == "wifi-regdom" && fields[2] == "on" {
					prompt = regdomPrompt()
				}
			}
			m.keepStaged = nil
			return m.requestBackend(captureRequest{
				title: "Apply staged changes", args: []string{"batch"},
				input: input, privileged: true, refresh: true, prompt: prompt,
			})
		case "esc", "n", "q", "left", "h":
			m.scr = scrModule
			return m, nil
		}
		return m, nil

	case scrMain:
		switch k {
		case "up", "k", "shift+tab":
			m.move(-1)
		case "down", "j", "tab":
			m.move(1)
		case "home", "pgup":
			m.modCursor = 0
			m.focusMarquee = 0
			m.keepCursorVisible()
		case "end", "pgdown":
			m.modCursor = len(m.suite.Modules) - 1
			m.focusMarquee = 0
			m.keepCursorVisible()
		case "enter", " ", "right", "l":
			return m.openModule(m.modCursor)
		case "1", "2", "3", "4", "5", "6", "7", "8", "9":
			i := int(k[0] - '1')
			if i < len(m.suite.Modules) {
				return m.openModule(i)
			}
		case "r":
			return m.refresh(false)
		case "s":
			if !m.suite.Snapshots {
				m.note = "snapper is not configured for the root filesystem"
				return m, nil
			}
			m.snapshotConfirm = true
			m.hoverBtn = -1
			return m, nil
		case "i":
			m.openDocuments()
			return m, nil
		case "u":
			if !portableInstall() {
				m.note = "updates for this installation are managed by pacman or git"
				return m, nil
			}
			// The update swaps the version behind the running process, so
			// keep it captured without a refresh and let a restart pick the
			// new version up.
			return m.requestBackend(captureRequest{
				title: "Update Tweaks for CachyOS", args: []string{"update"},
				cancelable: true,
			})
		case "q", "esc":
			return m, tea.Quit
		default:
			m.note = note
		}
		return m, nil

	case scrModule:
		switch k {
		case "up", "k", "shift+tab":
			m.move(-1)
		case "down", "j", "tab":
			m.move(1)
		case "home", "pgup":
			m.cursor = 0
			m.ensureSelectable()
			m.focusMarquee = 0
			m.keepCursorVisible()
		case "end", "pgdown":
			m.cursor = len(m.rows) - 1
			for m.cursor > 0 && !m.selectable(m.cursor) {
				m.cursor--
			}
			m.focusMarquee = 0
			m.keepCursorVisible()
		case "enter", " ":
			return m.activate(m.cursor)
		case "right", "l":
			m.openSelectedDetails()
			return m, nil
		case "1", "2", "3", "4", "5", "6", "7", "8", "9":
			if i := m.nthSelectable(int(k[0] - '0')); i >= 0 {
				return m.activate(i)
			}
		case "a":
			if m.mod.StagedCount() == 0 {
				m.note = "nothing staged yet — toggle items first"
				return m, nil
			}
			m.buildConfirm()
			m.scr = scrConfirm
		case "d":
			if m.mod.StagedCount() == 0 {
				m.note = "nothing staged"
				return m, nil
			}
			m.discardConfirm = true
			m.discardGoBack = false
			m.hoverBtn = -1
		case "+", "=":
			m.stageAll("on")
		case "-", "_":
			m.stageAll("off")
		case "r":
			return m.refresh(true)
		case "esc", "q", "left", "h", "backspace":
			return m.goBack()
		default:
			m.note = note
		}
		return m, nil
	}
	return m, nil
}

func (m *model) openDocuments() {
	m.documents = loadDocuments(m.suite)
	m.docTab = 0
	m.docHover = -1
	m.docNavOffset = 0
	m.hoverBtn = -1
	m.docRenderW = 0
	m.scr = scrDocuments
	m.layoutDocument(true)
}

func (m *model) selectDocumentCategory(direction int) {
	if len(m.documents) == 0 || direction == 0 {
		return
	}
	current := m.documents[m.docTab].category
	index := m.docTab
	for range len(m.documents) {
		index = (index + direction + len(m.documents)) % len(m.documents)
		if m.documents[index].category != current {
			if direction < 0 {
				targetCategory := m.documents[index].category
				for index > 0 && m.documents[index-1].category == targetCategory {
					index--
				}
			}
			m.selectDocument(index)
			return
		}
	}
}

func (m *model) selectDocument(index int) {
	if len(m.documents) == 0 {
		return
	}
	index = ((index % len(m.documents)) + len(m.documents)) % len(m.documents)
	if index == m.docTab {
		return
	}
	m.docTab = index
	m.docRenderW = 0
	m.layoutDocument(true)
}

func (m *model) layoutDocument(reset bool) {
	if len(m.documents) == 0 || m.w < 1 || m.h < 1 {
		return
	}
	frameW := m.documentFrameWidth()
	contentFrameW := frameW
	selectorRows := 1
	if m.documentSideNav() {
		contentFrameW = frameW - m.documentNavWidth() - 2
		selectorRows = 0
	}
	contentW := maxInt(contentFrameW-8, 20)
	m.docVP.Width = maxInt(contentFrameW-6, 1)
	m.docVP.Height = maxInt(m.h-6-selectorRows, 1)
	if contentW != m.docRenderW {
		reset = true
		m.docRenderW = contentW
		rendered, err := renderDocument(m.documents[m.docTab].body, contentW)
		if err != nil {
			rendered = sErr.Render("Could not render this document: " + err.Error())
		}
		m.docVP.SetContent(rendered)
	}
	if reset {
		m.docVP.GotoTop()
	}
}

func (m *model) openModule(i int) (tea.Model, tea.Cmd) {
	if i < 0 || i >= len(m.suite.Modules) {
		return m, nil
	}
	m.modCursor = i
	m.mod = m.suite.Modules[i]
	m.buildRows()
	m.cursor = 0
	m.rowOffset = 0
	m.ensureSelectable()
	m.scr = scrModule
	m.hover = -1
	m.hoverBtn = -1
	m.focusMarquee = 0
	m.hoverMarquee = 0
	return m, nil
}

// ---------------------------------------------------------------------------
// Mouse
// ---------------------------------------------------------------------------

func (m *model) rowAt(x, y int) int {
	i := y - m.listTop
	limit := len(m.rows)
	if m.scr == scrMain {
		limit = len(m.suite.Modules)
		i += m.modOffset
	} else {
		i += m.rowOffset
	}
	if i < 0 || i >= limit || x < m.listLeft || x >= m.listLeft+m.listW {
		return -1
	}
	return i
}

func (m *model) buttonAt(x, y int) *button {
	if y != m.footerY {
		return nil
	}
	for _, b := range m.buttons {
		if x >= b.x0 && x <= b.x1 {
			return b
		}
	}
	return nil
}

func (m *model) updateButtonHover(x, y int) {
	m.hoverBtn = -1
	b := m.buttonAt(x, y)
	if b == nil || b.dim {
		return
	}
	for i, candidate := range m.buttons {
		if candidate == b {
			m.hoverBtn = i
			return
		}
	}
}

func (m *model) onMouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	if m.suite == nil {
		return m, nil
	}
	if m.scr == scrDocuments {
		return m.onDocumentMouse(msg)
	}
	switch {
	case msg.Action == tea.MouseActionMotion:
		m.updateButtonHover(msg.X, msg.Y)
		if m.scr == scrConfirm {
			m.hover = -1
			return m, nil
		}
		nextHover := m.rowAt(msg.X, msg.Y)
		if nextHover != m.hover {
			m.hover = nextHover
			m.hoverMarquee = 0
		}
	case msg.Button == tea.MouseButtonWheelUp && msg.Action == tea.MouseActionPress:
		if m.scr == scrConfirm {
			m.confirmVP.LineUp(2)
		} else {
			m.move(-1)
		}
	case msg.Button == tea.MouseButtonWheelDown && msg.Action == tea.MouseActionPress:
		if m.scr == scrConfirm {
			m.confirmVP.LineDown(2)
		} else {
			m.move(1)
		}
	case msg.Button == tea.MouseButtonLeft && msg.Action == tea.MouseActionPress:
		if b := m.buttonAt(msg.X, msg.Y); b != nil {
			if b.dim {
				return m, nil
			}
			return m.onKey(b.action)
		}
		if m.scr == scrConfirm {
			return m, nil
		}
		// First click selects (highlight + description); only a click on
		// the already-selected row activates it.
		if i := m.rowAt(msg.X, msg.Y); i >= 0 {
			m.note = ""
			if m.scr == scrMain {
				if i == m.modCursor {
					return m.openModule(i)
				}
				m.modCursor = i
				m.focusMarquee = 0
				return m, nil
			}
			if i == m.cursor {
				return m.activate(i)
			}
			if m.selectable(i) {
				m.cursor = i
				m.focusMarquee = 0
			}
			return m, nil
		}
	}
	return m, nil
}

func (m *model) tabAt(x, y int) int {
	for i, tab := range m.docTabs {
		if y == tab.y && x >= tab.x0 && x <= tab.x1 {
			return i
		}
	}
	return -1
}

func (m *model) onDocumentMouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	switch {
	case msg.Action == tea.MouseActionMotion:
		m.updateButtonHover(msg.X, msg.Y)
		m.docHover = m.tabAt(msg.X, msg.Y)
	case msg.Button == tea.MouseButtonWheelUp && msg.Action == tea.MouseActionPress:
		m.docVP.LineUp(3)
	case msg.Button == tea.MouseButtonWheelDown && msg.Action == tea.MouseActionPress:
		m.docVP.LineDown(3)
	case msg.Button == tea.MouseButtonLeft && msg.Action == tea.MouseActionPress:
		if b := m.buttonAt(msg.X, msg.Y); b != nil {
			return m.onKey(b.action)
		}
		if i := m.tabAt(msg.X, msg.Y); i >= 0 {
			m.selectDocument(i)
		}
	}
	return m, nil
}
