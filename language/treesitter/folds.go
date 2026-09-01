package treesitter

// isFoldNode is Scratchpad-owned policy. Grammar repositories do not need to
// provide fold queries for the initial language proof.
func isFoldNode(kind string) bool {
	switch kind {
	case "function_declaration", "method_declaration", "type_declaration", "block", "composite_literal",
		"method_definition", "class_declaration", "interface_declaration", "type_alias_declaration",
		"enum_declaration", "statement_block", "class_body", "object", "interface_body", "arrow_function":
		return true
	default:
		return false
	}
}
