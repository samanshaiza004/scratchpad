package main

import "core:encoding/json"
import "core:fmt"
import "core:testing"

scratchpad_theme_test_json_string_value :: proc(value: json.Value) -> (result: string, ok: bool) {
	#partial switch member in value {
	case json.String:
		return string(member), true
	}
	return "", false
}

@(test)
test_theme_customize_preserves_and_compiles_bundled_and_sparse_sources :: proc(t: ^testing.T) {
	sparse_source := `{
  "schema": 1,
  "contract": "0.2",
  "tokens": {
    "fixture.original": {"$type":"color","$value":{"colorSpace":"srgb","components":[0.2,0.3,0.4],"alpha":1}},
    "fixture.unknown": {"$type":"color","$value":{"colorSpace":"srgb","components":[0.4,0.3,0.2],"alpha":1}}
  }
}

`
	collision_source := `{
  "schema": 1,
  "contract": "0.2",
  "tokens": {
    "scratchpad.custom.paper": {"$type":"color","$value":{"colorSpace":"srgb","components":[0.1,0.2,0.3],"alpha":1}},
    "fixture.original": {"$type":"color","$value":{"colorSpace":"srgb","components":[0.2,0.3,0.4],"alpha":1}}
  }
}`
	fixtures := [?]string{
		SCRATCHPAD_DEFAULT_WORKBENCH_THEME_JSON,
		SCRATCHPAD_COOL_LIGHT_THEME_JSON,
		SCRATCHPAD_CHARCOAL_INK_THEME_JSON,
		SCRATCHPAD_CATPPUCCIN_MOCHA_THEME_JSON,
		sparse_source,
		collision_source,
	}
	for fixture_source in fixtures {
		original_source, original_error := make([]u8, len(fixture_source), context.temp_allocator)
		if original_error != nil {
			testing.expect(t, false, "theme fixture source should allocate")
			continue
		}
		copy(original_source, fixture_source)
		original_value, original_parse_error := json.parse_bytes(original_source, .JSON, parse_integers=true, allocator=context.temp_allocator)
		if original_parse_error != .None {
			testing.expect(t, false, "the source fixture should be valid JSON")
			delete(original_source, context.temp_allocator)
			continue
		}
		original_root, original_root_ok := scratchpad_theme_json_object(original_value)
		original_tokens_value, original_tokens_found := original_root["tokens"]
		original_tokens, original_tokens_ok := scratchpad_theme_json_object(original_tokens_value)
		testing.expect(t, original_root_ok && original_tokens_found && original_tokens_ok,
			"each fixture should expose its original theme tokens")

		for role in Scratchpad_Theme_Customize_Role {
			updated, result := scratchpad_theme_color_override_source(original_source, role, "#D08772", context.temp_allocator)
			testing.expect(t, result == .None,
				fmt.tprintf("Duplicate & Customize should produce JSON for every theme color (result=%v)", result))
			if result != .None { continue }

			updated_value, updated_parse_error := json.parse_bytes(updated, .JSON, parse_integers=true, allocator=context.temp_allocator)
			testing.expect(t, updated_parse_error == .None, "customized source should remain valid JSON")
			if updated_parse_error == .None {
				updated_root, updated_root_ok := scratchpad_theme_json_object(updated_value)
				updated_tokens_value, updated_tokens_found := updated_root["tokens"]
				updated_tokens, updated_tokens_ok := scratchpad_theme_json_object(updated_tokens_value)
				testing.expect(t, updated_root_ok && updated_tokens_found && updated_tokens_ok,
					"customization should retain the theme token object")
				testing.expect(t, len(updated_tokens) == len(original_tokens)+1,
					"customization should add one token without dropping source declarations")
				for original_key, _ in original_tokens {
					_, retained := updated_tokens[original_key]
					testing.expect(t, retained, "all original token declarations should be preserved")
				}
				if _, has_recipes := original_root["recipes"]; has_recipes {
					_, retained_recipes := updated_root["recipes"]
					testing.expect(t, !retained_recipes, "installable color copies should leave component recipes to Scratchpad defaults")
				}

				roles_value, roles_found := updated_root["roles"]
				roles, roles_ok := scratchpad_theme_json_object(roles_value)
				category := "extensions"
				if role == .Accent || role == .Surface { category = "core" }
				category_value, category_found := roles[category]
				category_object, category_ok := scratchpad_theme_json_object(category_value)
				role_name := "app.scratchpad.editor.paper_surface" if role == .Paper else "app.scratchpad.syntax.keyword"
				if role == .Accent { role_name = "accent" }
				if role == .Surface { role_name = "surface" }
				role_value, role_found := category_object[role_name]
				role_alias := ""
				role_alias_ok := false
				if role == .Accent || role == .Surface {
					role_alias, role_alias_ok = scratchpad_theme_test_json_string_value(role_value)
				} else {
					role_object, role_object_ok := scratchpad_theme_json_object(role_value)
					color_value, color_found := role_object["$value"]
					role_alias, role_alias_ok = scratchpad_theme_test_json_string_value(color_value)
					role_alias_ok = role_object_ok && color_found && role_alias_ok
				}
				custom_reference_ok := len(role_alias) > 2 && role_alias[0] == '{' && role_alias[len(role_alias)-1] == '}'
				if custom_reference_ok {
					reference_key := role_alias[1:len(role_alias)-1]
					_, generated_token_found := updated_tokens[reference_key]
					_, reference_was_original := original_tokens[reference_key]
					custom_reference_ok = generated_token_found && !reference_was_original
				}
				testing.expect(t, roles_found && roles_ok && category_found && category_ok && role_found && role_alias_ok,
					fmt.tprintf("the selected Scratchpad role should resolve to the customized token (role=%s, value=%v)", role_name, role_value))
				testing.expect(t, custom_reference_ok, "the selected role should reference a newly added token without overwriting existing declarations")

				candidate := scratchpad_theme_compile_source("test:customized", "Customized test theme", updated, context.temp_allocator)
				testing.expect(t, candidate.valid,
					fmt.tprintf("Alicorn should compile the customized theme using Scratchpad defaults (%s)", candidate.diagnostic))
				scratchpad_theme_candidate_destroy(&candidate, context.temp_allocator)
				json.destroy_value(updated_value, context.temp_allocator)
			}
			delete(updated, context.temp_allocator)
		}
		json.destroy_value(original_value, context.temp_allocator)
		delete(original_source, context.temp_allocator)
	}
}

@(test)
test_theme_customize_reports_invalid_source_without_rewriting_it :: proc(t: ^testing.T) {
	invalid_source := [?]u8{'{', '"', 'b', 'a', 'd', '"', ':'}
	_, invalid_result := scratchpad_theme_color_override_source(invalid_source[:], .Paper, "#D08772", context.temp_allocator)
	testing.expect(t, invalid_result == .Invalid_JSON, "malformed JSON should report its actual failure stage")
	testing.expect(t, string(invalid_source[:]) == `{"bad":`, "failed customization must leave its selected source bytes unchanged")

	missing_tokens := [?]u8{'{', '"', 's', 'c', 'h', 'e', 'm', 'a', '"', ':', '1', '}', '\n'}
	_, missing_result := scratchpad_theme_color_override_source(missing_tokens[:], .Paper, "#D08772", context.temp_allocator)
	testing.expect(t, missing_result == .Missing_Tokens, "valid themes without tokens should report missing declarations")

	wrong_tokens := [?]u8{'{', '"', 't', 'o', 'k', 'e', 'n', 's', '"', ':', '[', ']', '}', '\n'}
	_, wrong_result := scratchpad_theme_color_override_source(wrong_tokens[:], .Paper, "#D08772", context.temp_allocator)
	testing.expect(t, wrong_result == .Invalid_Tokens, "non-object token declarations should report a structural error")
	testing.expect(t, string(wrong_tokens[:]) == "{\"tokens\":[]}\n", "structural errors must not rewrite the selected source")

	good_source := [?]u8{'{', '"', 't', 'o', 'k', 'e', 'n', 's', '"', ':', '{', '}', '}', '\n'}
	_, bad_color_result := scratchpad_theme_color_override_source(good_source[:], .Paper, "#D0877Z", context.temp_allocator)
	testing.expect(t, bad_color_result == .Invalid_Color, "invalid hex input should remain distinguishable from JSON errors")
}
