import Foundation

public enum SessionOrigin {
    public static func isDesktopRoot(originator: String?, source: String?) -> Bool {
        originator?.caseInsensitiveCompare("Codex Desktop") == .orderedSame
            && source?.caseInsensitiveCompare("vscode") == .orderedSame
    }
}
