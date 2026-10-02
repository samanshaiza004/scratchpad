package application

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"scratchpad/editor"
)

// Keep smart-paste's expanded replacement within the foreign editor command
// payload limit enforced by bridge/caliber and the Alicorn edit queue.
const clipboardSmartLinkMaxBytes = 128 * 1024

// PasteDocument inserts plain OS clipboard text into the authoritative,
// revision-checked document buffer as one undoable edit. Markdown documents
// additionally turn a clean HTTP(S) URL into a link when the replaced source
// range is non-empty, valid UTF-8, and single-line. Clipboard HTML and other
// rich formats are deliberately outside this contract.
func (a *Application) PasteDocument(
	id DocumentID,
	expectedRevision uint64,
	startByte, endByte int,
	clipboardText []byte,
	beforeAnchor, beforeCursor int,
) (editor.AppliedEdit, error) {
	if a == nil {
		return editor.AppliedEdit{}, errors.New("nil application")
	}
	doc := a.Documents[id]
	if doc == nil || doc.Editor == nil {
		return editor.AppliedEdit{}, errors.New("unknown document")
	}
	if doc.Revision() != expectedRevision {
		return editor.AppliedEdit{}, fmt.Errorf("%w: expected %d, current %d", ErrStaleEditorRevision, expectedRevision, doc.Revision())
	}
	buffer := &doc.Editor.Buffer
	length := buffer.ByteLen()
	if startByte < 0 || endByte < startByte || endByte > length {
		return editor.AppliedEdit{}, errors.New("paste range outside document buffer")
	}
	if beforeAnchor < 0 || beforeAnchor > length || beforeCursor < 0 || beforeCursor > length {
		return editor.AppliedEdit{}, errors.New("pre-paste selection outside document buffer")
	}
	// Pasting an empty clipboard is a no-op; it must never delete a selected
	// range as a side effect of an empty native clipboard.
	if len(clipboardText) == 0 {
		return editor.AppliedEdit{SourceEdit: editor.SourceEdit{
			BeforeRevision: doc.Revision(),
			AfterRevision:  doc.Revision(),
			StartByte:      startByte,
			OldEndByte:     startByte,
			NewEndByte:     startByte,
		}}, nil
	}

	replacement := doc.Editor.NormalizeLineEndings(clipboardText)
	if doc.RootLanguage == "markdown" {
		// A smart link can never fit when the selected label alone is already
		// over the bounded edit payload, and non-Markdown pastes never need to
		// copy the selected source range at all.
		var selected []byte
		if endByte-startByte <= clipboardSmartLinkMaxBytes {
			var err error
			selected, err = buffer.Bytes(startByte, endByte)
			if err != nil {
				return editor.AppliedEdit{}, err
			}
		}
		if linked, ok := markdownLinkFromClipboard(selected, clipboardText); ok {
			replacement = doc.Editor.NormalizeLineEndings(linked)
		}
	}
	after := startByte + len(replacement)
	before := doc.Revision()
	applied, err := doc.ReplaceWithSelectionStateResult(
		startByte,
		endByte,
		replacement,
		beforeAnchor,
		beforeCursor,
		after,
		after,
	)
	if err != nil {
		return editor.AppliedEdit{}, err
	}
	if doc.Revision() != before {
		a.PinPreview(id)
		a.touchPresentation()
	}
	return applied, nil
}

func markdownLinkFromClipboard(selection, clipboardText []byte) ([]byte, bool) {
	if len(selection) == 0 || !utf8.Valid(selection) || !utf8.Valid(clipboardText) || !cleanHTTPURL(string(clipboardText)) {
		return nil, false
	}
	// Keep the common form exactly in familiar Markdown syntax. Angle
	// destinations are only needed when parentheses in the URL would make a
	// normal parenthesized destination ambiguous.
	angleDestination := strings.ContainsAny(string(clipboardText), "()")
	projectedLength := 4 + len(selection) + len(clipboardText)
	if angleDestination {
		projectedLength += 2
	}
	for _, r := range string(selection) {
		if r == '\n' || r == '\r' || (unicode.IsControl(r) && r != '\t') {
			return nil, false
		}
	}
	for _, b := range selection {
		if b == '&' {
			projectedLength += 4 // "&" becomes "&amp;".
		} else if b == '\\' || b == '[' || b == ']' || b == '*' || b == '_' || b == '\x60' || b == '~' || b == '!' || b == '<' || b == '>' {
			projectedLength++
		}
		if projectedLength > clipboardSmartLinkMaxBytes {
			return nil, false
		}
	}

	var output strings.Builder
	output.Grow(projectedLength)
	output.WriteByte('[')
	for _, b := range selection {
		switch b {
		case '&':
			// Avoid turning entity-like source such as "&copy;" into another
			// glyph when the Markdown renderer processes the link label.
			output.WriteString("&amp;")
		case '\\', '[', ']', '*', '_', '`', '~', '!', '<', '>':
			output.WriteByte('\\')
			output.WriteByte(b)
		default:
			output.WriteByte(b)
		}
	}
	output.WriteString("](")
	if angleDestination {
		output.WriteByte('<')
	}
	output.Write(clipboardText)
	if angleDestination {
		output.WriteByte('>')
	}
	output.WriteByte(')')
	return []byte(output.String()), true
}

func cleanHTTPURL(value string) bool {
	if value == "" || !utf8.ValidString(value) {
		return false
	}
	for _, r := range value {
		if unicode.IsSpace(r) || unicode.IsControl(r) {
			return false
		}
	}
	// These delimiters are not safe inside an angle-bracket CommonMark
	// destination; require their percent-encoded form.
	if strings.ContainsAny(value, "<>\\\"`{}|^") {
		return false
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Opaque != "" || !parsed.IsAbs() || parsed.Host == "" || parsed.User != nil {
		return false
	}
	if !strings.EqualFold(parsed.Scheme, "http") && !strings.EqualFold(parsed.Scheme, "https") {
		return false
	}
	host := parsed.Hostname()
	if host == "" || !cleanURLHost(host) {
		return false
	}
	if port := parsed.Port(); port != "" {
		value, err := strconv.Atoi(port)
		if err != nil || value < 1 || value > 65535 {
			return false
		}
	}
	return true
}

func cleanURLHost(host string) bool {
	if net.ParseIP(host) != nil {
		return true
	}
	// Keep DNS names unambiguous. Unicode names should arrive in their
	// conventional punycode form, as they do in browser-copied URLs.
	if len(host) == 0 || len(host) > 253 || strings.HasSuffix(host, ".") {
		return false
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, r := range label {
			if !(r >= 'a' && r <= 'z') && !(r >= 'A' && r <= 'Z') && !(r >= '0' && r <= '9') && r != '-' {
				return false
			}
		}
	}
	return true
}
