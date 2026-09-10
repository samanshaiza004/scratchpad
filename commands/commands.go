// Package commands owns Scratchpad's stable, surface-independent command
// vocabulary. UI surfaces may discover and invoke these IDs, but document
// transformations live in this package rather than in a particular widget.
package commands

type ID string

const (
	FileOpen              ID = "file.open"
	FileSave              ID = "file.save"
	FileSaveAs            ID = "file.save-as"
	DocumentFind          ID = "document.find"
	DocumentFindReplace   ID = "document.find-replace"
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
	SettingsOpen          ID = "settings.open"
	ViewIncreaseFontSize  ID = "view.increase-font-size"
	ViewDecreaseFontSize  ID = "view.decrease-font-size"
	ViewResetFontSize     ID = "view.reset-font-size"
	WorkspaceRefresh      ID = "workspace.refresh"
	WorkspaceToggleFolder ID = "workspace.toggle-folder"
	WorkspaceNewFile      ID = "workspace.new-file"
	WorkspaceNewFolder    ID = "workspace.new-folder"
	WorkspaceRename       ID = "workspace.rename"
	WorkspaceMove         ID = "workspace.move"
	WorkspaceTrash        ID = "workspace.trash"
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
	EditIndentLines       ID = "edit.indent-lines"
	EditOutdentLines      ID = "edit.outdent-lines"
	EditDeleteLine        ID = "edit.delete-line"
	EditInsertLineAbove   ID = "edit.insert-line-above"
	EditInsertLineBelow   ID = "edit.insert-line-below"
	EditMoveLineUp        ID = "edit.move-line-up"
	EditMoveLineDown      ID = "edit.move-line-down"
	EditDuplicateLine     ID = "edit.duplicate-line"
	EditJoinLines         ID = "edit.join-lines"

	MarkdownToggleStrong       ID = "markdown.toggle-strong"
	MarkdownToggleEmphasis     ID = "markdown.toggle-emphasis"
	MarkdownToggleStrike       ID = "markdown.toggle-strike"
	MarkdownToggleInlineCode   ID = "markdown.toggle-inline-code"
	MarkdownInsertLink         ID = "markdown.insert-link"
	MarkdownHeading1           ID = "markdown.heading-1"
	MarkdownHeading2           ID = "markdown.heading-2"
	MarkdownHeading3           ID = "markdown.heading-3"
	MarkdownToggleBulletedList ID = "markdown.toggle-bulleted-list"
	MarkdownToggleNumberedList ID = "markdown.toggle-numbered-list"
	MarkdownToggleQuote        ID = "markdown.toggle-quote"
	MarkdownInsertTask         ID = "markdown.insert-task"
	MarkdownInsertCodeBlock    ID = "markdown.insert-code-block"
	MarkdownSetFenceLanguage   ID = "markdown.set-fence-language"
	MarkdownInsertTable        ID = "markdown.insert-table"
	MarkdownTableNext          ID = "markdown.table-next"
	MarkdownTablePrevious      ID = "markdown.table-previous"
	MarkdownTableEnter         ID = "markdown.table-enter"
	MarkdownInsertDivider      ID = "markdown.insert-divider"
	MarkdownSmartPaste         ID = "markdown.smart-paste"
)

var InitialVocabulary = []ID{
	FileOpen,
	FileSave,
	FileSaveAs,
	DocumentFind,
	DocumentFindReplace,
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
	SettingsOpen,
	ViewIncreaseFontSize,
	ViewDecreaseFontSize,
	ViewResetFontSize,
	WorkspaceRefresh,
	WorkspaceToggleFolder,
	WorkspaceNewFile,
	WorkspaceNewFolder,
	WorkspaceRename,
	WorkspaceMove,
	WorkspaceTrash,
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
	EditIndentLines,
	EditOutdentLines,
	EditDeleteLine,
	EditInsertLineAbove,
	EditInsertLineBelow,
	EditMoveLineUp,
	EditMoveLineDown,
	EditDuplicateLine,
	EditJoinLines,
	MarkdownToggleStrong,
	MarkdownToggleEmphasis,
	MarkdownToggleStrike,
	MarkdownToggleInlineCode,
	MarkdownInsertLink,
	MarkdownHeading1,
	MarkdownHeading2,
	MarkdownHeading3,
	MarkdownToggleBulletedList,
	MarkdownToggleNumberedList,
	MarkdownToggleQuote,
	MarkdownInsertTask,
	MarkdownInsertCodeBlock,
	MarkdownSetFenceLanguage,
	MarkdownInsertTable,
	MarkdownTableNext,
	MarkdownTablePrevious,
	MarkdownTableEnter,
	MarkdownInsertDivider,
	MarkdownSmartPaste,
}
