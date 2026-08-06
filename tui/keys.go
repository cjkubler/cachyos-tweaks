package main

import (
	"github.com/charmbracelet/bubbles/key"
)

type keyMap struct {
	Up       key.Binding
	Down     key.Binding
	Open     key.Binding
	Toggle   key.Binding
	Details  key.Binding
	Apply    key.Binding
	Discard  key.Binding
	AllOn    key.Binding
	AllOff   key.Binding
	Refresh  key.Binding
	Snapshot key.Binding
	Update   key.Binding
	About    key.Binding
	Category key.Binding
	Read     key.Binding
	Top      key.Binding
	Bottom   key.Binding
	Close    key.Binding
	Back     key.Binding
	Help     key.Binding
	Quit     key.Binding
}

func newKeyMap() keyMap {
	return keyMap{
		Up: key.NewBinding(
			key.WithKeys("up", "k", "shift+tab"),
			key.WithHelp("↑/k", "move up"),
		),
		Down: key.NewBinding(
			key.WithKeys("down", "j", "tab"),
			key.WithHelp("↓/j", "move down"),
		),
		Open: key.NewBinding(
			key.WithKeys("enter", "right", "l"),
			key.WithHelp("enter", "open"),
		),
		Toggle: key.NewBinding(
			key.WithKeys("enter", " "),
			key.WithHelp("enter", "stage"),
		),
		Details: key.NewBinding(
			key.WithKeys("right", "l"),
			key.WithHelp("→/l", "details"),
		),
		Apply: key.NewBinding(
			key.WithKeys("a"),
			key.WithHelp("a", "apply staged"),
		),
		Discard: key.NewBinding(
			key.WithKeys("d"),
			key.WithHelp("d", "discard"),
		),
		AllOn: key.NewBinding(
			key.WithKeys("+", "="),
			key.WithHelp("+", "stage all on"),
		),
		AllOff: key.NewBinding(
			key.WithKeys("-", "_"),
			key.WithHelp("-", "stage all off"),
		),
		Refresh: key.NewBinding(
			key.WithKeys("r"),
			key.WithHelp("r", "refresh"),
		),
		Snapshot: key.NewBinding(
			key.WithKeys("s"),
			key.WithHelp("s", "snapshot"),
		),
		Update: key.NewBinding(
			key.WithKeys("u"),
			key.WithHelp("u", "update suite"),
		),
		About: key.NewBinding(
			key.WithKeys("i"),
			key.WithHelp("i", "about"),
		),
		Category: key.NewBinding(
			key.WithKeys("left", "right", "h", "l"),
			key.WithHelp("←/→", "change category"),
		),
		Read: key.NewBinding(
			key.WithKeys("pgup", "pgdown", " "),
			key.WithHelp("pg↑/pg↓", "read page"),
		),
		Top: key.NewBinding(
			key.WithKeys("home", "g"),
			key.WithHelp("g", "document top"),
		),
		Bottom: key.NewBinding(
			key.WithKeys("end", "G"),
			key.WithHelp("G", "document bottom"),
		),
		Close: key.NewBinding(
			key.WithKeys("esc", "q", "backspace"),
			key.WithHelp("esc", "close"),
		),
		Back: key.NewBinding(
			key.WithKeys("esc", "left", "h", "backspace"),
			key.WithHelp("esc", "back"),
		),
		Help: key.NewBinding(
			key.WithKeys("?"),
			key.WithHelp("?", "all shortcuts"),
		),
		Quit: key.NewBinding(
			key.WithKeys("q", "ctrl+c"),
			key.WithHelp("q", "quit"),
		),
	}
}

type helpBindings struct {
	short []key.Binding
	full  [][]key.Binding
}

func (b helpBindings) ShortHelp() []key.Binding  { return b.short }
func (b helpBindings) FullHelp() [][]key.Binding { return b.full }

func (k keyMap) forScreen(scr screen, modal bool) helpBindings {
	if modal {
		return helpBindings{
			short: []key.Binding{k.Up, k.Down, k.Back, k.Help},
			full:  [][]key.Binding{{k.Up, k.Down}, {k.Back, k.Help, k.Quit}},
		}
	}
	switch scr {
	case scrDocuments:
		return helpBindings{
			short: []key.Binding{k.Up, k.Down, k.Category, k.Read, k.Close, k.Help},
			full: [][]key.Binding{
				{k.Up, k.Down, k.Category},
				{k.Read, k.Top, k.Bottom},
				{k.Close, k.Help, k.Quit},
			},
		}
	case scrModule:
		return helpBindings{
			short: []key.Binding{k.Up, k.Down, k.Toggle, k.Details, k.Apply},
			full: [][]key.Binding{
				{k.Up, k.Down, k.Toggle, k.Details},
				{k.Apply, k.Discard, k.AllOn, k.AllOff},
				{k.Refresh, k.Back, k.Help, k.Quit},
			},
		}
	case scrConfirm:
		return helpBindings{
			short: []key.Binding{k.Up, k.Down, k.Read, k.Open, k.Back},
			full: [][]key.Binding{
				{k.Up, k.Down, k.Read},
				{k.Top, k.Bottom, k.Open, k.Back},
				{k.Help, k.Quit},
			},
		}
	default:
		return helpBindings{
			short: []key.Binding{k.Up, k.Down, k.Open, k.Snapshot, k.About, k.Help},
			full:  [][]key.Binding{{k.Up, k.Down, k.Open}, {k.Snapshot, k.Update, k.About, k.Refresh, k.Help, k.Quit}},
		}
	}
}
