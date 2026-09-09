package workspace

import "errors"

// Trasher is deliberately separate from Workspace. A workspace owns
// contained, reversible path mutations; an OS trash adapter owns platform
// policy and may use Finder, the desktop trash specification, or the Windows
// Recycle Bin.
type Trasher interface {
	Trash(absolutePath string) error
}

// ErrTrashUnavailable means no platform trash adapter has been installed.
// Scratchpad must never silently turn a trash request into permanent delete.
var ErrTrashUnavailable = errors.New("OS trash is unavailable")

// UnavailableTrasher is the explicit default used by embedders that have not
// selected a platform trash integration yet.
type UnavailableTrasher struct{}

func (UnavailableTrasher) Trash(string) error { return ErrTrashUnavailable }
