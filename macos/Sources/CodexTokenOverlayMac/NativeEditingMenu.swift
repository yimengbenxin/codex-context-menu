import AppKit

@MainActor
enum NativeEditingMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        let application = NSMenu(title: "Codex 上下文")
        application.addItem(withTitle: "退出 Codex 上下文", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let applicationItem = NSMenuItem()
        applicationItem.submenu = application
        menu.addItem(applicationItem)

        let editing = NSMenu(title: "编辑")
        for (title, action, shortcut) in [("撤销", "undo:", "z"), ("重做", "redo:", "z"),
                                         ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                         ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            let item = editing.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: shortcut)
            item.keyEquivalentModifierMask = action == "redo:" ? [.command, .shift] : [.command]
        }
        let editingItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editingItem.submenu = editing
        menu.addItem(editingItem)
        return menu
    }
}
