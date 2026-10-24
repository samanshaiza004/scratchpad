# Full, Skim, and Outline

Scratchpad's density modes are read-only presentations over the open source
document. They do not create a second buffer or change source bytes, revision,
dirty state, or the editor's selection. Return to **Full** to resume editing.

Every reduced excerpt carries its document identity, source revision, original
byte range, source line range, and projection occurrence key. The frontend
displays only a bounded window of excerpts (up to 128 at a time); the source
text for any one excerpt is capped at 256 bytes. Compact separators mark omitted
source between excerpts or at the end of the projection, including a source-line
count when it is known. Each excerpt has a **Go to source** action: it returns
to Full and reveals the original location only when the excerpt still matches
the document's current revision.

Excerpt rows use measured, wrapped text heights at the resolved viewport width
and follow editor zoom. Code uses the editor's monospace font. Source line
metadata and omission markers are smaller, muted text. Markdown Outline indents
headings by their source heading depth. These measurements are cached per
projection page and reset when the viewport, font, or zoom changes.

## Initial deterministic policy

- **Full** shows the ordinary editable source view.
- **Skim** shows Markdown headings, the first paragraph in each section,
  task items, and the opening line of fenced code blocks. Paragraph excerpts
  are capped at 256 bytes. For supported code, Skim shows each symbol's
  declaration line and the next source line when available.
- **Outline** shows hierarchically indented Markdown headings. For supported
  code, it shows the first source line of each recognized symbol declaration.
- Plain text and unsupported language adapters remain in the ordinary Full
  editor with an explanation; no parser is required to keep using the file.

The language/application layer chooses source ranges. The Alicorn frontend
only consumes revision-tagged projection windows and renders them as a
virtualized, read-only list; it does not import parser-specific structures.

The current slice preserves the source editor's selection and its Full-view
scroll position when changing density. Reduced modes retain a separate scroll
position per document; changing density lets Alicorn clamp that position to the
new list extent. Reduced presentations remain read-only; editing projected
segments is future work.
