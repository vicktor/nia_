// SPDX-License-Identifier: MPL-2.0
// Run without AppKit, Metal, or a PTY:
// swiftc native/Sources/NiaTerminalGeometry.swift native/Tests/NiaTerminalGeometryTests.swift -o /tmp/nia-geometry-tests
// /tmp/nia-geometry-tests

@main
struct NiaTerminalGeometryTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fatalError(message) }
            checks += 1
        }
        let large = NiaTerminalGrid(rows: 60, columns: 160)
        let small = NiaTerminalGrid(rows: 30, columns: 100)
        check(NiaTerminalGrid.fitting(width: 1600, height: 1200,
            cellWidth: 10, cellHeight: 20) == large, "Use all available rows and columns")
        check(NiaTerminalGrid.fitting(width: 3200, height: 2400,
            cellWidth: 20, cellHeight: 40) == large, "Retina pixels and glyph metrics use the same units")
        check(NiaTerminalGrid.fitting(width: 1609, height: 1219,
            cellWidth: 10, cellHeight: 20) == large, "Only complete cells fit")
        check(NiaTerminalGrid.fitting(width: 0, height: 1200,
            cellWidth: 10, cellHeight: 20) == nil, "Do not acknowledge zero width during attachment")
        check(NiaTerminalGrid.fitting(width: 1600, height: 0,
            cellWidth: 10, cellHeight: 20) == nil, "Do not acknowledge zero height during attachment")
        check(NiaTerminalGrid.fitting(width: .infinity, height: 1200,
            cellWidth: 10, cellHeight: 20) == nil, "Reject nonfinite bounds")
        check(NiaTerminalGrid.fitting(width: 1600, height: 1200,
            cellWidth: 0, cellHeight: 20) == nil, "Wait for valid glyph metrics")
        check(NiaTerminalGrid.fitting(width: 1_000_000, height: 1_000_000,
            cellWidth: 1, cellHeight: 1) == NiaTerminalGrid(rows: 65_535, columns: 65_535),
            "Clamp to the FFI range before acknowledging")

        var sync = NiaTerminalSizeSync()
        var deliveries: [NiaTerminalGrid] = []
        let accept: (Int, Int) -> Bool = { rows, columns in
            deliveries.append(NiaTerminalGrid(rows: rows, columns: columns))
            return true
        }
        check(!sync.report(large, session: "A", observedSize: small, resize: nil),
            "An absent callback must not consume the first size")
        check(sync.report(large, session: "A", observedSize: small, resize: accept),
            "Deliver the first real size after attachment")
        check(deliveries == [large], "Exactly one initial resize")
        sync.report(large, session: "A", observedSize: large, resize: accept)
        check(deliveries.count == 1, "Repeated matching frames do not resize the PTY")

        // This is the reported regression: a reused view has unchanged bounds,
        // but the second PTY still has the 30×100 startup grid.
        sync.report(large, session: "B", observedSize: small, resize: accept)
        check(deliveries.count == 2, "A→B must resize even without a window resize")
        sync.report(small, session: "B", observedSize: large, resize: accept)
        check(deliveries.last == small, "A split pane uses its own viewport")
        sync.report(small, session: "A", observedSize: large, resize: accept)
        check(deliveries.count == 4, "Returning to A must deliver B's changed pane size")

        sync.report(small, session: "A", observedSize: small, resize: accept)
        check(deliveries.count == 4, "Reusing a synchronized pane is deduplicated")
        sync.report(small, session: "A", observedSize: large, resize: accept)
        check(deliveries.count == 5, "A replacement PTY under the same ID invalidates stale acknowledgement")
        sync.invalidate()
        sync.report(small, session: "A", observedSize: small, resize: accept)
        check(deliveries.count == 6, "Reattachment or new font metrics revalidate the grid")

        var failures = 0
        let reject: (Int, Int) -> Bool = { _, _ in failures += 1; return false }
        check(!sync.report(large, session: "C", observedSize: small, resize: reject),
            "A failed backend resize is not acknowledged")
        check(!sync.report(large, session: "C", observedSize: small, resize: reject),
            "The same size is retried after failure")
        check(failures == 2, "Both failed requests reached the backend")
        check(sync.report(large, session: "C", observedSize: small, resize: accept),
            "A newly available PTY accepts the previously failed size")
        sync.report(large, session: "C", observedSize: large, resize: accept)
        check(deliveries.count == 7, "The successful retry is then deduplicated")
        print("Nia terminal geometry: \(checks) checks passed")
    }
}
