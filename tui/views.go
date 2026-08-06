package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

const logoPad = 27

func (m *model) View() string {
	if m.w == 0 || m.h == 0 {
		return ""
	}
	if m.showHelp {
		return m.viewHelp()
	}
	if m.configPrompt {
		return m.viewConfiguration()
	}
	if m.authPrompt {
		return m.viewAuth()
	}
	switch {
	case m.suite == nil && m.err != nil:
		return m.viewError()
	case m.suite == nil:
		return m.viewSplash()
	}
	if m.snapshotConfirm {
		return m.viewSnapshotConfirm()
	}
	if m.discardConfirm {
		return m.viewDiscardConfirm()
	}
	if m.modal {
		return m.viewModal()
	}
	switch m.scr {
	case scrDocuments:
		return m.viewDocuments()
	case scrConfirm:
		return m.viewConfirm()
	case scrModule:
		return m.viewModule()
	default:
		return m.viewMain()
	}
}

func (m *model) viewConfiguration() string {
	spec := m.configSpec
	if spec == nil {
		// Defensive fallback; every prompt opener installs a spec.
		spec = &promptSpec{
			title:   "Input required",
			heading: "Provide the requested value",
		}
	}
	body := m.headerLines(spec.title)
	content := sBold.Render(spec.heading)
	if spec.detail != "" {
		content += "\n\n" + spec.detail
	}
	if spec.hint != "" {
		content += "\n" + sSubtle.Render(spec.hint)
	}
	content += "\n\n" + m.configInput.View()
	if m.configError != "" {
		content += "\n\n" + sBad.Render(m.configError)
	}
	m.buttons = []*button{
		{label: "Continue", action: "config-submit"},
		{label: "Cancel", action: "config-cancel"},
	}
	if m.h < 14 {
		compact := []string{sBold.Render(spec.heading)}
		if spec.hint != "" {
			compact = append(compact, sSubtle.Render(spec.hint))
		}
		compact = append(compact, "", m.configInput.View())
		if m.configError != "" {
			compact = append(compact, sBad.Render(m.configError))
		}
		body = append(body, compact...)
		return m.compose(body, m.renderFooter("enter continue · esc cancel"))
	}
	panelW := minInt(maxInt(m.w-12, 30), 76)
	panel := sConfirmPanel.Width(maxInt(panelW-6, 20)).Render(content)
	area := maxInt(m.h-1-len(body), 1)
	placed := lipgloss.Place(m.w, area, lipgloss.Center, lipgloss.Center, panel)
	body = append(body, splitLines(placed, "")...)
	return m.compose(body, m.renderFooter("enter continue · esc cancel"))
}

func (m *model) viewAuth() string {
	body := m.headerLines("Administrator authorization")
	panelW := minInt(maxInt(m.w-12, 30), 76)
	contentW := maxInt(panelW-6, 20)
	title := "Administrator access is required"
	if m.authStartup {
		title = "Unlock administrator actions for this session"
	}
	content := sBold.Render(title) + "\n\n" +
		"sudo is using the authentication order configured by this system.\n" +
		sSubtle.Render("Approve a security key or fingerprint prompt when offered; password remains a fallback.")

	transcript := authTranscript(m.authOutput, contentW, maxInt(minInt(m.h-12, 5), 1))
	if transcript != "" {
		content += "\n\n" + sSubtle.Render(transcript)
	}

	switch {
	case m.authSession != nil:
		content += "\n\n " + m.spin.View() + " " + sSubtle.Render("authentication in progress…")
		if m.authNeedsReply() {
			content += "\n\n" + sBold.Render("sudo is requesting a hidden response:") +
				"\n" + m.authInput.View() + "\n" +
				sSubtle.Render("Sent only to sudo on standard input; it is not stored.")
		}
		m.buttons = []*button{
			{
				label: "Send response", action: "auth-submit",
				dim: !m.authNeedsReply() || m.authInput.Value() == "",
			},
			{label: "Cancel", action: "auth-cancel"},
		}
	case m.authChecking:
		content += "\n\n " + m.spin.View() + " " + sSubtle.Render("starting system authentication…")
		m.buttons = []*button{
			{label: "Waiting", action: "auth-submit", dim: true},
			{label: "Cancel", action: "auth-cancel"},
		}
	default:
		if m.authError != "" {
			content += "\n\n" + sBad.Render(m.authError)
		}
		m.buttons = []*button{
			{label: "Try again", action: "auth-submit"},
			{label: "Cancel", action: "auth-cancel"},
		}
	}

	if m.h < 14 {
		compact := []string{sBold.Render(title)}
		if transcript != "" {
			compact = append(compact, transcript)
		}
		switch {
		case m.authNeedsReply():
			compact = append(compact,
				sBold.Render("sudo requests a hidden response:"),
				m.authInput.View(),
			)
		case m.authSession != nil:
			compact = append(compact, " "+m.spin.View()+" "+sSubtle.Render("authentication in progress…"))
		case m.authChecking:
			compact = append(compact, " "+m.spin.View()+" "+sSubtle.Render("starting system authentication…"))
		case m.authError != "":
			compact = append(compact, sBad.Render(m.authError))
		}
		body = append(body, compact...)
		cancel := "cancel"
		if m.authStartup {
			cancel = "continue without"
		}
		hint := "esc " + cancel
		if m.authNeedsReply() {
			hint = "enter send response · " + hint
		} else if !m.authChecking {
			hint = "enter try again · " + hint
		}
		return m.compose(body, m.renderFooter(hint))
	}

	panel := sConfirmPanel.Width(maxInt(panelW-6, 20)).Render(content)
	area := maxInt(m.h-1-len(body), 1)
	placed := lipgloss.Place(m.w, area, lipgloss.Center, lipgloss.Center, panel)
	body = append(body, splitLines(placed, "")...)
	cancel := "cancel"
	if m.authStartup {
		cancel = "continue without"
	}
	hint := "follow the configured sudo prompt · esc " + cancel
	if m.authNeedsReply() {
		hint = "enter send response · esc " + cancel
	} else if !m.authChecking {
		hint = "enter try again · esc " + cancel
	}
	return m.compose(body, m.renderFooter(hint))
}

func authTranscript(raw string, width, maxLines int) string {
	raw = strings.ReplaceAll(raw, sudoAuthInputMarker, "")
	// A pipe read may split the private prompt marker. Hide a trailing partial
	// marker until the next chunk completes it.
	for i := len(sudoAuthInputMarker) - 1; i > 0; i-- {
		if strings.HasSuffix(raw, sudoAuthInputMarker[:i]) {
			raw = strings.TrimSuffix(raw, sudoAuthInputMarker[:i])
			break
		}
	}
	raw = strings.ReplaceAll(raw, "\r", "")
	raw = ansi.Strip(raw)
	raw = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' || r >= ' ' {
			return r
		}
		return -1
	}, raw)
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	wrapped := strings.Split(ansi.Wordwrap(raw, maxInt(width, 1), ""), "\n")
	if len(wrapped) > maxLines {
		wrapped = wrapped[len(wrapped)-maxLines:]
	}
	return strings.Join(wrapped, "\n")
}

func (m *model) viewDocuments() string {
	m.layoutDocument(false)
	body := m.headerLines("About & documentation")
	m.docTabs = make([]tabHitbox, len(m.documents))
	for i := range m.docTabs {
		m.docTabs[i] = tabHitbox{x0: -1, x1: -1, y: -1}
	}
	frameW := m.documentFrameWidth()
	left := maxInt((m.w-frameW)/2, 0)
	if m.documentSideNav() {
		paneH := maxInt(m.h-1-len(body), 1)
		navW := m.documentNavWidth()
		docW := maxInt(frameW-navW-2, 20)
		navRows := m.documentNavigationRows()
		navH := maxInt(paneH-2, 1)
		selectedRow := 0
		for i, row := range navRows {
			if row.doc == m.docTab {
				selectedRow = i
				break
			}
		}
		if selectedRow < m.docNavOffset {
			m.docNavOffset = selectedRow
		}
		if selectedRow >= m.docNavOffset+navH {
			m.docNavOffset = selectedRow - navH + 1
		}
		m.docNavOffset = minInt(
			maxInt(m.docNavOffset, 0),
			maxInt(len(navRows)-navH, 0),
		)
		end := minInt(m.docNavOffset+navH, len(navRows))
		navLines := make([]string, 0, navH)
		for rowIndex := m.docNavOffset; rowIndex < end; rowIndex++ {
			row := navRows[rowIndex]
			if row.doc < 0 {
				navLines = append(navLines, sSection.Render(
					truncate(strings.ToUpper(row.category), navW-4),
				))
				continue
			}
			label := "  " + truncate(m.documents[row.doc].title, navW-6)
			navLines = append(navLines, m.documentItemStyle(row.doc).
				Width(maxInt(navW-4, 1)).Render(label))
			m.docTabs[row.doc] = tabHitbox{
				x0: left + 1,
				x1: left + navW - 2,
				y:  len(body) + 1 + len(navLines) - 1,
			}
		}
		nav := sPanel.Width(maxInt(navW-2, 1)).Height(navH).
			Render(strings.Join(navLines, "\n"))
		panel := sDocument.Width(maxInt(docW-2, 1)).Height(m.docVP.Height).
			Render(m.docVP.View())
		joined := lipgloss.JoinHorizontal(lipgloss.Top, nav, "  ", panel)
		body = append(body, splitLines(joined, strings.Repeat(" ", left))...)
	} else {
		current := m.documents[m.docTab]
		prev := (m.docTab - 1 + len(m.documents)) % len(m.documents)
		next := (m.docTab + 1) % len(m.documents)
		breadcrumb := truncate(current.category+" / "+current.title, maxInt(frameW-10, 1))
		prevStyle, nextStyle := sSubtle, sSubtle
		if m.docHover == prev {
			prevStyle = sHovered.Foreground(cAccent)
		}
		if m.docHover == next {
			nextStyle = sHovered.Foreground(cAccent)
		}
		selector := prevStyle.Render("‹ ") + sAccent.Render(breadcrumb) + nextStyle.Render(" ›")
		selectorW := lipgloss.Width(selector)
		selectorLeft := maxInt((m.w-selectorW)/2, 0)
		selectorY := len(body)
		m.docTabs[prev] = tabHitbox{x0: selectorLeft, x1: selectorLeft + 1, y: selectorY}
		m.docTabs[next] = tabHitbox{
			x0: selectorLeft + selectorW - 2,
			x1: selectorLeft + selectorW - 1,
			y:  selectorY,
		}
		body = append(body, strings.Repeat(" ", selectorLeft)+selector)
		panel := sDocument.Width(maxInt(frameW-2, 1)).Height(m.docVP.Height).
			Render(m.docVP.View())
		body = append(body, splitLines(panel, strings.Repeat(" ", left))...)
	}

	scroll := "all visible"
	if m.docVP.TotalLineCount() > m.docVP.Height {
		scroll = fmt.Sprintf("%d%%", int(m.docVP.ScrollPercent()*100))
	}
	filename := ""
	if m.docTab >= 0 && m.docTab < len(m.documents) {
		filename = m.documents[m.docTab].filename + " · "
	}
	m.buttons = []*button{{label: "Close", action: "esc"}}
	return m.compose(body, m.renderFooter(
		filename+scroll+" · ↑/↓ topics · ←/→ categories · pg↑/pg↓/wheel read · esc close",
	))
}

func (m *model) viewSnapshotConfirm() string {
	body := m.headerLines("Create snapshot")
	content := sBold.Render("Create a standalone Snapper snapshot now?") + "\n\n" +
		"This creates a root-filesystem restore point without changing any settings.\n" +
		sSubtle.Render("Administrator authorization is requested only after you confirm.")
	panelW := minInt(maxInt(m.w-12, 24), 78)
	m.buttons = []*button{
		{label: "Create", action: "enter"},
		{label: "Cancel", action: "esc"},
	}
	if m.h < 14 {
		body = append(body,
			sBold.Render("Create a standalone Snapper snapshot now?"),
			"",
			sSubtle.Render("No settings will be changed."),
		)
		return m.compose(body, m.renderFooter("enter create · esc cancel"))
	}
	wrapped := ansi.Wordwrap(content, maxInt(panelW-6, 12), "")
	panel := sConfirmPanel.Render(wrapped)
	area := maxInt(m.h-1-len(body), 1)
	placed := lipgloss.Place(m.w, area, lipgloss.Center, lipgloss.Center, panel)
	body = append(body, splitLines(placed, "")...)
	return m.compose(body, m.renderFooter("enter create · esc cancel"))
}

func (m *model) viewDiscardConfirm() string {
	body := m.headerLines("Discard staged changes")
	count := 0
	if m.mod != nil {
		count = m.mod.StagedCount()
	}
	content := sBold.Render(fmt.Sprintf("Discard %d staged change(s)?", count)) + "\n\n" +
		"No backend action has run. This only clears the pending selections.\n" +
		sSubtle.Render("Cancel returns with every staged choice intact.")
	m.buttons = []*button{
		{label: "Discard", action: "enter"},
		{label: "Cancel", action: "esc"},
	}
	if m.h < 14 {
		body = append(body,
			sBold.Render(fmt.Sprintf("Discard %d staged change(s)?", count)),
			"",
			sSubtle.Render("Nothing has run; cancel keeps every selection."),
		)
		return m.compose(body, m.renderFooter("enter discard · esc cancel"))
	}
	panelW := minInt(maxInt(m.w-12, 24), 78)
	wrapped := ansi.Wordwrap(content, maxInt(panelW-6, 12), "")
	panel := sConfirmPanel.Render(wrapped)
	area := maxInt(m.h-1-len(body), 1)
	placed := lipgloss.Place(m.w, area, lipgloss.Center, lipgloss.Center, panel)
	body = append(body, splitLines(placed, "")...)
	return m.compose(body, m.renderFooter("enter discard · esc cancel"))
}

// viewModal shows a capture-mode action: a spinner while it runs, then its
// output in a centered, scrollable viewport.
func (m *model) viewModal() string {
	body := m.headerLines(m.modalTitle)
	var panel, hints string
	m.modalTabHits = nil
	if m.h < 14 {
		if m.modalRunning {
			body = append(body, " "+m.spin.View()+" "+sSubtle.Render("running — output updates live"))
			if m.modalContent == "" {
				body = append(body, "", sSubtle.Render("Preparing the action…"))
			} else {
				body = append(body, "")
				body = append(body, splitLines(m.vp.View(), "")...)
			}
			m.buttons = []*button{{
				label: "Cancel", action: "esc", dim: !m.modalCancelable,
			}}
			hints = "working — follow the prompt above"
			if m.modalCancelable {
				hints = "working — esc cancels this read-only action"
			}
			return m.compose(body, m.renderFooter(hints))
		}
		if len(m.modalTabs) > 0 {
			tabLines, hits := renderOutputTabs(m.modalTabs, m.modalTab,
				m.modalTabHover, m.vp.Width)
			tabY := len(body)
			body = append(body, tabLines...)
			body = append(body, rule(minInt(m.vp.Width, maxInt(m.w-2, 1))))
			for _, hit := range hits {
				hit.y += tabY
				m.modalTabHits = append(m.modalTabHits, hit)
			}
		}
		body = append(body, splitLines(m.vp.View(), "")...)
		m.buttons = []*button{{label: "Close", action: "esc"}}
		hints = "↑↓/wheel scroll · esc close"
		if len(m.modalTabs) > 0 {
			hints = "←/→ tabs · 1-9 jump · ↑↓/wheel scroll · esc close"
		}
		return m.compose(body, m.renderFooter(hints))
	}
	if m.modalRunning {
		status := " " + m.spin.View() + " " + sSubtle.Render("running — output updates live")
		if m.modalContent == "" {
			panel = sConfirmPanel.Render(status + "\n\n" +
				sSubtle.Render("Preparing the action…"))
		} else {
			panel = sPanel.Render(status + "\n\n" + m.vp.View())
		}
		m.buttons = []*button{{
			label: "Cancel", action: "esc", dim: !m.modalCancelable,
		}}
		hints = "working — follow the prompt above"
		if m.modalCancelable {
			hints = "working — esc cancels this read-only action"
		}
	} else {
		content := m.vp.View()
		var relativeTabs []tabHitbox
		if len(m.modalTabs) > 0 {
			tabLines, hits := renderOutputTabs(m.modalTabs, m.modalTab,
				m.modalTabHover, m.vp.Width)
			relativeTabs = hits
			content = strings.Join(tabLines, "\n") + "\n" +
				rule(minInt(m.vp.Width, maxInt(m.w-8, 1))) + "\n" + content
		}
		panel = sPanel.Render(content)
		m.buttons = []*button{{label: "Close", action: "esc"}}
		hints = "↑↓/wheel scroll · esc close"
		if len(m.modalTabs) > 0 {
			hints = "←/→ tabs · 1-9 jump · ↑↓/wheel scroll · esc close"
		}
		if m.vp.TotalLineCount() > m.vp.Height {
			prefix := ""
			if len(m.modalTabs) > 0 {
				prefix = "←/→ tabs · "
			}
			hints = fmt.Sprintf("%s↑↓/wheel scroll (%d%%) · esc close",
				prefix, int(m.vp.ScrollPercent()*100))
		}
		if len(relativeTabs) > 0 {
			panelW := lipgloss.Width(panel)
			panelH := lipgloss.Height(panel)
			area := maxInt(m.h-1-len(body), 1)
			panelX := maxInt((m.w-panelW)/2, 0)
			panelY := len(body) + maxInt((area-panelH)/2, 0)
			for _, hit := range relativeTabs {
				m.modalTabHits = append(m.modalTabHits, tabHitbox{
					x0: panelX + 2 + hit.x0,
					x1: panelX + 2 + hit.x1,
					y:  panelY + 1 + hit.y,
				})
			}
		}
	}
	area := maxInt(m.h-1-len(body), 1)
	placed := lipgloss.Place(m.w, area, lipgloss.Center, lipgloss.Center, panel)
	body = append(body, splitLines(placed, "")...)
	return m.compose(body, m.renderFooter(hints))
}

func outputTabRowCount(tabs []outputTab, width int) int {
	lines, _ := renderOutputTabs(tabs, -1, -1, width)
	return len(lines)
}

// renderOutputTabs wraps compact output tabs without widening the modal.
// Returned hitboxes are relative to the content origin.
func renderOutputTabs(tabs []outputTab, active, hovered, width int) ([]string, []tabHitbox) {
	if len(tabs) == 0 || width < 1 {
		return nil, nil
	}
	var lines []string
	var hits []tabHitbox
	var parts []string
	lineW := 0
	row := 0
	flush := func() {
		if len(parts) == 0 {
			return
		}
		lines = append(lines, strings.Join(parts, " "))
		parts = nil
		lineW = 0
		row++
	}
	for i, tab := range tabs {
		label := fmt.Sprintf("%d %s", i+1, tab.title)
		label = truncate(label, maxInt(width-2, 1))
		style := sTabCompact
		if i == active {
			style = sTabCompactActive
		} else if i == hovered {
			style = sTabCompactHover
		}
		rendered := style.Render(label)
		tabW := lipgloss.Width(rendered)
		spacer := 0
		if len(parts) > 0 {
			spacer = 1
		}
		if len(parts) > 0 && lineW+spacer+tabW > width {
			flush()
			spacer = 0
		}
		x0 := lineW + spacer
		hits = append(hits, tabHitbox{x0: x0, x1: x0 + tabW - 1, y: row})
		parts = append(parts, rendered)
		lineW += spacer + tabW
	}
	flush()
	return lines, hits
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

// compose pads the body to fill the screen and pins the footer to the last
// line, recording its row for mouse hitboxes.
func (m *model) compose(body []string, footer string) string {
	m.footerY = m.h - 1
	out := make([]string, 0, m.h)
	for i := 0; i < m.h-1; i++ {
		if i < len(body) {
			out = append(out, truncate(body[i], m.w))
		} else {
			out = append(out, "")
		}
	}
	out = append(out, padRight(truncate(footer, m.w), m.w))
	return strings.Join(out, "\n")
}

func justify(left, right string, w int) string {
	pad := w - ansi.StringWidth(left) - ansi.StringWidth(right) - 2
	if pad < 1 {
		return left
	}
	return left + strings.Repeat(" ", pad) + right
}

func rule(w int) string {
	if w < 1 {
		return ""
	}
	return sRule.Render(strings.Repeat("─", w))
}

// renderFooter lays out the status/hints on the left and clickable buttons
// on the right, recording button hitboxes.
func (m *model) renderFooter(hints string) string {
	btnW := 0
	for _, b := range m.buttons {
		btnW += ansi.StringWidth(b.label) + 4 + 2
	}
	if btnW > 0 {
		btnW -= 2
	}

	var left string
	switch {
	case m.loading:
		left = " " + m.spin.View() + " " + sSubtle.Render("refreshing state…")
	case m.note != "":
		left = sNote.Render("  " + m.note)
	case m.snapshotConfirm || m.discardConfirm:
		left = sSubtle.Render("  " + hints)
	case m.authPrompt || m.configPrompt:
		left = sSubtle.Render("  " + hints)
	default:
		m.help.Width = maxInt(m.w-btnW-4, 12)
		if rendered := m.help.View(m.keys.forScreen(m.scr, m.modal)); rendered != "" {
			left = "  " + rendered
		} else {
			left = sSubtle.Render("  " + hints)
		}
	}
	leftW := ansi.StringWidth(left)
	pad := m.w - leftW - btnW - 2
	if pad < 1 {
		left = truncate(left, maxInt(m.w-btnW-3, 0))
		leftW = ansi.StringWidth(left)
		pad = maxInt(m.w-leftW-btnW-2, 1)
	}
	var b strings.Builder
	b.WriteString(left)
	b.WriteString(strings.Repeat(" ", pad))
	x := leftW + pad
	for i, btn := range m.buttons {
		label := "[ " + btn.label + " ]"
		btn.x0, btn.x1 = x, x+ansi.StringWidth(label)-1
		st := sButton
		switch {
		case btn.dim:
			st = sBtnDim
		case i == m.hoverBtn:
			st = sBtnHot
		}
		b.WriteString(st.Render(label))
		if i < len(m.buttons)-1 {
			b.WriteString("  ")
		}
		x = btn.x1 + 3
	}
	return b.String()
}

// detailsPanel renders the bordered description box.
func detailsPanel(content string, totalW, maxH int) string {
	if totalW < 12 || maxH < 3 {
		return ""
	}
	return sPanel.Width(totalW - 2).MaxHeight(maxH).Render(content)
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// ---------------------------------------------------------------------------
// Row rendering
// ---------------------------------------------------------------------------

func badgePlainText(status, staged string, choice bool) string {
	if choice {
		switch {
		case staged == "on":
			return " → USE"
		case staged == "off":
			return " → DEFAULT"
		case status == "on":
			return " ● ACTIVE"
		case status == "off":
			return " ○ PRESET"
		}
	}
	switch {
	case staged == "on":
		return " → ON"
	case staged == "off":
		return " → OFF"
	}
	switch status {
	case "on":
		return " ● ON"
	case "off":
		return " ○ OFF"
	case "drifted":
		return " ✚ DRIFT"
	case "unmanaged":
		return " ◆ EXTERN"
	case "n/a":
		return " · N/A"
	}
	return status
}

func (m *model) renderRow(i, width int) string {
	r := m.rows[i]
	if r.kind == rowSep {
		heading := strings.ToUpper(r.label)
		if heading == "" {
			heading = "ACTIONS"
		}
		label := sViolet.Bold(true).Render(heading)
		remaining := maxInt(width-ansi.StringWidth(label)-5, 0)
		return truncate("  "+label+"  "+rule(remaining), width)
	}
	selected := i == m.cursor
	hovered := i == m.hover && !selected

	var badgeTxt, title string
	var badgeStyled string
	var dim bool
	switch r.kind {
	case rowTweak:
		t := r.tweak
		badgeTxt = badgePlainText(t.Status, t.Staged, t.Group != "")
		badgeStyled = badge(t.Status, t.Staged, t.Group != "")
		title = strings.TrimRight(t.Title, " ")
		dim = t.Status == "n/a"
	case rowExtra:
		e := r.extra
		badgeTxt = " RUN ›"
		title = e.Label
		dim = e.Disabled
		if dim {
			badgeStyled = sFaint.Render(padRight(badgeTxt, badgeWidth))
		} else {
			badgeStyled = sViolet.Background(cRunBg).Bold(true).
				Render(padRight(badgeTxt, badgeWidth))
		}
	}

	titleStyle := lipgloss.NewStyle()
	if dim {
		titleStyle = sFaint
	}
	prefix := "  "
	if selected {
		prefix = sAccent.Render("▌") + " "
	} else if hovered {
		prefix = sAccent.Render("▏") + " "
	}
	available := maxInt(width-ansi.StringWidth(prefix), 1)
	titleW := maxInt(available-badgeWidth-3, 1)
	renderedTitle := truncate(title, titleW)
	if selected {
		renderedTitle = marqueeText(title, titleW, m.focusMarquee)
	} else if hovered {
		renderedTitle = marqueeText(title, titleW, m.hoverMarquee)
	}
	left := titleStyle.Render(renderedTitle)
	line := prefix + justify(left, badgeStyled, available)
	line = padRight(truncate(line, width), width)
	if selected {
		return sSelected.Render(line)
	}
	if hovered {
		return sHovered.Render(line)
	}
	return line
}

func (m *model) rowNaturalWidth() int {
	w := 0
	for _, r := range m.rows {
		switch r.kind {
		case rowTweak:
			w = maxInt(w, ansi.StringWidth(strings.TrimRight(r.tweak.Title, " ")))
		case rowExtra:
			w = maxInt(w, ansi.StringWidth(r.extra.Label))
		case rowSep:
			w = maxInt(w, ansi.StringWidth(r.label)+5)
		}
	}
	return w + 2 + badgeWidth + 2
}

// ---------------------------------------------------------------------------
// Details content
// ---------------------------------------------------------------------------

// reflow joins hard-wrapped lines within paragraphs so the panel can re-wrap
// text to its own width; indented blocks, list items and label lines keep
// their breaks.
func reflow(s string) string {
	lines := strings.Split(s, "\n")
	var out []string
	for _, l := range lines {
		trimmed := strings.TrimRight(l, " ")
		if trimmed == "" {
			out = append(out, "")
			continue
		}
		prev := ""
		if len(out) > 0 {
			prev = out[len(out)-1]
		}
		joinable := prev != "" &&
			!strings.HasPrefix(l, " ") &&
			!strings.HasPrefix(prev, " ") &&
			!isListStart(trimmed) &&
			!strings.HasSuffix(prev, ":")
		if joinable {
			out[len(out)-1] = prev + " " + trimmed
		} else {
			out = append(out, trimmed)
		}
	}
	return strings.Join(out, "\n")
}

func isListStart(s string) bool {
	if strings.HasPrefix(s, "- ") || strings.HasPrefix(s, "* ") || strings.HasPrefix(s, "• ") {
		return true
	}
	return len(s) > 1 && s[0] >= '0' && s[0] <= '9' && (s[1] == '.' || s[1] == ')')
}

func tweakDetails(t *Tweak) string {
	var b strings.Builder
	if t.Category != "" {
		b.WriteString(sSection.Render(strings.ToUpper(t.Category)))
		b.WriteString("\n\n")
	}
	b.WriteString(sBold.Render(strings.TrimRight(t.Title, " ")))
	b.WriteString("\n\n")
	b.WriteString(reflow(strings.TrimRight(t.Desc, "\n")))
	meaning, st := statusMeaning(t.Status)
	if t.Group != "" {
		meaning, st = choiceStatusMeaning(t.Status)
	}
	if meaning != "" {
		b.WriteString("\n\n")
		b.WriteString(st.Render(meaning))
	}
	if t.Staged != "" {
		b.WriteString("\n")
		b.WriteString(sWarn.Render("Staged: will be turned " + t.Staged + ". Enter un-stages it."))
	}
	return b.String()
}

func extraDetails(e *Extra) string {
	var b strings.Builder
	b.WriteString(sBold.Render(e.Label))
	b.WriteString("\n\n")
	b.WriteString(reflow(strings.TrimRight(e.Desc, "\n")))
	if e.Disabled {
		b.WriteString("\n\n")
		b.WriteString(sWarn.Render("Not available right now — see above."))
	}
	return b.String()
}

func moduleSummary(mod *Module) string {
	var b strings.Builder
	b.WriteString(sBold.Render(mod.Title))
	b.WriteString("\n\n")
	categorized := moduleHasTweakCategories(mod)
	lastCategory := ""
	for _, t := range mod.Tweaks {
		if categorized {
			category := tweakDisplayCategory(t)
			if category != lastCategory {
				if lastCategory != "" {
					b.WriteString("\n")
				}
				b.WriteString(sSection.Render(strings.ToUpper(category)))
				b.WriteString("\n")
				lastCategory = category
			}
		}
		b.WriteString(badge(t.Status, "", t.Group != ""))
		b.WriteString(strings.TrimRight(t.Title, " "))
		b.WriteString("\n")
	}
	if len(mod.Extras) > 0 {
		names := make([]string, 0, len(mod.Extras))
		for _, e := range mod.Extras {
			names = append(names, e.Label)
		}
		b.WriteString("\n")
		b.WriteString(sSubtle.Render("Actions: " + strings.Join(names, " · ")))
	}
	return b.String()
}

func moduleCounts(mod *Module) string {
	var on, off, drift, ext, choices, activeChoices int
	for _, t := range mod.Tweaks {
		if t.Group != "" {
			choices++
			if t.Status == "on" {
				activeChoices++
			}
			continue
		}
		switch t.Status {
		case "on":
			on++
		case "off":
			off++
		case "drifted":
			drift++
		case "unmanaged":
			ext++
		}
	}
	parts := []string{}
	if choices > 0 {
		parts = append(parts, fmt.Sprintf("%d active · %d presets",
			activeChoices, maxInt(choices-activeChoices, 0)))
	}
	if on > 0 {
		parts = append(parts, fmt.Sprintf("%d on", on))
	}
	if off > 0 {
		parts = append(parts, fmt.Sprintf("%d off", off))
	}
	if drift > 0 {
		parts = append(parts, fmt.Sprintf("%d drifted", drift))
	}
	if ext > 0 {
		parts = append(parts, fmt.Sprintf("%d extern", ext))
	}
	return strings.Join(parts, " · ")
}

// ---------------------------------------------------------------------------
// Screens
// ---------------------------------------------------------------------------

func (m *model) viewSplash() string {
	content := " " + m.spin.View() + " " + sSubtle.Render("reading system state…")
	return lipgloss.Place(m.w, m.h, lipgloss.Center, lipgloss.Center, content)
}

func (m *model) viewError() string {
	content := sErr.Render("Could not read the suite state") + "\n\n" +
		m.err.Error() + "\n\n" +
		sSubtle.Render("r retry · q quit")
	return lipgloss.Place(m.w, m.h, lipgloss.Center, lipgloss.Center, content)
}

func (m *model) viewHelp() string {
	h := m.help
	h.ShowAll = m.h >= 12
	h.Width = minInt(maxInt(m.w-10, 30), 100)
	content := sBold.Render("Keyboard shortcuts") + "\n\n" +
		h.View(m.keys.forScreen(m.scr, m.modal)) + "\n\n" +
		sSubtle.Render("? / esc closes this help")
	panel := sConfirmPanel.MaxWidth(maxInt(m.w-6, 20)).Render(content)
	placed := lipgloss.Place(m.w, m.h, lipgloss.Center, lipgloss.Center, panel)
	lines := strings.Split(placed, "\n")
	if len(lines) > m.h {
		lines = lines[:m.h]
	}
	return strings.Join(lines, "\n")
}

func (m *model) headerLines(title string) []string {
	info := m.hostInfo()
	return []string{
		justify("  "+sTitle.Render(title), info, m.w),
		"  " + rule(m.w-4),
		"",
	}
}

func (m *model) hostInfo() string {
	info := sSubtle.Render(m.suite.Host + " · " + m.suite.Kernel)
	if buildRevision != "" {
		info += sFaint.Render(" · " + buildRevision)
	}
	return info
}

func (m *model) viewMain() string {
	if m.w >= 150 && m.h >= 24 {
		return m.viewMainWide()
	}
	mods := m.suite.Modules
	var body []string
	m.listLeft = 0

	// Roomy terminals get the logo header; small ones a compact bar.
	bigHeader := m.h >= len(mods)+len(logoArt)+11
	if bigHeader {
		snap := sSubtle.Render("snapshots: not configured")
		if m.suite.Snapshots {
			snap = sSubtle.Render("snapshots: snapper ") + sGood.Render("✓")
		}
		beside := map[int]string{
			2: sTitle.Render("Tweaks for CachyOS"),
			3: sSubtle.Render(m.suite.Host + " · " + m.suite.Kernel),
			4: snap,
		}
		if buildRevision != "" {
			beside[5] = sFaint.Render("build " + buildRevision)
		}
		for i := range logoArt {
			pad := strings.Repeat(" ", maxInt(logoPad-logoLineWidth(i), 1))
			body = append(body, renderLogoLine(i)+pad+beside[i])
		}
		body = append(body, "  "+rule(m.w-4), "")
	} else {
		body = append(body, m.headerLines("Tweaks for CachyOS")...)
	}
	m.listTop = len(body)
	m.listW = m.w - 1
	available := maxInt(m.h-1-m.listTop, 1)
	m.listH = minInt(len(mods), available)
	if available > 8 {
		m.listH = minInt(len(mods), available-7)
	}
	m.keepCursorVisible()
	end := minInt(m.modOffset+m.listH, len(mods))

	for i := m.modOffset; i < end; i++ {
		body = append(body, m.renderModuleRow(i, m.listW))
	}
	body = append(body, "")

	if m.modCursor >= 0 && m.modCursor < len(mods) {
		avail := m.h - 1 - len(body)
		body = append(body, splitLines(detailsPanel(moduleSummary(mods[m.modCursor]), m.w-4, avail), "  ")...)
	}

	m.buttons = mainMenuButtons(m.suite.Snapshots)
	return m.compose(body, m.renderFooter(mainMenuHints()))
}

// mainMenuButtons keeps the dashboard footer identical across the compact and
// wide layouts. Updating is a suite-level concern, so it lives here rather
// than inside any module; it is dimmed unless this is a managed portable
// installation (pacman and git checkouts update through their own tooling).
func mainMenuButtons(snapshots bool) []*button {
	return []*button{
		{label: "Snapshot", action: "s", dim: !snapshots},
		{label: "Update", action: "u", dim: !portableInstall()},
		{label: "About", action: "i"},
		{label: "Quit", action: "q"},
	}
}

func mainMenuHints() string {
	hints := "↑↓ move · enter open · s snapshot"
	if portableInstall() {
		hints += " · u update"
	}
	return hints + " · i about · r refresh · q quit"
}

func (m *model) renderModuleRow(i, width int) string {
	mod := m.suite.Modules[i]
	label := mod.Title
	if n := mod.StagedCount(); n > 0 {
		label += fmt.Sprintf("  (%d staged)", n)
	}
	selected := i == m.modCursor
	hovered := i == m.hover && !selected
	prefix := "  "
	if selected {
		prefix = sAccent.Render("▌") + " "
	} else if hovered {
		prefix = sAccent.Render("▏") + " "
	}
	available := maxInt(width-ansi.StringWidth(prefix), 1)
	counts := sSubtle.Render(moduleCounts(mod))
	labelW := maxInt(available-ansi.StringWidth(counts)-3, 1)
	left := truncate(label, labelW)
	if selected {
		left = marqueeText(label, labelW, m.focusMarquee)
	} else if hovered {
		left = marqueeText(label, labelW, m.hoverMarquee)
	}
	line := prefix + justify(left, counts, available)
	line = padRight(truncate(line, width), width)
	if selected {
		return sSelected.Render(line)
	}
	if hovered {
		return sHovered.Render(line)
	}
	return line
}

func (m *model) viewMainWide() string {
	mods := m.suite.Modules
	body := m.headerLines("Tweaks for CachyOS")
	availableH := maxInt(m.h-1-len(body), 1)
	paneH := minInt(maxInt(len(mods)+5, 20), minInt(availableH, 24))
	topPad := minInt(maxInt((availableH-paneH)/3, 0), 5)
	body = append(body, make([]string, topPad)...)
	dashboardY := len(body)

	panesW := maxInt(m.w-logoPad-4, 1)
	navW := minInt(maxInt(panesW*2/5, 52), 76)
	detailW := minInt(maxInt(panesW-navW, 1), 110)

	navContentW := navW - 4
	m.listH = minInt(len(mods), maxInt(paneH-4, 1))
	m.keepCursorVisible()
	end := minInt(m.modOffset+m.listH, len(mods))
	navLines := []string{sSection.Render("MODULES"), ""}
	for i := m.modOffset; i < end; i++ {
		navLines = append(navLines, m.renderModuleRow(i, navContentW))
	}
	nav := sPanel.Width(navW - 2).Height(paneH - 2).
		Render(strings.Join(navLines, "\n"))

	detail := sPanel.Width(detailW - 2).Height(paneH - 2).
		Render(sSection.Render("OVERVIEW") + "\n\n" +
			moduleSummary(mods[m.modCursor]))

	logo := lipgloss.Place(
		logoPad, paneH, lipgloss.Center, lipgloss.Center, renderLogo(),
	)
	joined := lipgloss.JoinHorizontal(lipgloss.Top, logo, "  ", nav, "  ", detail)
	left := maxInt((m.w-lipgloss.Width(joined))/2, 0)
	body = append(body, splitLines(joined, strings.Repeat(" ", left))...)

	m.listLeft = left + lipgloss.Width(logo) + 4
	m.listTop = dashboardY + 3
	m.listW = navContentW
	m.buttons = mainMenuButtons(m.suite.Snapshots)
	return m.compose(body, m.renderFooter(mainMenuHints()))
}

func (m *model) viewModule() string {
	body := m.headerLines(strings.TrimSpace(m.mod.Title))
	staged := m.mod.StagedCount()
	if staged > 0 {
		toggleable := 0
		for _, t := range m.mod.Tweaks {
			if t.Toggleable {
				toggleable++
			}
		}
		m.progress.Width = minInt(maxInt(m.w/3, 12), 36)
		fraction := float64(staged) / float64(maxInt(toggleable, 1))
		// headerLines always reserves its final row. Reuse it for transient
		// stage state so toggling an item never moves the dashboard below it.
		body[len(body)-1] = "  " + sWarn.Render(fmt.Sprintf("%d staged", staged)) +
			"  " + m.progress.ViewAs(fraction)
	}
	if m.w >= 150 && m.h >= 18 {
		return m.viewModuleWide(body, staged)
	}
	body = append(body,
		justify("  "+sSection.Render("SETTINGS"), sSubtle.Render(moduleCounts(m.mod))+"  ", m.w),
		"",
	)
	m.listTop = len(body)
	m.listLeft = 0

	split := m.w >= 104
	if split {
		m.listW = minInt(maxInt(m.rowNaturalWidth(), 46), minInt(m.w/2+6, 64))
	} else {
		m.listW = m.w - 1
	}

	bodyH := maxInt(m.h-1-m.listTop, 1)
	if split {
		m.listH = bodyH
	} else {
		m.listH = minInt(len(m.rows), maxInt(bodyH/2, 3))
		if bodyH < 8 {
			m.listH = bodyH
		}
	}
	m.keepCursorVisible()
	end := minInt(m.rowOffset+m.listH, len(m.rows))
	var listLines []string
	for i := m.rowOffset; i < end; i++ {
		listLines = append(listLines, m.renderRow(i, m.listW))
	}

	var content string
	if m.selectable(m.cursor) {
		r := m.rows[m.cursor]
		if r.kind == rowTweak {
			content = tweakDetails(r.tweak)
		} else {
			content = extraDetails(r.extra)
		}
	}

	if split {
		panel := detailsPanel(content, m.w-m.listW-3, bodyH)
		left := strings.Join(listLines, "\n")
		joined := lipgloss.JoinHorizontal(lipgloss.Top, left, " ", panel)
		body = append(body, splitLines(joined, "")...)
	} else {
		body = append(body, listLines...)
		body = append(body, "")
		avail := m.h - 1 - len(body)
		body = append(body, splitLines(detailsPanel(content, m.w-4, avail), "  ")...)
	}

	applyLabel := "Apply"
	if staged > 0 {
		applyLabel = fmt.Sprintf("Apply %d", staged)
	}
	m.buttons = []*button{
		{label: applyLabel, action: "a", dim: staged == 0},
		{label: "Discard", action: "d", dim: staged == 0},
		{label: "Back", action: "esc"},
	}
	return m.compose(body, m.renderFooter("enter stage · → details · a apply · d discard · r refresh · esc back"))
}

func (m *model) viewModuleWide(body []string, staged int) string {
	availableH := maxInt(m.h-1-len(body), 1)
	paneH := minInt(maxInt(len(m.rows)+4, minInt(availableH, 32)), availableH)
	topPad := minInt(maxInt((availableH-paneH)/3, 0), 4)
	body = append(body, make([]string, topPad)...)
	dashboardY := len(body)

	listOuterW := minInt(maxInt(m.rowNaturalWidth()+4, 60), minInt(m.w/2, 92))
	detailW := minInt(maxInt(m.w-listOuterW-4, 58), 110)
	listContentW := listOuterW - 4

	m.listH = minInt(len(m.rows), maxInt(paneH-4, 1))
	m.keepCursorVisible()
	end := minInt(m.rowOffset+m.listH, len(m.rows))
	listLines := []string{sSection.Render("SETTINGS & ACTIONS"), ""}
	for i := m.rowOffset; i < end; i++ {
		listLines = append(listLines, m.renderRow(i, listContentW))
	}
	listPanel := sPanel.Width(listOuterW - 2).Height(paneH - 2).
		Render(strings.Join(listLines, "\n"))

	content := ""
	if m.selectable(m.cursor) {
		r := m.rows[m.cursor]
		if r.kind == rowTweak {
			content = tweakDetails(r.tweak)
		} else {
			content = extraDetails(r.extra)
		}
	}
	detailPanel := sPanel.Width(detailW - 2).Height(paneH - 2).
		Render(sSection.Render("DETAILS") + "\n\n" + content)

	joined := lipgloss.JoinHorizontal(lipgloss.Top, listPanel, "  ", detailPanel)
	left := maxInt((m.w-lipgloss.Width(joined))/2, 0)
	body = append(body, splitLines(joined, strings.Repeat(" ", left))...)

	m.listLeft = left + 2
	m.listTop = dashboardY + 3
	m.listW = listContentW
	applyLabel := "Apply"
	if staged > 0 {
		applyLabel = fmt.Sprintf("Apply %d", staged)
	}
	m.buttons = []*button{
		{label: applyLabel, action: "a", dim: staged == 0},
		{label: "Discard", action: "d", dim: staged == 0},
		{label: "Back", action: "esc"},
	}
	return m.compose(body, m.renderFooter("enter stage · → details · a apply · d discard · r refresh · esc back"))
}

func (m *model) viewConfirm() string {
	m.layoutConfirm(false)
	body := m.headerLines("Confirm changes — " + strings.TrimSpace(m.mod.Title))
	if m.h < 14 {
		body = append(body, splitLines(m.confirmVP.View(), "")...)
		m.buttons = []*button{
			{label: "Confirm", action: "enter"},
			{label: "Cancel", action: "esc"},
		}
		scroll := "all changes visible"
		if m.confirmVP.TotalLineCount() > m.confirmVP.Height {
			scroll = fmt.Sprintf("scroll %d%%", int(m.confirmVP.ScrollPercent()*100))
		}
		return m.compose(body, m.renderFooter(
			"↑↓/pg↑pg↓ "+scroll+" · enter confirm · esc cancel",
		))
	}
	panelW := minInt(maxInt(m.w-4, 20), 104)
	panel := sConfirmPanel.Width(maxInt(panelW-6, 1)).Render(m.confirmVP.View())
	area := m.h - 1 - len(body)
	placed := lipgloss.Place(m.w, maxInt(area, 1), lipgloss.Center, lipgloss.Center, panel)
	body = append(body, splitLines(placed, "")...)

	m.buttons = []*button{
		{label: "Confirm", action: "enter"},
		{label: "Cancel", action: "esc"},
	}
	scroll := "all changes visible"
	if m.confirmVP.TotalLineCount() > m.confirmVP.Height {
		scroll = fmt.Sprintf("scroll %d%%", int(m.confirmVP.ScrollPercent()*100))
	}
	return m.compose(body, m.renderFooter(
		"↑↓/pg↑pg↓ "+scroll+" · enter confirm · esc cancel",
	))
}

func splitLines(s, indent string) []string {
	if s == "" {
		return nil
	}
	lines := strings.Split(s, "\n")
	if indent != "" {
		for i := range lines {
			lines[i] = indent + lines[i]
		}
	}
	return lines
}
