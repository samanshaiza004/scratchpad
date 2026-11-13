package palette_model

// Item_ID is an application-owned, stable identity. Zero is reserved as the
// empty selection. Keep IDs stable and unique for one palette session.
Item_ID :: distinct u64

Item :: struct {
	id:          Item_ID,
	title:       string,
	description: string,
	keywords:    string,
	disabled:    bool,
}

// Match stores an index into the caller's current Item slice. It owns no item
// strings, so callers may rebuild their item list between input turns.
Match :: struct {
	item_index: int,
}

Selection :: struct {
	id: Item_ID,
}

Filter_Status :: enum {
	Ok,
	Output_Too_Small,
}

item_id_value :: proc(id: Item_ID) -> u64 {
	return u64(id)
}

item_id_from_value :: proc(value: u64) -> Item_ID {
	return Item_ID(value)
}

@(private)
ascii_lower :: proc(value: u8) -> u8 {
	if value >= 'A' && value <= 'Z' { return value + ('a' - 'A') }
	return value
}

@(private)
is_ascii_space :: proc(value: u8) -> bool {
	return value == ' ' || value == '\t' || value == '\n' || value == '\r' || value == '\v' || value == '\f'
}

@(private)
contains_folded :: proc(field, token: string) -> bool {
	if len(token) == 0 { return true }
	if len(token) > len(field) { return false }
	for start in 0..=(len(field)-len(token)) {
		matches := true
		for offset in 0..<len(token) {
			if ascii_lower(field[start+offset]) != ascii_lower(token[offset]) {
				matches = false
				break
			}
		}
		if matches { return true }
	}
	return false
}

@(private)
item_matches_token :: proc(item: Item, token: string) -> bool {
	return contains_folded(item.title, token) ||
		contains_folded(item.description, token) ||
		contains_folded(item.keywords, token)
}

// matches requires every whitespace-separated query token to occur as a
// contiguous substring in at least one searchable field. ASCII letters are
// case-insensitive; non-ASCII UTF-8 bytes compare exactly. This deliberately
// does not promise locale-aware or Unicode case-folded search.
matches :: proc(item: Item, query: string) -> bool {
	position := 0
	for position < len(query) {
		for position < len(query) && is_ascii_space(query[position]) { position += 1 }
		if position >= len(query) { break }
		start := position
		for position < len(query) && !is_ascii_space(query[position]) { position += 1 }
		if !item_matches_token(item, query[start:position]) { return false }
	}
	return true
}

// filter preserves caller order, allowing the application to provide its own
// ranking. output must have room for at least len(items) entries; the returned
// count selects the initialized prefix.
filter :: proc(items: []Item, query: string, output: []Match) -> (count: int, status: Filter_Status) {
	if len(output) < len(items) { return 0, .Output_Too_Small }
	for item, index in items {
		if matches(item, query) {
			output[count] = Match{item_index=index}
			count += 1
		}
	}
	return count, .Ok
}

// index_all records every item in caller order without applying a query. Use
// this when the application has already filtered and ranked its own results.
index_all :: proc(items: []Item, output: []Match) -> (count: int, status: Filter_Status) {
	if len(output) < len(items) { return 0, .Output_Too_Small }
	for _, index in items {
		output[index] = Match{item_index=index}
	}
	return len(items), .Ok
}

// reconcile keeps selection by stable ID while it remains visible and
// enabled. Otherwise it selects the first enabled visible item, or clears it.
reconcile :: proc(selection: ^Selection, items: []Item, visible: []Match) -> bool {
	if selection == nil { return false }
	for match in visible {
		if match.item_index < 0 || match.item_index >= len(items) { continue }
		item := items[match.item_index]
		if item.id == selection.id && !item.disabled { return false }
	}
	old := selection.id
	selection.id = 0
	for match in visible {
		if match.item_index < 0 || match.item_index >= len(items) { continue }
		item := items[match.item_index]
		if item.id != 0 && !item.disabled {
			selection.id = item.id
			break
		}
	}
	return old != selection.id
}

// move wraps through the visible rows and skips disabled items. delta's sign
// determines direction; its magnitude does not skip multiple rows.
move :: proc(selection: ^Selection, items: []Item, visible: []Match, delta: int) -> bool {
	if selection == nil || len(visible) == 0 || delta == 0 { return false }
	direction := 1 if delta > 0 else -1
	current := -1
	for match, index in visible {
		if match.item_index < 0 || match.item_index >= len(items) { continue }
		item := items[match.item_index]
		if item.id == selection.id && !item.disabled {
			current = index
			break
		}
	}
	if current < 0 {
		current = len(visible)-1 if direction > 0 else 0
	}
	for _ in 0..<len(visible) {
		current += direction
		if current < 0 { current = len(visible)-1 }
		if current >= len(visible) { current = 0 }
		match := visible[current]
		if match.item_index < 0 || match.item_index >= len(items) { continue }
		item := items[match.item_index]
		if item.id != 0 && !item.disabled {
			changed := selection.id != item.id
			selection.id = item.id
			return changed
		}
	}
	return false
}

activate :: proc(selection: Selection, items: []Item, visible: []Match) -> (id: Item_ID, ok: bool) {
	if selection.id == 0 { return }
	for match in visible {
		if match.item_index < 0 || match.item_index >= len(items) { continue }
		item := items[match.item_index]
		if item.id == selection.id && !item.disabled { return item.id, true }
	}
	return
}
