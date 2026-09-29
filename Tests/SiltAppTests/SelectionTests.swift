import Foundation
import Testing
@testable import Silt

/// Picking a place only shows it; scanning takes an explicit Scan.
@MainActor
@Test func pickingAPlaceDoesNotScanIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-pick-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    let other = root.appendingPathComponent("other")
    let inside = root.appendingPathComponent("scanned/inside")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    let model = WindowModel()
    defer {
        for s in model.sessions { s.close() }
        try? FileManager.default.removeItem(at: root)
    }
    let before = model.sessions.count
    let scanned = inside.deletingLastPathComponent()

    model.select(scanned.path)
    #expect(model.sessions.count == before)
    #expect(model.pending == scanned.path)
    #expect(model.current == nil && model.viewing == nil)

    model.scan(scanned)
    #expect(model.sessions.count == before + 1)
    #expect(model.pending == nil)
    #expect(model.viewing == scanned.path)
    let session = try #require(model.current)

    // Picking somewhere unscanned leaves the scan alone and offers a Scan.
    model.select(other.path)
    #expect(model.sessions.count == before + 1)
    #expect(model.pending == other.path)
    #expect(model.current == nil)

    // Somewhere already scanned, or inside a scan, shows straight away.
    model.select(inside.path)
    #expect(model.current === session)
    #expect(model.viewing == inside.path)
    #expect(model.pending == nil)
    model.select(scanned.path)
    #expect(model.current === session)
    #expect(model.viewing == scanned.path)
    #expect(model.sessions.count == before + 1)
}
