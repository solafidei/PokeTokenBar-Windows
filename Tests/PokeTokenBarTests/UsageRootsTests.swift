import XCTest
@testable import PokeTokenBar

/// UsageRoots — WSL detection's pure parts. The subprocess/9P parts need a real Windows box with
/// WSL, so what's covered here is the logic that silently breaks detection when wrong: the
/// UTF-16LE output of `wsl.exe -l -q`, and root composition.
final class UsageRootsTests: XCTestCase {

    /// `wsl.exe` writes UTF-16LE. Encode a fixture the same way it does.
    private func utf16LE(_ s: String, bom: Bool) -> Data {
        var bytes: [UInt8] = bom ? [0xFF, 0xFE] : []
        for unit in Array(s.utf16) {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        return Data(bytes)
    }

    func testDecodeUTF16LEWithBOM() {
        XCTAssertEqual(UsageRoots.decode(utf16LE("Ubuntu\r\n", bom: true)), "Ubuntu\r\n")
    }

    func testDecodeUTF16LEWithoutBOM() {
        XCTAssertEqual(UsageRoots.decode(utf16LE("Ubuntu\r\n", bom: false)), "Ubuntu\r\n")
    }

    /// A Linux child's stdout (`wsl -e ...`) comes through as plain UTF-8 — must not be mangled.
    func testDecodeUTF8() {
        XCTAssertEqual(UsageRoots.decode(Data("/home/solafidei\n".utf8)), "/home/solafidei\n")
    }

    /// The regression that makes detection find nothing: decoding UTF-16 as UTF-8.
    func testUTF16OutputIsNotParsedAsEmpty() {
        let raw = utf16LE("Ubuntu\r\n", bom: true)
        XCTAssertFalse(UsageRoots.parseDistroList(raw).isEmpty,
                       "UTF-16LE distro list must decode; empty means detection silently fails")
    }

    func testParseDistroListRealisticOutput() {
        let raw = utf16LE("Ubuntu\r\ndocker-desktop\r\ndocker-desktop-data\r\nDebian\r\n\r\n", bom: true)
        XCTAssertEqual(UsageRoots.parseDistroList(raw), ["Ubuntu", "Debian"],
                       "blank lines dropped; Docker utility VMs skipped (no user homes, costly to boot)")
    }

    func testParseDistroListEmptyOutput() {
        XCTAssertEqual(UsageRoots.parseDistroList(Data()), [])
    }

    /// Additive contract: the native home is always first, so a Windows-native install keeps
    /// exactly the behaviour it had before WSL support existed.
    func testAllStartsWithNativeHome() {
        let roots = UsageRoots.all(".claude/projects")
        let native = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        XCTAssertEqual(roots.first, native)
    }

    /// The real contract `all()` has to honour: native home first, then one entry per WSL home,
    /// each with the suffix appended. Checked against a stub so it cannot pass by restating
    /// `all()`'s own implementation the way an `wslHomes.count`-derived assertion would.
    func testComposeAppendsSuffixToNativeThenEachWSLHome() {
        let native = URL(fileURLWithPath: "C:/Users/me")
        let wsl = [URL(fileURLWithPath: "//wsl.localhost/Ubuntu/home/me"),
                   URL(fileURLWithPath: "//wsl.localhost/Debian/home/me")]
        XCTAssertEqual(UsageRoots.compose(native: native, wslHomes: wsl, suffix: ".claude/projects"),
                       ([native] + wsl).map { $0.appendingPathComponent(".claude/projects") })
    }

    func testWalkTreatsDottedNamesAsFilesAndRecursesIntoTheRest() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ptb-walk-\(UUID().uuidString)")
        let nested = tmp.appendingPathComponent("project-dir")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data().write(to: nested.appendingPathComponent("session.jsonl"))
        try Data().write(to: tmp.appendingPathComponent("top.jsonl"))
        let found = Set(UsageRoots.walk(tmp).map(\.lastPathComponent))
        XCTAssertEqual(found, ["session.jsonl", "top.jsonl"])
    }

    #if !os(Windows)
    func testNoWSLHomesOffWindows() {
        XCTAssertTrue(UsageRoots.wslHomes.isEmpty)
        XCTAssertEqual(UsageRoots.all(".codex/sessions").count, 1)
    }
    #endif
}
