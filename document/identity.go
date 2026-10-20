package document

import "sync/atomic"

var nextDocumentInstanceID atomic.Uint64

// InstanceID is the process-local numeric identity assigned once by New.
// It remains stable across edits and path changes, but a document reopened at
// the same path receives a different identity even if its revision restarts.
// Nil and documents not constructed by New have identity zero.
func (d *Document) InstanceID() uint64 {
	if d == nil {
		return 0
	}
	return d.instanceID
}
