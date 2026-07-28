#if os(Windows)
import Foundation
import WinSDK

/// Optional: mirror the current companion/usage report into an Obsidian vault note.
///
/// Opt-in only, via a plain text file — never a hardcoded path, since this fork's repo is public
/// and a hardcoded personal vault path would (a) leak it in source control and (b) do nothing
/// useful for anyone else who builds this. Point `%LOCALAPPDATA%\PokeTokenBar\obsidian-vault.txt`
/// at your vault folder (one line, the absolute path) to turn this on; leave it absent/empty and
/// nothing changes.
enum WindowsObsidianExport {
    private static let configURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("PokeTokenBar/obsidian-vault.txt")
    }()

    /// The configured vault folder, if the user opted in and the path still exists.
    private static var vaultFolder: URL? {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// swift-corelibs-foundation on Windows doesn't resolve `TimeZone.current`/`.autoupdatingCurrent`
    /// from the system settings (observed: always reports UTC), so read the offset straight from the
    /// Win32 API instead of trusting Foundation's timezone detection.
    private static func windowsLocalTimeZone() -> TimeZone {
        var tzi = TIME_ZONE_INFORMATION()
        let bias: Int32
        switch GetTimeZoneInformation(&tzi) {
        case DWORD(TIME_ZONE_ID_DAYLIGHT):
            bias = tzi.Bias + tzi.DaylightBias
        default:
            bias = tzi.Bias + tzi.StandardBias
        }
        return TimeZone(secondsFromGMT: Int(-bias) * 60) ?? .current
    }

    /// 10-block text progress bar, e.g. "██████░░░░ 62%" — no image/plugin needed, renders in any
    /// Markdown viewer.
    private static func progressBar(_ fraction: Double) -> String {
        let pct = max(0, min(100, Int((fraction * 100).rounded())))
        let filled = max(0, min(10, Int((fraction * 10).rounded())))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled) + " \(pct)%"
    }

    /// Write (or silently skip, if not configured) `PokeTokenBar.md` (+ a `PokeTokenBar-sprite.png`
    /// alongside it, when a sprite is available) with the current status + usage report. Called
    /// from the normal refresh cycle (timer tick / user action) — Obsidian picks up the change on
    /// its own file-watcher, no plugin/API round trip needed. Best-effort: never throws, never
    /// blocks the caller on a write failure (e.g. vault folder deleted, file locked by an editor).
    static func write(statusLine: String, progress: Double, spritePNG: Data?, report: [String]) {
        guard let folder = vaultFolder else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.timeZone = windowsLocalTimeZone()

        var imageLine = ""
        if let spritePNG {
            let imgURL = folder.appendingPathComponent("PokeTokenBar-sprite.png")
            if (try? spritePNG.write(to: imgURL)) != nil {
                imageLine = "![[PokeTokenBar-sprite.png]]"
            }
        }

        var lines = ["# PokeTokenBar", ""]
        if !imageLine.isEmpty { lines.append(imageLine); lines.append("") }
        lines.append("> [!note] \(statusLine)")
        lines.append("> \(progressBar(progress))")
        lines.append("")
        lines.append("_마지막 업데이트: \(fmt.string(from: Date()))_")
        lines.append("")
        lines.append("## 사용량")
        lines.append(contentsOf: report)
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: folder.appendingPathComponent("PokeTokenBar.md"), atomically: true, encoding: .utf8)
    }
}
#endif
