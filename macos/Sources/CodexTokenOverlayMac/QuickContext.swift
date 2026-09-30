import AppKit
import SwiftUI

enum StatusItemGesture {
    enum Action { case menu, delayedMenu, window }
    static func action(rightClick: Bool, clickCount: Int) -> Action {
        rightClick ? .menu : (clickCount >= 2 ? .window : .delayedMenu)
    }
}

@MainActor
final class QuickContextController {
    let model = ContextSettingsModel()
    var openSettings: (() -> Void)?
    private let popover = NSPopover()
    private var locating = false

    func present(relativeTo button: NSView, mode: ContextMode) {
        guard !model.saving, !locating else { return }
        model.mode = mode
        locate(mode: mode)
        popover.behavior = .semitransient
        popover.contentViewController = NSHostingController(rootView: QuickContextView(model: model,
            retry: { [weak self] in self?.locate(mode: self?.model.mode) },
            locateLink: { [weak self] in self?.locate(mode: self?.model.mode, link: self?.model.targetLink) },
            openSettings: { [weak self] in self?.close(); self?.openSettings?() }))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() { if !model.saving { popover.close() } }

    private func locate(mode: ContextMode?, link: String? = nil) {
        guard !locating, !model.saving else { return }
        locating = true
        model.identifying = true
        model.error = nil
        model.feedback = nil
        Task {
            defer { locating = false; model.identifying = false }
            do {
                let target: ContextTarget.Located
                let title: String?
                if let link {
                    target = try await Task.detached(priority: .userInitiated) { try ContextTarget.locate(link: link) }.value
                    title = nil
                } else {
                    (target, title) = try await FocusedContextTarget.resolve()
                }
                model.load(project: target.project, threadID: target.threadID, observedWindow: nil, observedTarget: nil,
                    scope: .thread, origin: link == nil ? .focused : .link, title: title, selectedMode: mode)
            } catch { model.failTarget(error.localizedDescription) }
        }
    }
}

private struct QuickContextView: View {
    @ObservedObject var model: ContextSettingsModel
    let retry: () -> Void
    let locateLink: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("当前对话上下文", systemImage: "slider.horizontal.3").font(.headline)
                Spacer()
                Button("完整设置", action: openSettings).buttonStyle(.link)
            }
            if model.identifying || model.loading {
                ProgressView("正在核对目标对话…").controlSize(.small)
            } else if let identifier = model.threadID, !model.targetVerificationFailed {
                Text(model.threadTitle ?? String(identifier.prefix(8))).font(.subheadline).lineLimit(2)
                Text("仅此对话 · \(identifier.prefix(8))").font(.caption).foregroundStyle(.secondary)
                Picker("上下文策略", selection: $model.mode) {
                    ForEach(ContextMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).disabled(model.saving)
                if model.mode == .custom {
                    HStack {
                        TextField("例如 485；留空恢复默认", text: $model.input)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("自定义上下文，单位 K tokens")
                        Text("K tokens").font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.mode == .adaptive {
                    Text("从初始档开始；成功自动压缩后按保留比例升档。阈值与档位可在完整设置修改。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("保存后在下一轮加载，不打断当前回复。").font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.error ?? model.validation {
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let message = model.feedback {
                Label(message, systemImage: "checkmark.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                TextField("粘贴 codex://threads/…", text: $model.targetLink)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("目标对话深度链接")
                Button("定位", action: locateLink).disabled(model.targetLink.isEmpty || model.identifying || model.loading || model.saving)
            }
            HStack {
                Button("重新识别焦点", action: retry).disabled(model.identifying || model.loading || model.saving)
                Spacer()
                if model.saving { ProgressView().controlSize(.small) }
                Button("保存设置") { model.save() }.buttonStyle(.borderedProminent).disabled(!model.canSave)
            }
        }.padding(18).frame(width: 390)
    }
}
