import Testing
@testable import Silt

/// `rowMoves` plans the outline moves for a folder whose rows were re-sorted.
private final class Row {
    let n: Int
    init(_ n: Int) { self.n = n }
}

/// Applies moves the way the outline does: each (from, to) against the rows
/// as they are after the moves before it.
private func apply(_ moves: [(from: Int, to: Int)], to rows: [Row]) -> [Row] {
    var rows = rows
    for m in moves { rows.insert(rows.remove(at: m.from), at: m.to) }
    return rows
}

/// Rows that must move: all but the longest run already in order.
private func minimumMoves(_ current: [Row], _ target: [Row]) -> Int {
    var at: [ObjectIdentifier: Int] = [:]
    for (i, r) in current.enumerated() { at[ObjectIdentifier(r)] = i }
    let was = target.map { at[ObjectIdentifier($0)]! }
    var best = [Int](repeating: 1, count: was.count)
    for i in was.indices {
        for j in 0..<i where was[j] < was[i] { best[i] = max(best[i], best[j] + 1) }
    }
    return was.count - (best.max() ?? 0)
}

@Test func sameOrderNeedsNoMoves() throws {
    let rows = (0..<50).map(Row.init)
    let moves = try #require(rowMoves(from: rows, to: rows, limit: 0))
    #expect(moves.isEmpty)
}

@Test func reordersExactlyWithTheFewestMoves() throws {
    var rng = SystemRandomNumberGenerator()
    for size in [1, 2, 3, 10, 57, 400] {
        for _ in 0..<40 {
            let current = (0..<size).map(Row.init)
            var target = current
            // A few rows moving, as a re-sort after some sizes changed does,
            // or a full shuffle.
            if Bool.random(using: &rng) {
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    target.insert(target.remove(at: Int.random(in: 0..<size, using: &rng)),
                                  at: Int.random(in: 0..<size, using: &rng))
                }
            } else {
                target.shuffle(using: &rng)
            }
            let moves = try #require(rowMoves(from: current, to: target, limit: size))
            #expect(apply(moves, to: current).map(\.n) == target.map(\.n))
            #expect(moves.count == minimumMoves(current, target))
        }
    }
}

@Test func givesUpPastTheLimit() {
    let current = (0..<20).map(Row.init)
    let target = Array(current.reversed()) // 19 rows have to move
    #expect(rowMoves(from: current, to: target, limit: 18) == nil)
    #expect(rowMoves(from: current, to: target, limit: 19)?.count == 19)
}

@Test func refusesDifferentRows() {
    let current = (0..<5).map(Row.init)
    #expect(rowMoves(from: current, to: Array(current.prefix(4)), limit: 10) == nil)
    #expect(rowMoves(from: current, to: Array(current.prefix(4)) + [Row(9)], limit: 10) == nil)
    #expect(rowMoves(from: current, to: [current[0], current[0], current[1], current[2], current[3]], limit: 10) == nil)
}
