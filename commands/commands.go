// Package commands names the future unified command vocabulary. Behavior and
// key bindings are intentionally deferred until document contexts exist.
package commands

type ID string

const (
	FileOpen              ID = "file.open"
	FileSave              ID = "file.save"
	FileSaveAs            ID = "file.save-as"
	DocumentFind          ID = "document.find"
	QuickOpen             ID = "file.quick-open"
	WorkspaceSearch       ID = "workspace.search"
	DocumentClose         ID = "document.close"
	DocumentActivate      ID = "document.activate"
	DocumentCloseOthers   ID = "document.close-others"
	DocumentCloseAll      ID = "document.close-all"
	DocumentReopenClosed  ID = "document.reopen-closed"
	DocumentGoToLine      ID = "document.go-to-line"
	DocumentFindNext      ID = "document.find-next"
	DocumentFindPrevious  ID = "document.find-previous"
	TabNext               ID = "tab.next"
	TabPrevious           ID = "tab.previous"
	FileOpenRecent        ID = "file.open-recent"
	FileCopyPath          ID = "file.copy-path"
	FileCopyRelativePath  ID = "file.copy-relative-path"
	FileReveal            ID = "file.reveal"
	FileRevealActive      ID = "file.reveal-active"
	ViewToggleSidebar     ID = "view.toggle-sidebar"
	WorkspaceRefresh      ID = "workspace.refresh"
	WorkspaceToggleFolder ID = "workspace.toggle-folder"
	OutlineToggle         ID = "outline.toggle"
	ItemToggle            ID = "item.toggle"
	SelectionExpand       ID = "selection.expand"
	CommentToggle         ID = "comment.toggle"
	DocumentFormat        ID = "document.format"
	EditUndo              ID = "edit.undo"
	EditRedo              ID = "edit.redo"
	EditCut               ID = "edit.cut"
	EditCopy              ID = "edit.copy"
	EditPaste             ID = "edit.paste"
	EditSelectAll         ID = "edit.select-all"
)

var InitialVocabulary = []ID{
	FileOpen,
	FileSave,
	FileSaveAs,
	DocumentFind,
	QuickOpen,
	WorkspaceSearch,
	DocumentClose,
	DocumentActivate,
	DocumentCloseOthers,
	DocumentCloseAll,
	DocumentReopenClosed,
	DocumentGoToLine,
	DocumentFindNext,
	DocumentFindPrevious,
	TabNext,
	TabPrevious,
	FileOpenRecent,
	FileCopyPath,
	FileCopyRelativePath,
	FileReveal,
	FileRevealActive,
	ViewToggleSidebar,
	WorkspaceRefresh,
	WorkspaceToggleFolder,
	OutlineToggle,
	ItemToggle,
	SelectionExpand,
	CommentToggle,
	DocumentFormat,
	EditUndo,
	EditRedo,
	EditCut,
	EditCopy,
	EditPaste,
	EditSelectAll,
}
