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
///
/// The note body is a raw HTML block styled to match the tray popover's Home tab (same dark
/// palette/layout as `WindowsTray.paintHome`) rather than plain Markdown — Obsidian's reading view
/// renders inline-styled HTML directly, so the note looks like a screenshot of the popup instead of
/// a text dump. The sprite is inlined as a base64 data URI (not a sibling file) so the note is
/// self-contained and never shows a broken image if the PNG write races an open editor.
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

    // MARK: Popup-matching palette (hex twins of the COLORREFs in WindowsTray.paintHome/limitRow)

    private static let cBg = "#1C1C20"
    private static let cCard = "#141418"
    private static let cDivider = "#34343C"
    private static let cTrack = "#383840"
    private static let cAccent = "#5C98E8"
    private static let cText = "#F2F2F8"
    private static let cTextStrong = "#ECECF4"
    private static let cTextDim = "#9696A2"
    private static let cTextMuted = "#ACACB8"
    private static let cPillOnBg = "#284870", cPillOnFg = "#7DC3FF"
    private static let cPillOffBg = "#2C2C34", cPillOffFg = "#AAAAB6"
    private static let cGreen = "#60C878", cYellow = "#E8B848", cRed = "#E86060"

    private static func rarityColor(_ r: String) -> String {
        switch r {
        case "legendary": return "#C49428"
        case "rare": return "#2E6CC8"
        case "uncommon": return "#2E965C"
        default: return "#5A5A66"
        }
    }

    private static func limitColor(_ pct: Int) -> String {
        pct >= 90 ? cRed : (pct >= 70 ? cYellow : cGreen)
    }

    /// Rounded progress bar (track + fill), same shape as `WindowsTray.drawProgress`.
    private static func progressBar(_ frac: Double, color: String, height: Int = 8) -> String {
        let pct = max(0, min(100, Int((frac * 100).rounded())))
        return """
        <div style="height:\(height)px;border-radius:\(height/2)px;background:\(cTrack);overflow:hidden;">
          <div style="height:100%;width:\(pct)%;background:\(color);"></div>
        </div>
        """
    }

    private static func pill(_ text: String, bg: String, fg: String) -> String {
        "<span style=\"font-size:10px;font-weight:700;background:\(bg);color:\(fg);padding:3px 9px;border-radius:9px;white-space:nowrap;\">\(text)</span>"
    }

    /// One "label ...... value" limit row with its own colored progress bar (mirrors `limitRow`).
    private static func limitRow(_ label: String, _ pct: Int?) -> String {
        let p = pct ?? 0
        let color = pct == nil ? cTextDim : limitColor(p)
        let valueText = pct == nil ? "—" : "\(p)%"
        return """
        <div style="margin-top:10px;">
          <div style="display:flex;justify-content:space-between;font-size:13px;font-weight:700;color:\(cTextStrong);">
            <span>\(label)</span><span style="color:\(color);">\(valueText)</span>
          </div>
          <div style="margin-top:5px;">\(progressBar(Double(p) / 100.0, color: color, height: 6))</div>
        </div>
        """
    }

    /// One "provider · today N · $cost" line for a used provider.
    private static func providerRow(_ label: String, tokens: Int, cost: Double, showCost: Bool) -> String {
        let costPart = showCost ? " · \(TokenFormatter.cost(cost))" : ""
        return """
        <div style="display:flex;justify-content:space-between;font-size:12px;color:\(cText);padding:4px 0;">
          <span style="color:\(cTextMuted);">\(label)</span><span>\(TokenFormatter.compact(tokens))\(costPart)</span>
        </div>
        """
    }

    /// Write (or silently skip, if not configured) `PokeTokenBar.md` with a styled HTML snapshot of
    /// the companion + usage, laid out like the tray popover's Home tab. Called from the normal
    /// refresh cycle (timer tick / user action) — Obsidian picks up the change on its own
    /// file-watcher, no plugin/API round trip needed. Best-effort: never throws, never blocks the
    /// caller on a write failure (e.g. vault folder deleted, file locked by an editor).
    static func write(disp: CompanionDisplay, usage u: UsageSnapshot, spriteData: Data?, spriteIsGIF: Bool) {
        guard let folder = vaultFolder else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.timeZone = windowsLocalTimeZone()

        let spriteImg: String
        if let spriteData {
            let mime = spriteIsGIF ? "image/gif" : "image/png"
            let b64 = spriteData.base64EncodedString()
            spriteImg = "<img src=\"data:\(mime);base64,\(b64)\" width=\"64\" height=\"64\" style=\"image-rendering:pixelated;\" />"
        } else {
            spriteImg = ""
        }

        let rarityBadge: String
        if !disp.isEgg, let rar = disp.rarityText {
            rarityBadge = " " + pill(rar.uppercased(), bg: rarityColor(rar), fg: "#FFFFFF")
        } else {
            rarityBadge = ""
        }

        let stageLine: String
        if disp.isEgg {
            stageLine = "부화 중"
        } else if disp.natureText.isEmpty {
            stageLine = disp.stageText.isEmpty ? " " : disp.stageText
        } else {
            stageLine = disp.stageText.isEmpty ? disp.natureText : "\(disp.stageText) · \(disp.natureText)"
        }

        let toNextText: String
        let n = TokenFormatter.compact(disp.isEgg ? disp.eggTokensToHatch : disp.tokensToNext)
        if disp.isEgg { toNextText = "부화까지 \(n)" }
        else if disp.isFinalStage { toNextText = "졸업까지 \(n)" }
        else { toNextText = "진화까지 \(n)" }

        var provs: [(label: String, on: Bool)] = []
        if u.claudeUsed { provs.append(("Claude Code", true)) }
        if u.codexUsed { provs.append(("Codex", true)) }
        if u.geminiUsed { provs.append(("Gemini", true)) }
        if u.opencodeUsed { provs.append(("OpenCode", true)) }
        if u.hermesUsed { provs.append(("Hermes", true)) }
        let pillsHTML = provs.map { pill($0.label, bg: cPillOnBg, fg: cPillOnFg) }.joined(separator: " ")

        var providerRows = ""
        if u.claudeUsed { providerRows += providerRow("Claude Code", tokens: u.claudeToday, cost: u.claudeCost, showCost: true) }
        if u.codexUsed { providerRows += providerRow("Codex", tokens: u.codexToday, cost: u.codexCost, showCost: false) }
        if u.geminiUsed { providerRows += providerRow("Gemini", tokens: u.geminiToday, cost: u.geminiCost, showCost: true) }
        if u.opencodeUsed { providerRows += providerRow("OpenCode", tokens: u.opencodeToday, cost: u.opencodeCost, showCost: true) }
        if u.hermesUsed { providerRows += providerRow("Hermes Agent", tokens: u.hermesToday, cost: u.hermesCost, showCost: true) }

        var claudeBreakdown = ""
        if u.claudeUsed {
            claudeBreakdown = """
            <div style="font-size:11px;color:\(cTextDim);margin-top:2px;">
              입력 \(TokenFormatter.compact(u.claudeIn))  ·  출력 \(TokenFormatter.compact(u.claudeOut))  ·  cache w \(TokenFormatter.compact(u.claudeCacheW))  ·  cache r \(TokenFormatter.compact(u.claudeCacheR))
            </div>
            """
        }

        var limitsBlock = ""
        if u.claude5h != nil || u.claude7d != nil {
            limitsBlock = """
            <div style="height:1px;background:\(cDivider);margin:14px 0;"></div>
            <div style="font-size:12px;color:\(cTextMuted);">공식 한도</div>
            \(limitRow("5시간 세션", u.claude5h))
            \(limitRow("주간", u.claude7d))
            """
        }

        let html = """
        <div style="background:\(cBg);border-radius:16px;padding:18px 20px;font-family:-apple-system,'Segoe UI',sans-serif;color:\(cText);max-width:420px;">
          <div style="display:flex;gap:14px;align-items:flex-start;">
            <div style="width:76px;height:76px;flex:0 0 76px;background:\(cCard);border-radius:12px;display:flex;align-items:center;justify-content:center;overflow:hidden;">
              \(spriteImg)
            </div>
            <div style="flex:1;min-width:0;">
              <div style="font-size:17px;font-weight:700;color:\(cTextStrong);">\(disp.displayName)\(rarityBadge)</div>
              <div style="font-size:12px;color:\(cTextMuted);margin-top:3px;">\(stageLine)</div>
              <div style="margin-top:9px;">\(progressBar(disp.progress, color: cAccent))</div>
              <div style="font-size:11px;color:\(cTextDim);margin-top:5px;">\(toNextText)</div>
            </div>
          </div>

          <div style="height:1px;background:\(cDivider);margin:16px 0;"></div>

          <div style="display:flex;justify-content:space-between;align-items:flex-end;">
            <div>
              <div style="font-size:12px;color:\(cTextDim);">오늘 토큰</div>
              <div style="font-size:30px;font-weight:700;color:\(cText);margin-top:2px;">\(TokenFormatter.compact(u.todayTokens))</div>
            </div>
            <div style="font-size:15px;font-weight:700;color:\(cTextMuted);">\(TokenFormatter.cost(u.todayCost))</div>
          </div>
          <div style="font-size:12px;color:\(cTextDim);margin-top:8px;">
            이번 주 <span style="color:\(cTextStrong);font-weight:700;">\(TokenFormatter.compact(u.weekTokens))</span> \(TokenFormatter.cost(u.weekCost))
            &nbsp;&nbsp;&nbsp;이번 달 <span style="color:\(cTextStrong);font-weight:700;">\(TokenFormatter.compact(u.monthTokens))</span> \(TokenFormatter.cost(u.monthCost))
          </div>

          \(pillsHTML.isEmpty ? "" : "<div style=\"margin-top:14px;\">\(pillsHTML)</div><div style=\"margin-top:10px;\">\(providerRows)</div>\(claudeBreakdown)")
          \(limitsBlock)

          <div style="text-align:right;font-size:10px;color:\(cTextDim);margin-top:16px;">마지막 업데이트 \(fmt.string(from: Date()))</div>
        </div>
        """

        let text = "# PokeTokenBar\n\n\(html)\n"
        try? text.write(to: folder.appendingPathComponent("PokeTokenBar.md"), atomically: true, encoding: .utf8)

        // The old sibling sprite file is now superseded by the inlined data URI above — clean it up
        // if a previous version left one behind so the vault doesn't accumulate a stale orphan.
        let staleSprite = folder.appendingPathComponent("PokeTokenBar-sprite.png")
        if FileManager.default.fileExists(atPath: staleSprite.path) {
            try? FileManager.default.removeItem(at: staleSprite)
        }
    }
}
#endif
