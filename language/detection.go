// Package language contains language identity and provider seams. Parsing and
// highlighting are deliberately not part of this scaffold.
package language

import (
	"path/filepath"
	"strings"
)

type ID string

const (
	PlainText  ID = "plain-text"
	Markdown   ID = "markdown"
	Go         ID = "go"
	Rust       ID = "rust"
	JavaScript ID = "javascript"
	TypeScript ID = "typescript"
	Python     ID = "python"
	Shell      ID = "shell"
	JSON       ID = "json"
	YAML       ID = "yaml"
)

// DetectPath provides only a root-language hint. It does not parse content or
// attach global meaning to punctuation; all structural projections remain
// language-provider responsibilities.
func DetectPath(path string) ID {
	ext := strings.ToLower(filepath.Ext(path))
	switch ext {
	case ".md", ".markdown", ".mdown":
		return Markdown
	case ".go":
		return Go
	case ".rs":
		return Rust
	case ".js", ".jsx", ".mjs", ".cjs":
		return JavaScript
	case ".ts", ".tsx", ".mts", ".cts":
		return TypeScript
	case ".py":
		return Python
	case ".sh", ".bash", ".zsh":
		return Shell
	case ".json", ".jsonc":
		return JSON
	case ".yaml", ".yml":
		return YAML
	default:
		return PlainText
	}
}
