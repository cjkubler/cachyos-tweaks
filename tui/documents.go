package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"charm.land/glamour/v2"
	"github.com/charmbracelet/lipgloss"
)

const maxDocumentSize = 1 << 20

type document struct {
	category string
	title    string
	filename string
	body     string
}

type documentNavRow struct {
	category string
	doc      int // -1 for a category heading
}

type tabHitbox struct {
	x0, x1 int
	y      int
}

var projectDocumentSpecs = []struct {
	category string
	title    string
	filename string
}{
	{category: "Start here", title: "Overview", filename: "README.md"},
	{category: "Project", title: "Security policy", filename: "SECURITY.md"},
	{category: "Project", title: "License", filename: "LICENSE"},
	{category: "Project", title: "Attributions", filename: "ATTRIBUTIONS.md"},
}

func (m *model) documentSideNav() bool {
	return m.w >= 72 && m.h >= 16
}

func (m *model) documentFrameWidth() int {
	if m.documentSideNav() {
		return minInt(maxInt(m.w-4, 44), 136)
	}
	return minInt(maxInt(m.w-4, 20), 104)
}

func (m *model) documentNavWidth() int {
	return minInt(maxInt(m.documentFrameWidth()/4, 24), 32)
}

func (m *model) documentItemStyle(index int) lipgloss.Style {
	switch {
	case index == m.docTab:
		return sSelected.Foreground(cAccent)
	case index == m.docHover:
		return sHovered.Foreground(cAccent)
	default:
		return sSubtle
	}
}

func (m *model) documentNavigationRows() []documentNavRow {
	var rows []documentNavRow
	lastCategory := ""
	for i, doc := range m.documents {
		if doc.category != lastCategory {
			rows = append(rows, documentNavRow{category: doc.category, doc: -1})
			lastCategory = doc.category
		}
		rows = append(rows, documentNavRow{doc: i})
	}
	return rows
}

func suiteRoot() string {
	path := scriptPath()
	if absolute, err := filepath.Abs(path); err == nil {
		path = absolute
	}
	return filepath.Dir(path)
}

func safeDocumentPath(path string) bool {
	if path == "" || filepath.IsAbs(path) || strings.Contains(path, `\`) {
		return false
	}
	clean := filepath.Clean(filepath.FromSlash(path))
	return clean != "." && clean != ".." && filepath.ToSlash(clean) == path &&
		!strings.HasPrefix(clean, ".."+string(filepath.Separator)) &&
		strings.HasPrefix(clean, "modules"+string(filepath.Separator))
}

func readDocument(root, category, title, filename string) document {
	candidate := filepath.Join(root, filepath.FromSlash(filename))
	var body []byte
	var err error
	if safeDocumentPath(filename) {
		candidate, err = resolvedModuleDocument(root, candidate)
	} else {
		candidate, err = resolvedProjectDocument(root, candidate)
	}
	if err == nil {
		body, err = readFileBounded(candidate, maxDocumentSize)
	}
	if err != nil {
		body = []byte(fmt.Sprintf(
			"# %s unavailable\n\nCould not read `%s`:\n\n```\n%s\n```\n",
			title, filename, err,
		))
	}
	return document{
		category: category, title: title, filename: filename, body: string(body),
	}
}

func resolvedProjectDocument(root, candidate string) (string, error) {
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(candidate)
	if err != nil {
		return "", err
	}
	relative, err := filepath.Rel(resolvedRoot, resolved)
	if err != nil || relative == "." ||
		relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("document resolves outside the bundled suite")
	}
	return resolved, nil
}

func resolvedModuleDocument(root, candidate string) (string, error) {
	moduleRoot, err := filepath.EvalSymlinks(filepath.Join(root, "modules"))
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(candidate)
	if err != nil {
		return "", err
	}
	relative, err := filepath.Rel(moduleRoot, resolved)
	if err != nil || relative == "." ||
		relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("document resolves outside the bundled modules tree")
	}
	return resolved, nil
}

func readFileBounded(path string, limit int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("not a regular file")
	}
	if info.Size() > limit {
		return nil, fmt.Errorf("document exceeds the %d-byte limit", limit)
	}
	body, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, fmt.Errorf("document exceeds the %d-byte limit", limit)
	}
	return body, nil
}

func loadDocuments(suite *Suite) []document {
	root := suiteRoot()
	docs := make([]document, 0, len(projectDocumentSpecs)+len(suite.Modules))
	docs = append(docs, readDocument(
		root,
		projectDocumentSpecs[0].category,
		projectDocumentSpecs[0].title,
		projectDocumentSpecs[0].filename,
	))
	var moduleSpecs []HelpDocument
	var categories []string
	seenCategory := map[string]bool{}
	seenPath := map[string]bool{}
	for _, module := range suite.Modules {
		for _, spec := range module.Documents {
			if !safeDocumentPath(spec.Path) || seenPath[spec.Path] {
				continue
			}
			seenPath[spec.Path] = true
			moduleSpecs = append(moduleSpecs, spec)
			if !seenCategory[spec.Category] {
				seenCategory[spec.Category] = true
				categories = append(categories, spec.Category)
			}
		}
	}
	for _, category := range categories {
		for _, spec := range moduleSpecs {
			if spec.Category == category {
				docs = append(docs, readDocument(
					root, spec.Category, spec.Title, spec.Path,
				))
			}
		}
	}
	for _, spec := range projectDocumentSpecs[1:] {
		docs = append(docs, readDocument(
			root, spec.category, spec.title, spec.filename,
		))
	}
	return docs
}

func renderDocument(markdown string, width int) (string, error) {
	renderer, err := glamour.NewTermRenderer(
		glamour.WithStandardStyle("dark"),
		glamour.WithWordWrap(maxInt(width, 20)),
	)
	if err != nil {
		return "", err
	}
	rendered, err := renderer.Render(markdown)
	if err != nil {
		return "", err
	}
	return strings.Trim(rendered, "\n"), nil
}
