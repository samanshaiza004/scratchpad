package main

import "core:fmt"
import "core:os"
import alicorn "alicorn:runtime"
import theme "alicorn:theme"

main :: proc() {
	args := os.args
	if len(args) != 4 {
		fmt.eprintln("usage: theme_codegen <workbench.json> <paper.json> <generated.odin>")
		os.exit(2)
	}

	base := theme.theme_builtin_base_source_create()
	defer theme.theme_builtin_base_source_destroy(&base)
	if len(base.tokens) == 0 || len(base.core_roles) == 0 {
		fmt.eprintln("could not construct Alicorn's typed alicorn.base layer")
		os.exit(1)
	}

	workbench, workbench_ok := theme_codegen_compile_file(args[1], base.model)
	defer theme.theme_output_destroy(&workbench)
	if !workbench_ok {
		os.exit(1)
	}
	paper, paper_ok := theme_codegen_compile_file(args[2], base.model)
	defer theme.theme_output_destroy(&paper)
	if !paper_ok {
		os.exit(1)
	}

	workbench_runtime, workbench_adapted := theme.theme_runtime_style_theme(workbench)
	if !workbench_adapted {
		fmt.eprintln("workbench theme did not adapt to Alicorn's runtime style contract")
		os.exit(1)
	}
	defer theme.theme_runtime_style_theme_destroy(&workbench_runtime)

	paper_runtime, paper_adapted := theme.theme_runtime_style_theme(paper)
	if !paper_adapted {
		fmt.eprintln("paper theme did not adapt to Alicorn's runtime style contract")
		os.exit(1)
	}
	defer theme.theme_runtime_style_theme_destroy(&paper_runtime)

	paper_role := alicorn.style_extension_color_role_id("app.scratchpad.editor", "paper_surface")
	if !theme_codegen_has_extension_role(paper_runtime, paper_role) {
		fmt.eprintln("paper theme must bind app.scratchpad.editor.paper_surface")
		os.exit(1)
	}

	file, write_error := os.create(args[3])
	if write_error != nil {
		fmt.eprintln("could not create generated theme source:", args[3], write_error)
		os.exit(1)
	}
	defer os.close(file)

	fmt.fprintln(file, "// Generated from themes/scratchpad-workbench.json and themes/scratchpad-paper.json.")
	fmt.fprintln(file, "// Do not edit; tools/alicorn.ps1 regenerates this static runtime data.")
	fmt.fprintln(file, "package main")
	fmt.fprintln(file, "")
	fmt.fprintln(file, "import alicorn \"alicorn:runtime\"")
	fmt.fprintln(file, "")
	fmt.fprintfln(file, "SCRATCHPAD_EDITOR_PAPER_SURFACE_ROLE :: alicorn.Style_Extension_Color_Role_ID(u64({}))", u64(paper_role))
	fmt.fprintln(file, "")
	theme_codegen_emit_runtime_theme(file, "scratchpad_workbench_theme", workbench_runtime)
	fmt.fprintln(file, "")
	theme_codegen_emit_runtime_theme(file, "scratchpad_editor_theme", paper_runtime)
	fmt.fprintln(file, "")
	fmt.fprintln(file, "scratchpad_generated_theme_destroy :: proc(theme: ^alicorn.Style_Theme) {")
	fmt.fprintln(file, "    if theme == nil { return }")
	fmt.fprintln(file, "    delete(theme.color_tokens)")
	fmt.fprintln(file, "    delete(theme.length_tokens)")
	fmt.fprintln(file, "    delete(theme.extension_color_roles)")
	fmt.fprintln(file, "    delete(theme.extension_length_roles)")
	fmt.fprintln(file, "    theme.color_tokens = nil")
	fmt.fprintln(file, "    theme.length_tokens = nil")
	fmt.fprintln(file, "    theme.extension_color_roles = nil")
	fmt.fprintln(file, "    theme.extension_length_roles = nil")
	fmt.fprintln(file, "}")
	fmt.fprintln(file, "")
	fmt.println("compiled Scratchpad workbench and paper themes with Alicorn's typed compiler")

}

theme_codegen_compile_file :: proc(path: string, base: theme.Theme_Source_Model) -> (theme.Theme_Compile_Output, bool) {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		fmt.eprintln("could not read theme source:", path, read_error)
		return {}, false
	}
	defer delete(data)

	parsed := theme.theme_json_parse(string(data), path)
	defer theme.theme_json_output_destroy(&parsed)
	for diagnostic in parsed.diagnostics {
		if diagnostic.field != "" {
			fmt.eprintfln("{}:{}:{}: error: {} (field: {})", diagnostic.span.path,
				diagnostic.span.line, diagnostic.span.column, diagnostic.message, diagnostic.field)
		} else {
			fmt.eprintfln("{}:{}:{}: error: {}", diagnostic.span.path,
				diagnostic.span.line, diagnostic.span.column, diagnostic.message)
		}
	}
	if !parsed.ok {
		return {}, false
	}
	if parsed.extends != "alicorn.base" {
		fmt.eprintfln("{}:{}:{}: error: Scratchpad themes must extend alicorn.base",
			path, parsed.source.metadata.span.line, parsed.source.metadata.span.column)
		return {}, false
	}

	output := theme.theme_compile({base, parsed.source}, support=theme.THEME_COMPILER_SUPPORT)
	for diagnostic in output.diagnostics {
		fmt.eprintfln("{}:{}:{}: error: {}", diagnostic.path, diagnostic.span.line,
			diagnostic.span.column, theme_codegen_diagnostic_message(diagnostic.code))
	}
	if !output.ok {
		theme.theme_output_destroy(&output)
		return {}, false
	}
	return output, true
}

theme_codegen_has_extension_role :: proc(
	value: alicorn.Style_Theme,
	role: alicorn.Style_Extension_Color_Role_ID,
) -> bool {
	for binding in value.extension_color_roles {
		if binding.role == role { return true }
	}
	return false
}

theme_codegen_emit_runtime_theme :: proc(file: ^os.File, name: string, value: alicorn.Style_Theme) {
	fmt.fprintfln(file, "{} :: proc() -> alicorn.Style_Theme {{", name)
	fmt.fprintln(file, "    result := alicorn.DEFAULT_STYLE_THEME")
	fmt.fprintln(file, "    result.colors = {")
	for color in value.colors {
		fmt.fprint(file, "        alicorn.Color{")
		fmt.fprintfln(file, "{:.9g}, {:.9g}, {:.9g}, {:.9g}", color.r, color.g, color.b, color.a)
		fmt.fprintln(file, "        },")
	}
	fmt.fprintln(file, "    }")
	fmt.fprintfln(file, "    result.color_tokens = make([]alicorn.Color, {}, context.allocator)", len(value.color_tokens))
	for color, index in value.color_tokens {
		fmt.fprint(file, "    result.color_tokens[")
		fmt.fprintfln(file, "{}] = alicorn.Color{{", index)
		fmt.fprintfln(file, "        {:.9g}, {:.9g}, {:.9g}, {:.9g}", color.r, color.g, color.b, color.a)
		fmt.fprintln(file, "    }")
	}
	fmt.fprintln(file, "    result.core_color_tokens = {")
	for token in value.core_color_tokens {
		fmt.fprint(file, "        alicorn.Style_Color_Token_ID(")
		fmt.fprintfln(file, "{}),", u32(token))
	}
	fmt.fprintln(file, "    }")
	fmt.fprintfln(file, "    result.length_tokens = make([]alicorn.Style_Length, {}, context.allocator)", len(value.length_tokens))
	for length, index in value.length_tokens {
		fmt.fprint(file, "    result.length_tokens[")
		fmt.fprintfln(file, "{}] = alicorn.Style_Length{{logical_units=", index)
		fmt.fprintfln(file, "{:.9g}}}", length.logical_units)
	}
	fmt.fprintfln(file, "    result.extension_color_roles = make([]alicorn.Style_Extension_Color_Role_Binding, {}, context.allocator)", len(value.extension_color_roles))
	for binding, index in value.extension_color_roles {
		fmt.fprint(file, "    result.extension_color_roles[")
		fmt.fprintfln(file, "{}] = alicorn.Style_Extension_Color_Role_Binding{{", index)
		fmt.fprint(file, "        role=alicorn.Style_Extension_Color_Role_ID(u64(")
		fmt.fprintfln(file, "{})),", u64(binding.role))
		fmt.fprint(file, "        token=alicorn.Style_Color_Token_ID(")
		fmt.fprintfln(file, "{}),", u32(binding.token))
		fmt.fprintln(file, "    }")
	}
	fmt.fprintfln(file, "    result.extension_length_roles = make([]alicorn.Style_Extension_Length_Role_Binding, {}, context.allocator)", len(value.extension_length_roles))
	for binding, index in value.extension_length_roles {
		fmt.fprint(file, "    result.extension_length_roles[")
		fmt.fprintfln(file, "{}] = alicorn.Style_Extension_Length_Role_Binding{{", index)
		fmt.fprint(file, "        role=alicorn.Style_Extension_Length_Role_ID(u64(")
		fmt.fprintfln(file, "{})),", u64(binding.role))
		fmt.fprint(file, "        token=alicorn.Style_Length_Token_ID(")
		fmt.fprintfln(file, "{}),", u32(binding.token))
		fmt.fprintln(file, "    }")
	}
	fmt.fprintln(file, "    return result")
	fmt.fprintln(file, "}")
}

theme_codegen_diagnostic_message :: proc(code: theme.Diagnostic_Code) -> string {
	switch code {
	case .Duplicate_Token: return "duplicate token definition"
	case .Token_Type_Changed: return "an overlay cannot change a token's type"
	case .Invalid_Token_Name: return "invalid or empty token name"
	case .Invalid_Token_Kind: return "unsupported token kind"
	case .Unsupported_Schema_Version: return "unsupported theme schema version"
	case .Unsupported_Contract_Version: return "unsupported Alicorn style contract version"
	case .Unknown_Alias: return "alias refers to an unknown token"
	case .Alias_Type_Mismatch: return "alias target has a different token kind"
	case .Alias_Cycle: return "token alias cycle"
	case .Invalid_Color: return "color is outside the supported channel range"
	case .Invalid_Length: return "length is outside the supported logical-unit range"
	case .Token_Value_Type_Mismatch: return "literal value does not match the declared token kind"
	case .Invalid_Core_Role: return "invalid core semantic role"
	case .Duplicate_Core_Role: return "core semantic role is declared more than once"
	case .Core_Role_Token_Not_Found: return "core role refers to an unknown token"
	case .Core_Role_Token_Type_Mismatch: return "core color role must reference a color token"
	case .Invalid_Extension_Role_Namespace: return "extension roles must use app.* or vendor.* namespace"
	case .Duplicate_Extension_Role: return "extension role is declared more than once"
	case .Extension_Role_Type_Changed: return "an overlay cannot change an extension role's type"
	case .Extension_Role_Hash_Collision: return "extension role ID collides with another role"
	case .Extension_Role_Token_Not_Found: return "extension role refers to an unknown token"
	case .Extension_Role_Token_Type_Mismatch: return "extension role and token kinds differ"
	}
	return "theme compiler rejected source"
}