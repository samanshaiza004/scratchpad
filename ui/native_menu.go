package ui

import (
	"net/url"

	"scratchpad/application"
	"scratchpad/commands"

	nativemenu "go.hasen.dev/shirei/ext/menu"
)

// nativeMenuBar reconciles the application menu only on platforms where the
// forked Shirei extension supports it. The same command IDs are used by the
// rendered fallback and the native adapter.
func nativeMenuBar(state *application.Application, shell *workbenchState) bool {
	if !nativemenu.Supported() {
		return false
	}
	model := nativemenu.Model{ApplicationName: "Scratchpad", Menus: []nativemenu.Menu{
		{Label: "File", Items: []nativemenu.Item{
			commandItem(commands.FileOpen, "Open…", "o", true),
			commandItem(commands.QuickOpen, "Quick Open…", "p", true),
			recentMenuItem(state),
			{Kind: nativemenu.SeparatorItem},
			commandItem(commands.FileSave, "Save", "s", state.ActiveDocument() != nil),
			commandItem(commands.FileSaveAs, "Save As…", "", state.ActiveDocument() != nil),
			commandItem(commands.DocumentClose, "Close", "w", state.ActiveDocument() != nil),
		}},
		{Label: "Edit", Items: []nativemenu.Item{
			commandItem(commands.EditUndo, "Undo", "z", state.ActiveDocument() != nil),
			commandItem(commands.EditRedo, "Redo", "Z", state.ActiveDocument() != nil),
			{Kind: nativemenu.SeparatorItem},
			commandItem(commands.EditCut, "Cut", "x", state.ActiveDocument() != nil),
			commandItem(commands.EditCopy, "Copy", "c", state.ActiveDocument() != nil),
			commandItem(commands.EditPaste, "Paste", "v", state.ActiveDocument() != nil),
			commandItem(commands.EditSelectAll, "Select All", "a", state.ActiveDocument() != nil),
			{Kind: nativemenu.SeparatorItem},
			commandItem(commands.DocumentFind, "Find…", "f", state.ActiveDocument() != nil),
		}},
		{Label: "View", Items: []nativemenu.Item{
			commandItem(commands.OutlineToggle, "Outline", "", state.ActiveDocument() != nil),
			commandItem(commands.ViewToggleSidebar, "Toggle Sidebar", "", state.HasWorkspace || state.ActiveDocument() != nil),
			commandItem(commands.FileRevealActive, "Reveal Active File", "", state.HasWorkspace && state.ActiveDocument() != nil),
		}},
		{Label: "Go", Items: []nativemenu.Item{
			commandItem(commands.TabNext, "Next Document", "", len(state.Order) > 1),
			commandItem(commands.TabPrevious, "Previous Document", "", len(state.Order) > 1),
			commandItem(commands.DocumentGoToLine, "Go to Line…", "g", state.ActiveDocument() != nil),
		}},
		{Label: "Help", Items: []nativemenu.Item{
			{Kind: nativemenu.CommandItem, ID: "help.about", Label: "Scratchpad", Enabled: true, Role: nativemenu.RoleAbout},
		}},
	}}
	ids, err := nativemenu.Update(model)
	if err != nil {
		return false
	}
	for _, id := range ids {
		executeCommand(state, shell, commands.ID(id))
	}
	return true
}

func recentMenuItem(state *application.Application) nativemenu.Item {
	paths := state.RecentPaths()
	children := make([]nativemenu.Item, 0, len(paths))
	for _, path := range paths {
		children = append(children, nativemenu.Item{
			Kind:  nativemenu.CommandItem,
			ID:    nativemenu.ID(string(commands.FileOpenRecent) + ":" + url.QueryEscape(path)),
			Label: filepathBase(path), Enabled: true,
		})
	}
	if len(children) == 0 {
		children = append(children, nativemenu.Item{Kind: nativemenu.CommandItem, ID: nativemenu.ID(commands.FileOpenRecent), Label: "No recent files", Enabled: false})
	}
	return nativemenu.Item{Kind: nativemenu.SubmenuItem, Label: "Open Recent", Children: children}
}

func commandItem(id commands.ID, label, key string, enabled bool) nativemenu.Item {
	modifiers := nativemenu.ModPrimary
	if key == "Z" {
		modifiers |= nativemenu.ModShift
	}
	return nativemenu.Item{Kind: nativemenu.CommandItem, ID: nativemenu.ID(id), Label: label, Enabled: enabled, Shortcut: nativemenu.Shortcut{Key: key, Modifiers: modifiers}}
}
