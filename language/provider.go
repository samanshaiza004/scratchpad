package language

// Provider describes the small root-language capability surface that command
// contexts need. Parser implementations remain behind their existing
// application seam; this registry is intentionally not an LSP or plugin API.
type Provider struct {
	ID                    ID
	LineComment           string
	SupportsCommentToggle bool
}

type Registry struct {
	providers map[ID]Provider
}

func NewRegistry(providers ...Provider) Registry {
	result := Registry{providers: make(map[ID]Provider, len(providers))}
	for _, provider := range providers {
		if provider.ID != "" {
			result.providers[provider.ID] = provider
		}
	}
	return result
}

func (r Registry) Lookup(id ID) (Provider, bool) {
	provider, ok := r.providers[id]
	return provider, ok
}

func (r Registry) SupportsCommentToggle(id ID) bool {
	provider, ok := r.Lookup(id)
	return ok && provider.SupportsCommentToggle && provider.LineComment != ""
}

func DefaultRegistry() Registry {
	return NewRegistry(
		Provider{ID: Markdown},
		Provider{ID: PlainText},
		Provider{ID: Go, LineComment: "//", SupportsCommentToggle: true},
		Provider{ID: Rust, LineComment: "//"},
		Provider{ID: JavaScript, LineComment: "//", SupportsCommentToggle: true},
		Provider{ID: TypeScript, LineComment: "//", SupportsCommentToggle: true},
		Provider{ID: TSX, LineComment: "//", SupportsCommentToggle: true},
		Provider{ID: Python, LineComment: "#"},
		Provider{ID: Shell, LineComment: "#"},
		Provider{ID: JSON},
		Provider{ID: YAML},
	)
}
