package commands

import "scratchpad/language"

// CommandContext is deliberately made only from primitive product facts.
// It is the common contract used by menus, keybindings, slash commands, and
// toolbars; it does not expose Shirei state or parser nodes.
type CommandContext struct {
	ActiveDocument    bool
	RootLanguage      string
	Markdown          bool
	Code              bool
	EditorFocused     bool
	HasSelection      bool
	Cursor            int
	SelectionStart    int
	SelectionEnd      int
	InTable           bool
	InTask            bool
	InFence           bool
	ProjectionCurrent bool
}

type Keybinding struct {
	Key string
}

type CommandDescriptor struct {
	ID       ID
	Title    string
	Category string
	Bindings []Keybinding
	Visible  func(CommandContext) bool
	Enabled  func(CommandContext) bool
}

func (d CommandDescriptor) IsVisible(ctx CommandContext) bool {
	return d.Visible == nil || d.Visible(ctx)
}

func (d CommandDescriptor) IsEnabled(ctx CommandContext) bool {
	return d.IsVisible(ctx) && (d.Enabled == nil || d.Enabled(ctx))
}

type Registry struct {
	order       []ID
	descriptors map[ID]CommandDescriptor
}

func NewRegistry(descriptors ...CommandDescriptor) Registry {
	result := Registry{order: make([]ID, 0, len(descriptors)), descriptors: make(map[ID]CommandDescriptor, len(descriptors))}
	for _, descriptor := range descriptors {
		if descriptor.ID == "" {
			continue
		}
		if _, exists := result.descriptors[descriptor.ID]; !exists {
			result.order = append(result.order, descriptor.ID)
		}
		result.descriptors[descriptor.ID] = descriptor
	}
	return result
}

func (r Registry) Lookup(id ID) (CommandDescriptor, bool) {
	descriptor, ok := r.descriptors[id]
	return descriptor, ok
}

func (r Registry) IDs() []ID {
	return append([]ID(nil), r.order...)
}

func (r Registry) Enabled(ctx CommandContext) []CommandDescriptor {
	result := make([]CommandDescriptor, 0, len(r.order))
	for _, id := range r.order {
		descriptor := r.descriptors[id]
		if descriptor.IsEnabled(ctx) {
			result = append(result, descriptor)
		}
	}
	return result
}

func (r Registry) Match(key string, ctx CommandContext) (ID, bool) {
	for _, id := range r.order {
		descriptor := r.descriptors[id]
		if !descriptor.IsEnabled(ctx) {
			continue
		}
		for _, binding := range descriptor.Bindings {
			if binding.Key == key {
				return id, true
			}
		}
	}
	return "", false
}

func DefaultRegistry() Registry {
	markdown := func(ctx CommandContext) bool {
		return ctx.ActiveDocument && ctx.Markdown && ctx.EditorFocused && !ctx.InFence
	}
	markdownSurface := func(ctx CommandContext) bool {
		return ctx.ActiveDocument && ctx.Markdown && ctx.EditorFocused
	}
	codeComment := func(ctx CommandContext) bool {
		if !ctx.ActiveDocument || !ctx.Code || !ctx.EditorFocused || ctx.InFence {
			return false
		}
		return language.DefaultRegistry().SupportsCommentToggle(language.ID(ctx.RootLanguage))
	}
	descriptors := make([]CommandDescriptor, 0, len(InitialVocabulary))
	for _, id := range InitialVocabulary {
		descriptors = append(descriptors, CommandDescriptor{ID: id, Title: string(id), Category: "application", Visible: func(CommandContext) bool { return true }, Enabled: func(ctx CommandContext) bool { return ctx.ActiveDocument }})
	}
	for _, descriptor := range []CommandDescriptor{
		{ID: CommentToggle, Title: "Toggle comment", Category: "code", Bindings: []Keybinding{{Key: "primary+/"}}, Visible: func(ctx CommandContext) bool { return ctx.Code }, Enabled: codeComment},
		{ID: ItemToggle, Title: "Toggle task", Category: "markdown", Visible: markdown, Enabled: markdown},
		{ID: DocumentFormat, Title: "Format table", Category: "markdown", Visible: markdown, Enabled: func(ctx CommandContext) bool { return markdown(ctx) && ctx.InTable }},
		{ID: MarkdownToggleStrong, Title: "Strong", Category: "markdown", Bindings: []Keybinding{{Key: "primary+b"}}, Visible: markdown, Enabled: markdown},
		{ID: MarkdownToggleEmphasis, Title: "Emphasis", Category: "markdown", Bindings: []Keybinding{{Key: "primary+i"}}, Visible: markdown, Enabled: markdown},
		{ID: MarkdownToggleStrike, Title: "Strikethrough", Category: "markdown", Visible: markdown, Enabled: markdown},
		{ID: MarkdownToggleInlineCode, Title: "Inline code", Category: "markdown", Visible: markdown, Enabled: markdown},
		{ID: MarkdownInsertLink, Title: "Link", Category: "markdown", Bindings: []Keybinding{{Key: "primary+k"}}, Visible: markdown, Enabled: markdown},
		{ID: MarkdownHeading1, Title: "Heading 1", Category: "markdown", Visible: markdown, Enabled: markdown},
		{ID: MarkdownHeading2, Title: "Heading 2", Category: "markdown", Visible: markdown, Enabled: markdown},
		{ID: MarkdownHeading3, Title: "Heading 3", Category: "markdown", Visible: markdown, Enabled: markdown},
		{ID: MarkdownToggleBulletedList, Title: "Bulleted list", Category: "markdown", Visible: markdown, Enabled: markdown},
		{ID: MarkdownToggleNumberedList, Title: "Numbered list", Category: "markdown", Visible: markdown, Enabled: markdown},
		{ID: MarkdownToggleQuote, Title: "Quote", Category: "markdown", Visible: markdown, Enabled: markdown},
		{ID: MarkdownInsertTask, Title: "Task", Category: "markdown", Visible: markdown, Enabled: markdown},
		{ID: MarkdownInsertCodeBlock, Title: "Code block", Category: "markdown", Visible: markdown, Enabled: markdown},
		{ID: MarkdownSetFenceLanguage, Title: "Code fence language", Category: "markdown", Visible: markdownSurface, Enabled: func(ctx CommandContext) bool { return markdownSurface(ctx) && ctx.InFence }},
		{ID: MarkdownInsertTable, Title: "Table", Category: "markdown", Visible: markdown, Enabled: markdown},
		{ID: MarkdownTableNext, Title: "Next table cell", Category: "markdown", Visible: markdown, Enabled: func(ctx CommandContext) bool { return markdown(ctx) && ctx.InTable }},
		{ID: MarkdownTablePrevious, Title: "Previous table cell", Category: "markdown", Visible: markdown, Enabled: func(ctx CommandContext) bool { return markdown(ctx) && ctx.InTable }},
		{ID: MarkdownTableEnter, Title: "Next table row", Category: "markdown", Visible: markdown, Enabled: func(ctx CommandContext) bool { return markdown(ctx) && ctx.InTable }},
		{ID: MarkdownInsertDivider, Title: "Divider", Category: "markdown", Visible: markdown, Enabled: markdown},
		{ID: MarkdownSmartPaste, Title: "Paste as link", Category: "markdown", Visible: markdown, Enabled: markdown},
	} {
		if _, exists := findDescriptor(descriptors, descriptor.ID); exists {
			for i := range descriptors {
				if descriptors[i].ID == descriptor.ID {
					descriptors[i] = descriptor
				}
			}
			continue
		}
		descriptors = append(descriptors, descriptor)
	}
	return NewRegistry(descriptors...)
}

func findDescriptor(descriptors []CommandDescriptor, id ID) (CommandDescriptor, bool) {
	for _, descriptor := range descriptors {
		if descriptor.ID == id {
			return descriptor, true
		}
	}
	return CommandDescriptor{}, false
}
