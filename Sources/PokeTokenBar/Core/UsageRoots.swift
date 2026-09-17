import Foundation

/// Where provider logs actually live.
///
/// On Windows the tray app runs as a Windows process, so `homeDirectoryForCurrentUser` is
/// `C:\Users\<name>` — but a large share of Windows devs run Claude Code/Codex/etc. *inside WSL*,
/// where the logs land in the Linux home instead. Reading only the Windows home shows 0 tokens
/// forever, which is the single most common "the app is empty" report.
///
/// So every provider root is resolved as a LIST: the Windows home first, then one entry per
/// detected WSL home. Additive — a Windows-native install behaves exactly as before.
enum UsageRoots {
    /// `~/<suffix>` on Windows, plus `<wsl home>/<suffix>` for each detected WSL home.
    /// Non-existent roots are kept: callers enumerate defensively and a distro can appear later.
    static func all(_ suffix: String) -> [URL] {
        compose(native: FileManager.default.homeDirectoryForCurrentUser, wslHomes: wslHomes, suffix: suffix)
    }

    /// Pure half of `all()`, split out so the ordering contract is testable without a live
    /// `wslHomes` (which is `[]` off Windows and environment-dependent on it).
    static func compose(native: URL, wslHomes: [URL], suffix: String) -> [URL] {
        ([native] + wslHomes).map { $0.appendingPathComponent(suffix) }
    }

    /// `true` for a UNC path such as `\\wsl.localhost\Ubuntu\home\me`.
    ///
    /// This matters more than it looks. On Windows, swift-corelibs-foundation's *recursive*
    /// directory APIs — `FileManager.enumerator(at:)`, `enumerator(atPath:)` and
    /// `contentsOfDirectory(at:)` — all return ZERO entries for a UNC path, silently, without
    /// throwing. Only `contentsOfDirectory(atPath:)` walks the share. Measured against a real
    /// `\\wsl.localhost\<distro>\home\me\.claude\projects` holding 2615 `.jsonl` files:
    /// the enumerators saw 0, `contentsOfDirectory(atPath:)` saw all of them. So every recursive
    /// scan has to branch here, or WSL roots read as empty and the whole feature reports zeros.
    static func isUNC(_ url: URL) -> Bool {
        let p = url.path
        return p.hasPrefix("\\\\") || p.hasPrefix("//")
    }

    /// Recursive file list for a root the URL enumerators cannot read (see `isUNC`).
    ///
    /// ponytail: an entry counts as a directory when its name contains no `.`, instead of
    /// stat-ing it. Every provider mangles dots out of its directory names (`~/.claude` becomes
    /// `-home-me--claude`), so this holds for Claude/Codex/Gemini today. It is a deliberate
    /// shortcut: over the 9P share a `fileExists(isDirectory:)` per entry costs ~8 ms, which
    /// turned a 0.7 s walk into 47 s on that same 2615-file tree. If a provider ever ships a
    /// dotted directory name, stat only the dotted entries rather than all of them.
    static func walk(_ root: URL, depth: Int = 0) -> [URL] {
        guard depth < 16 else { return [] }        // cycle/symlink backstop
        var out: [URL] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            let child = root.appendingPathComponent(name)
            if name.contains(".") { out.append(child) } else { out += walk(child, depth: depth + 1) }
        }
        return out
    }

    /// Detected WSL home directories, as Windows UNC paths. Empty on non-Windows and on
    /// Windows boxes with no WSL — resolved once per process (detection spawns a subprocess
    /// and touches the 9P share, neither of which is free).
    static let wslHomes: [URL] = resolveWSLHomes()

    /// Provider marker directories. A `/home/<user>` entry only counts as a real home if it
    /// holds at least one of these — that skips service accounts and empty skeleton homes.
    private static let markers = [".claude", ".codex", ".gemini", ".local/share/opencode", ".hermes"]

    #if os(Windows)

    private static func resolveWSLHomes() -> [URL] {
        // Escape hatch: `PTB_WSL_HOME=\\wsl.localhost\Ubuntu\home\me` (comma-separated for
        // several). Set it and detection is skipped entirely — no wsl.exe spawn, no probing.
        if let raw = ProcessInfo.processInfo.environment["PTB_WSL_HOME"], !raw.isEmpty {
            let manual = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0) }
            AppLog.write("WSL roots: \(manual.count) from PTB_WSL_HOME")
            return manual
        }

        // No wsl.exe → no WSL. This is the fast path for every Windows-native install: one
        // file-existence check, no subprocess, no behaviour change.
        let system32 = (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32"
        let wslExe = "\(system32)\\wsl.exe"
        guard FileManager.default.fileExists(atPath: wslExe) else { return [] }

        let distros = listDistros(wslExe: wslExe)
        guard !distros.isEmpty else { return [] }

        var homes: [URL] = []
        for distro in distros {
            // Touching the share starts the distro, so only probe ones that could plausibly
            // hold logs — `homesIn` stops at the first UNC prefix that enumerates.
            homes += homesIn(distro: distro)
        }
        AppLog.write("WSL roots: \(homes.count) home(s) across \(distros.count) distro(s)")
        return homes
    }

    /// `wsl.exe -l -q` — installed distros, one per line. Does NOT start them.
    private static func listDistros(wslExe: String) -> [String] {
        guard let data = capture(commandLine: "\"\(wslExe)\" -l -q", label: "wsl -l -q") else { return [] }
        return parseDistroList(data)
    }

    /// Holds one probe's result across the thread boundary below.
    private final class ProbeBox: @unchecked Sendable { var value: [URL] = [] }

    /// Bounded wrapper around `probeHomes`. A stopped or corrupted distro, or a 9P share blocked
    /// by a firewall, can make a UNC call block for an OS-dependent stretch with no error. This
    /// runs inside `wslHomes`'s one-time `static let` init, so a wedge here would stall not just
    /// this refresh but every later one — the whole app's numbers would freeze. A blocking
    /// syscall can't be cancelled once in flight, so we abandon the thread rather than join it.
    private static func homesIn(distro: String) -> [URL] {
        let box = ProbeBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.value = probeHomes(distro: distro)
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success else {
            AppLog.write("WSL probe timed out for \(distro) — skipping")
            return []
        }
        return box.value
    }

    /// Candidate homes inside one distro: every `/home/<user>` holding a provider marker, plus
    /// `/root` for people who run as root. Enumerating this starts the distro.
    private static func probeHomes(distro: String) -> [URL] {
        // `wsl.localhost` is the modern share; `wsl$` is the Win10 spelling. Same content.
        for prefix in ["\\\\wsl.localhost\\", "\\\\wsl$\\"] {
            let distroRoot = URL(fileURLWithPath: prefix + distro)
            let homeParent = distroRoot.appendingPathComponent("home")
            // Path-based on purpose: the URL variant returns zero entries over UNC (see isUNC).
            let candidates = ((try? FileManager.default.contentsOfDirectory(atPath: homeParent.path)) ?? [])
                .map { homeParent.appendingPathComponent($0) }
                + [distroRoot.appendingPathComponent("root")]
            let hits = candidates.filter(hasMarker)
            if !hits.isEmpty { return hits }
        }
        return []
    }

    private static func hasMarker(_ home: URL) -> Bool {
        markers.contains { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }
    }

    /// Run a command with no console window and return stdout. `wsl.exe` writes its own output
    /// (the distro list) as UTF-16LE, while `-e <linux binary>` passes the child's UTF-8 through,
    /// so both encodings are attempted.
    private static func capture(commandLine: String, label: String) -> Data? {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptb-wsl-\(UUID().uuidString).txt")
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptb-wsl-\(UUID().uuidString).err")
        defer { try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL) }
        guard let proc = WindowsProcess(commandLine: commandLine,
                                        stdoutPath: outURL.path, stderrPath: errURL.path),
              proc.launched else {
            AppLog.write("\(label) spawn failed")
            return nil
        }
        proc.closeStdin()
        // ponytail: fixed 10s ceiling. WSL service start is the slow case; raise only if real
        // reports show timeouts, not on principle.
        let finished = proc.waitFor(10)
        if !finished { proc.terminate() }
        proc.cleanup()
        guard finished, let data = try? Data(contentsOf: outURL) else {
            if !finished { AppLog.write("\(label) timed out") }
            return nil
        }
        return data
    }

    #else

    // Non-Windows: WSL cannot exist. `all()` degrades to the single native home, unchanged.
    private static func resolveWSLHomes() -> [URL] { [] }

    #endif

    // MARK: pure helpers (cross-platform so they stay testable off Windows)

    /// Decode process output. `wsl.exe` writes its OWN output (the distro list) as UTF-16LE —
    /// decoding it as UTF-8 yields NUL-riddled garbage and zero usable distro names, which is the
    /// classic way this detection silently finds nothing.
    static func decode(_ data: Data) -> String? {
        if data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xFE {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        // No BOM: still UTF-16LE, recognisable by NUL padding in otherwise-ASCII text.
        if data.count >= 2, data.prefix(512).contains(0x00) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        // No NUL anywhere in the window: either genuine UTF-8, or UTF-16LE whose every code unit
        // happens to be non-ASCII. Raw UTF-16LE is almost never valid UTF-8, so a nil decode here
        // means we guessed wrong — fall back rather than losing the whole distro list.
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16LittleEndian)
    }

    /// Distro names from `wsl -l -q` output, cleaned of encoding debris.
    static func parseDistroList(_ data: Data) -> [String] {
        guard let text = decode(data) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            // `wsl -l -q` still exits 0 when no distro is registered and prints an English
            // sentence ("...has no installed distributions..."). A real distro name never
            // contains whitespace, so this rejects the message without parsing English.
            .filter { !$0.contains(where: \.isWhitespace) }
            // Docker Desktop's utility VMs have no user homes and booting them is expensive.
            .filter { !$0.lowercased().hasPrefix("docker-desktop") }
    }
}
