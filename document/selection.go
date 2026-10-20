package document

// SelectionRange is a disposable, half-open source range contributed by a
// language provider. Its owning projection supplies the source revision;
// commands must not use ranges from a different revision. Parser nodes and
// visual geometry never enter this representation.
type SelectionRange struct {
	StartByte int
	EndByte   int
}
