// Package commands names the future unified command vocabulary. Behavior and
// key bindings are intentionally deferred until document contexts exist.
package commands

type ID string

const (
	FileOpen          ID = "file.open"
	FileSave          ID = "file.save"
	FileSaveAs        ID = "file.save-as"
	DocumentFind      ID = "document.find"
	QuickOpen         ID = "file.quick-open"
	WorkspaceSearch   ID = "workspace.search"
	DocumentClose     ID = "document.close"
	TabNext           ID = "tab.next"
	TabPrevious       ID = "tab.previous"
	ViewToggleSidebar ID = "view.toggle-sidebar"
	WorkspaceRefresh  ID = "workspace.refresh"
	OutlineToggle     ID = "outline.toggle"
	ItemToggle        ID = "item.toggle"
	SelectionExpand   ID = "selection.expand"
	CommentToggle     ID = "comment.toggle"
	DocumentFormat    ID = "document.format"
)

var InitialVocabulary = []ID{
	FileOpen,
	FileSave,
	FileSaveAs,
	DocumentFind,
	QuickOpen,
	WorkspaceSearch,
	DocumentClose,
	TabNext,
	TabPrevious,
	ViewToggleSidebar,
	WorkspaceRefresh,
	OutlineToggle,
	ItemToggle,
	SelectionExpand,
	CommentToggle,
	DocumentFormat,
}
