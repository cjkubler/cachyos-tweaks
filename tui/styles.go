package main

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// Palette — dark yet vibrant: saturated neons tuned for a dark terminal.
var (
	cAccent = lipgloss.Color("#00d7ff") // electric cyan
	cGreen  = lipgloss.Color("#2bee9b") // spring green
	cYellow = lipgloss.Color("#ffd23f") // vivid amber
	cRed    = lipgloss.Color("#ff5c7a") // hot coral
	cViolet = lipgloss.Color("#b48bff") // neon violet (actions)
	cDim    = lipgloss.Color("#7d93a8") // blue-gray
	cFaint  = lipgloss.Color("#46586a") // deep steel
	cSelFg  = lipgloss.Color("#001b24") // near-black on cyan
	cHovBg  = lipgloss.Color("#12333f") // dark teal wash
	cBorder = lipgloss.Color("#265d70") // teal steel
	cGoodBg = lipgloss.Color("#10382b")
	cWarnBg = lipgloss.Color("#3b3011")
	cBadBg  = lipgloss.Color("#421823")
	cOffBg  = lipgloss.Color("#182630")
	cRunBg  = lipgloss.Color("#2a2040")
)

var (
	sTitle    = lipgloss.NewStyle().Bold(true).Foreground(cAccent)
	sSubtle   = lipgloss.NewStyle().Foreground(cDim)
	sFaint    = lipgloss.NewStyle().Foreground(cFaint)
	sRule     = lipgloss.NewStyle().Foreground(cFaint)
	sBold     = lipgloss.NewStyle().Bold(true)
	sGood     = lipgloss.NewStyle().Foreground(cGreen)
	sWarn     = lipgloss.NewStyle().Foreground(cYellow)
	sBad      = lipgloss.NewStyle().Foreground(cRed)
	sAccent   = lipgloss.NewStyle().Foreground(cAccent)
	sSelected = lipgloss.NewStyle().Background(cHovBg).Bold(true)
	sHovered  = lipgloss.NewStyle().Background(cHovBg)
	sNote     = lipgloss.NewStyle().Foreground(cYellow)
	sErr      = lipgloss.NewStyle().Foreground(cRed).Bold(true)

	sViolet  = lipgloss.NewStyle().Foreground(cViolet)
	sSection = lipgloss.NewStyle().
			Foreground(cAccent).
			Bold(true)

	sPanel = lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(cBorder).
		Padding(0, 1)

	sConfirmPanel = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(cAccent).
			Padding(1, 2)

	sButton = lipgloss.NewStyle().Foreground(cAccent)
	sBtnHot = lipgloss.NewStyle().Foreground(cAccent).Background(cHovBg).Bold(true)
	sBtnDim = lipgloss.NewStyle().Foreground(cFaint)

	sTab = lipgloss.NewStyle().
		Foreground(cDim).
		Border(lipgloss.RoundedBorder(), true, true, false, true).
		BorderForeground(cFaint).
		Padding(0, 1)
	sTabActive = sTab.
			Foreground(cAccent).
			BorderForeground(cAccent).
			Background(cHovBg).
			Bold(true)
	sTabHover = sTab.
			Foreground(cAccent).
			BorderForeground(cBorder).
			Background(cHovBg)
	sTabCompact = lipgloss.NewStyle().
			Foreground(cDim).
			Padding(0, 1)
	sTabCompactActive = sTabCompact.
				Foreground(cSelFg).
				Background(cAccent).
				Bold(true)
	sTabCompactHover = sTabCompact.
				Foreground(cAccent).
				Background(cHovBg)
	sDocument = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(cBorder).
			Padding(0, 1)
)

// An original C+ mark for this independent project. Keeping the art in plain
// ASCII makes terminal width calculations deterministic.
type logoSeg struct {
	accent bool // cyan accent; green otherwise
	text   string
}

var logoArt = [][]logoSeg{
	{{false, `       .------.`}},
	{{false, `      /  .----'`}},
	{{false, `     |  /        `}, {true, `+`}},
	{{false, `     |  \      `}, {true, `+++++`}},
	{{false, `      \  '----.  `}, {true, `+`}},
	{{false, `       '------'`}},
}

var (
	sLogoGreen = lipgloss.NewStyle().Bold(true).Foreground(cGreen)
	sLogoCyan  = lipgloss.NewStyle().Bold(true).Foreground(cAccent)
)

func renderLogoLine(i int) string {
	var b strings.Builder
	for _, s := range logoArt[i] {
		if s.accent {
			b.WriteString(sLogoCyan.Render(s.text))
		} else {
			b.WriteString(sLogoGreen.Render(s.text))
		}
	}
	return b.String()
}

func logoLineWidth(i int) int {
	w := 0
	for _, s := range logoArt[i] {
		w += len(s.text) // pure ASCII art
	}
	return w
}

func renderLogo() string {
	lines := make([]string, len(logoArt))
	for i := range logoArt {
		lines[i] = renderLogoLine(i) +
			strings.Repeat(" ", maxInt(logoPad-logoLineWidth(i), 0))
	}
	return strings.Join(lines, "\n")
}

// badge renders the fixed-width status cell for a row. Staged state wins.
const badgeWidth = 10

func badge(status, staged string, choice bool) string {
	var txt string
	var st lipgloss.Style
	if choice {
		switch {
		case staged == "on":
			txt, st = " → USE", sWarn.Background(cWarnBg).Bold(true)
		case staged == "off":
			txt, st = " → DEFAULT", sWarn.Background(cWarnBg).Bold(true)
		default:
			switch status {
			case "on":
				txt, st = " ● ACTIVE", sGood.Background(cGoodBg).Bold(true)
			case "off":
				txt, st = " ○ PRESET", sSubtle.Background(cOffBg)
			case "drifted":
				txt, st = " ✚ DRIFT", sBad.Background(cBadBg).Bold(true)
			case "unmanaged":
				txt, st = " ◆ EXTERN", sWarn.Background(cWarnBg).Bold(true)
			case "n/a":
				txt, st = " · N/A", sFaint.Background(cOffBg)
			default:
				txt, st = status, sSubtle
			}
		}
		return st.Render(padRight(txt, badgeWidth))
	}
	switch {
	case staged == "on":
		txt, st = " → ON", sWarn.Background(cWarnBg).Bold(true)
	case staged == "off":
		txt, st = " → OFF", sWarn.Background(cWarnBg).Bold(true)
	default:
		switch status {
		case "on":
			txt, st = " ● ON", sGood.Background(cGoodBg).Bold(true)
		case "off":
			txt, st = " ○ OFF", sSubtle.Background(cOffBg)
		case "drifted":
			txt, st = " ✚ DRIFT", sBad.Background(cBadBg).Bold(true)
		case "unmanaged":
			txt, st = " ◆ EXTERN", sWarn.Background(cWarnBg).Bold(true)
		case "n/a":
			txt, st = " · N/A", sFaint.Background(cOffBg)
		default:
			txt, st = status, sSubtle
		}
	}
	return st.Render(padRight(txt, badgeWidth))
}

func statusMeaning(status string) (string, lipgloss.Style) {
	switch status {
	case "on":
		return "Currently: managed by this suite and intact.", sGood
	case "off":
		return "Currently: not applied.", sSubtle
	case "drifted":
		return "Currently: managed, but the live file was edited afterward.", sBad
	case "unmanaged":
		return "Currently: present, but applied outside this suite.", sWarn
	case "n/a":
		return "Not applicable on this system.", sFaint
	}
	return "", sSubtle
}

func choiceStatusMeaning(status string) (string, lipgloss.Style) {
	switch status {
	case "on":
		return "Currently: this memory policy is active.", sGood
	case "off":
		return "Available preset; selecting it replaces the active policy.", sSubtle
	case "drifted":
		return "Currently selected, but its managed files were edited afterward.", sBad
	case "unmanaged":
		return "A matching policy exists outside this suite; it will not be overwritten.", sWarn
	case "n/a":
		return "Not applicable with the swap devices active on this system.", sFaint
	}
	return "", sSubtle
}

func padRight(s string, w int) string {
	if d := w - ansi.StringWidth(s); d > 0 {
		return s + strings.Repeat(" ", d)
	}
	return s
}

func truncate(s string, w int) string {
	if w <= 0 {
		return ""
	}
	return ansi.Truncate(s, w, "…")
}

// marqueeText reveals a clipped focused/hovered label in-place. It pauses at
// the beginning of each cycle and never changes row geometry.
func marqueeText(s string, w, frame int) string {
	if w <= 0 || ansi.StringWidth(s) <= w {
		return s
	}
	const gap = "   "
	cycle := ansi.StringWidth(s + gap)
	const hold = 6
	position := frame % (cycle + hold)
	if position < hold {
		position = 0
	} else {
		position -= hold
	}
	return ansi.Cut(s+gap+s, position, position+w)
}
