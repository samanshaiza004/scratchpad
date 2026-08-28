// Package commands names the future unified command vocabulary. Behavior and
// key bindings are intentionally deferred until document contexts exist.
package commands

type ID string

const (
	FileOpen        ID = "file.open"
	FileSave        ID = "file.save"
	DocumentFind    ID = "document.find"
	OutlineToggle   ID = "outline.toggle"
	ItemToggle      ID = "item.toggle"
	SelectionExpand ID = "selection.expand"
	CommentToggle   ID = "comment.toggle"
	DocumentFormat  ID = "document.format"
)

var InitialVocabulary = []ID{
	FileOpen,
	FileSave,
	DocumentFind,
	OutlineToggle,
	ItemToggle,
	SelectionExpand,
	CommentToggle,
	DocumentFormat,
}
