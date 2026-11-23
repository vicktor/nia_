// SPDX-License-Identifier: MPL-2.0

/// The drawable and glyph metrics use backing pixels, not SwiftUI points.
struct NiaTerminalGrid: Equatable {
    let rows: Int
    let columns: Int

    static func fitting(width: Double, height: Double,
                        cellWidth: Double, cellHeight: Double) -> NiaTerminalGrid? {
        guard width.isFinite, height.isFinite, cellWidth.isFinite, cellHeight.isFinite,
              width > 0, height > 0, cellWidth > 0, cellHeight > 0 else { return nil }
        // A view with zero bounds is still being attached. Never resize its PTY
        // to 1×1 or acknowledge a size until a real viewport is available.
        let limit = Double(UInt16.max)
        // Positive values truncate to complete cells when converted to Int.
        return NiaTerminalGrid(
            rows: Int(min(limit, max(1, height / cellHeight))),
            columns: Int(min(limit, max(1, width / cellWidth))))
    }
}

/// A reused NSView can host many PTYs. A size delivered to session A says
/// nothing about session B, even when the view's bounds did not change.
struct NiaTerminalSizeSync {
    private var acknowledgedSession: String?
    private var acknowledgedSize: NiaTerminalGrid?

    mutating func invalidate() {
        acknowledgedSession = nil
        acknowledgedSize = nil
    }

    @discardableResult
    mutating func report(_ size: NiaTerminalGrid, session: String,
                         observedSize: NiaTerminalGrid?,
                         resize: ((Int, Int) -> Bool)?) -> Bool {
        guard let resize else { return false }
        // A changed snapshot also detects a replacement PTY under the same ID
        // (for example SSH reconnect). The last view size alone is insufficient.
        if acknowledgedSession == session, acknowledgedSize == size,
           observedSize == nil || observedSize == size { return true }
        guard resize(size.rows, size.columns) else { return false }
        acknowledgedSession = session
        acknowledgedSize = size
        return true
    }
}
