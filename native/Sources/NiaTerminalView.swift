// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import AppKit
import Metal
import MetalKit
import CoreText
import CryptoKit
import Security

// Nia renders the VT grid in Metal. SwiftUI remains responsible for the macOS chrome.
// Each atlas glyph is rasterized only once for a given font size and screen scale.
private let niaShader = """
#include <metal_stdlib>
using namespace metal;
struct Out { float4 position [[position]]; float2 uv; float4 color; float mode; };
vertex Out vertex_main(uint vid [[vertex_id]], device const float *v [[buffer(0)]],
                       constant float2 &viewport [[buffer(1)]]) {
    uint i = vid * 9;
    Out o;
    o.position = float4(v[i] * 2.0 / viewport.x - 1.0,
                        1.0 - v[i+1] * 2.0 / viewport.y, 0, 1);
    o.uv = float2(v[i+2], v[i+3]);
    o.color = float4(v[i+4],v[i+5],v[i+6],v[i+7]);
    o.mode = v[i+8];
    return o;
}
fragment float4 fragment_main(Out i [[stage_in]],
                              texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler smp(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    if (i.mode < 0.5) return i.color;
    return float4(i.color.rgb, i.color.a * atlas.sample(smp, i.uv).a);
}
"""

private struct GlyphUV {
    let u0: Float; let v0: Float; let u1: Float; let v1: Float
}

private final class GlyphAtlas {
    let device: MTLDevice
    let size = 1024
    let texture: MTLTexture
    private let pixels: UnsafeMutablePointer<UInt8>
    private let context: CGContext
    private var entries: [String: GlyphUV] = [:]
    private var nextX = 1
    private var nextY = 1
    private var rowHeight = 0
    private(set) var dirty = true
    private let font: CTFont
    private let cellWidth: Int
    private let cellHeight: Int

    init?(device: MTLDevice, font: CTFont, cellWidth: Int, cellHeight: Int) {
        self.device = device
        self.font = font
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                            width: size, height: size, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        texture = tex
        pixels = .allocate(capacity: size * size * 4)
        pixels.initialize(repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(data: pixels, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            pixels.deallocate(); return nil
        }
        context = ctx
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
    }
    deinit { pixels.deallocate() }

    func glyph(_ text: String, wide: Bool) -> GlyphUV? {
        let key = (wide ? "W:" : "N:") + text
        if let item = entries[key] { return item }
        let w = cellWidth * (wide ? 2 : 1) + 4
        let h = cellHeight + 4
        if nextX + w >= size { nextX = 1; nextY += rowHeight + 1; rowHeight = 0 }
        guard nextY + h < size else { return nil } // bounded atlas memory
        let x = nextX; let y = nextY
        nextX += w + 1
        rowHeight = max(rowHeight, h)
        context.saveGState()
        // CoreText draws in the local bitmap's bottom-left-origin coordinate space.
        context.setFillColor(NSColor.white.cgColor)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        context.textPosition = CGPoint(x: x + 2, y: size - y - h + 3 + Int(ceil(CTFontGetDescent(font))))
        CTLineDraw(line, context)
        context.restoreGState()
        let uv = GlyphUV(u0: Float(x + 2) / Float(size), v0: Float(y + 2) / Float(size),
                         u1: Float(x + w - 2) / Float(size), v1: Float(y + h - 2) / Float(size))
        entries[key] = uv
        dirty = true
        return uv
    }
    func uploadIfNeeded() {
        guard dirty else { return }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: size * 4)
        dirty = false
    }
}

private func palette(_ code: Int32, foreground: Bool, dark: Bool) -> SIMD4<Float> {
    let defaults: SIMD4<Float> = foreground
        ? (dark ? SIMD4<Float>(0.88,0.91,0.96,1) : SIMD4<Float>(0.13,0.16,0.21,1))
        : (dark ? SIMD4<Float>(0.065,0.081,0.105,1) : SIMD4<Float>(0.985,0.985,0.98,1))
    if code == -1 { return defaults }
    if (code & 0x1000000) != 0 {
        return SIMD4<Float>(Float((code >> 16) & 255)/255,
                            Float((code >> 8) & 255)/255, Float(code & 255)/255, 1)
    }
    let base: [(Float,Float,Float)] = [
        (0.13,0.15,0.18),(0.82,0.30,0.33),(0.36,0.72,0.50),(0.88,0.70,0.36),
        (0.38,0.58,0.91),(0.73,0.48,0.80),(0.35,0.75,0.81),(0.82,0.84,0.86),
        (0.40,0.44,0.50),(1.0,0.43,0.45),(0.48,0.89,0.61),(1.0,0.84,0.49),
        (0.52,0.67,1.0),(0.87,0.62,0.98),(0.53,0.88,0.94),(1.0,1.0,1.0)]
    let c = Int(code)
    if c < 16 && c >= 0 { let rgb = base[c]; return SIMD4(rgb.0,rgb.1,rgb.2,1) }
    if c >= 16 && c <= 231 {
        let n = c - 16
        let levels: [Float] = [0,95,135,175,215,255]
        return SIMD4(levels[n / 36] / 255, levels[(n / 6) % 6] / 255, levels[n % 6] / 255, 1)
    }
    if c >= 232 && c <= 255 { let gray = Float(8 + (c-232)*10)/255; return SIMD4(gray,gray,gray,1) }
    return defaults
}

final class NiaMetalView: MTKView, MTKViewDelegate {
    var onBytes: (([UInt8]) -> Void)?
    var onResize: ((Int, Int) -> Bool)?
    var onScroll: ((Int) -> Void)?
    // Files dropped from Finder are inserted as shell-quoted paths, never executed.
    private var hoveringFileDrop = false
    var onFocus: (() -> Void)?
    var focusEpochSeen: UInt64 = 0
    private var scrollRemainder: CGFloat = 0
    var activeSessionID: String? {
        didSet {
            guard activeSessionID != oldValue else { return }
            // Session-specific selection and blink state must not leak across tabs.
            pendingEscape?.cancel()
            pendingEscape = nil
            selectionStart = nil
            selectionEnd = nil
            scrollRemainder = 0
            currentRevision = nil
            phase = true
            terminalFrame = nil
            needsDisplay = true
            requestSizeReport()
        }
    }
    private var currentRevision: UInt64? = nil
    func present(_ frame: ScreenSnapshot?, revision: UInt64) {
        guard currentRevision != revision else { return }
        currentRevision = revision
        terminalFrame = frame
    }
    private var terminalFrame: ScreenSnapshot? {
        didSet {
            if hoveredLink != nil {
                hoveredLink = nil
                lastHoverCell = nil
                NSCursor.arrow.set()
            }
            needsDisplay = true
        }
    }
    var copyOnSelection = true
    var cursorBlink = true
    var cursorShape = "bar"
    var opacity = 1.0 { didSet { if opacity != oldValue { needsDisplay = true } } }
    var fontName = "system" { didSet { if fontName != oldValue { rebuildAtlas() } } }
    var fontSize: CGFloat = 13 { didSet { if fontSize != oldValue { rebuildAtlas() } } }
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var atlas: GlyphAtlas?
    private var cellWidth: CGFloat = 9
    private var cellHeight: CGFloat = 18
    private var phase = true
    private var timer: Timer?
    private var sizeSync = NiaTerminalSizeSync()
    private var sizeReportPending = false
    private var atlasScale: CGFloat = 0
    private enum SelectionMode: Equatable { case linear, rectangular }
    private var selectionMode: SelectionMode = .linear
    private var selectionStart: (Int, Int)?
    private var selectionEnd: (Int, Int)?
    private var mouseDownPoint: NSPoint?
    // Link highlighting only runs on pointer movement, never during PTY polling.
    private struct HoveredLink {
        let url: URL
        let row: Int
        let firstColumn: Int
        let lastColumn: Int
    }
    private var hoveredLink: HoveredLink?
    private var lastHoverCell: (Int, Int)?
    private var mouseTrackingArea: NSTrackingArea?
    // Escape is delayed very briefly so two presses can clear the editable shell line.
    // Single Escape remains available for vim, completion menus and other TUI apps.
    private var pendingEscape: DispatchWorkItem?
    private var lastEscapeAt: TimeInterval = 0
    private let doubleEscapeInterval: TimeInterval = 0.32
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(frame: CGRect) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = true
        layer?.isOpaque = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0.065,0.081,0.105,1)
        delegate = self
        registerForDraggedTypes([.fileURL])
        if let device {
            queue = device.makeCommandQueue()
            do {
                let library = try device.makeLibrary(source: niaShader, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
                descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
                descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
                let blend = descriptor.colorAttachments[0]!
                blend.isBlendingEnabled = true
                blend.sourceRGBBlendFactor = .sourceAlpha
                blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
                blend.sourceAlphaBlendFactor = .one
                blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch { NSLog("Nia Metal pipeline failed: %@", String(describing: error)) }
        }
        rebuildAtlas()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea { removeTrackingArea(mouseTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateLinkHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateLinkHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        lastHoverCell = nil
        if hoveredLink != nil { hoveredLink = nil; needsDisplay = true }
        NSCursor.arrow.set()
    }

    private func updateLinkHover(at point: NSPoint) {
        guard bounds.contains(point) else {
            lastHoverCell = nil
            if hoveredLink != nil { hoveredLink = nil; needsDisplay = true }
            NSCursor.arrow.set()
            return
        }
        let location = cell(at: point)
        if let old = lastHoverCell, old == location { return }
        lastHoverCell = location
        let candidate = webLink(at: location)
        let changed = candidate?.url != hoveredLink?.url ||
            candidate?.row != hoveredLink?.row ||
            candidate?.firstColumn != hoveredLink?.firstColumn ||
            candidate?.lastColumn != hoveredLink?.lastColumn
        hoveredLink = candidate
        if candidate != nil { NSCursor.pointingHand.set() }
        else { NSCursor.arrow.set() }
        if changed { needsDisplay = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sizeSync.invalidate()
        if window != nil {
            updateBackingScale()
            timer?.invalidate()
            let t = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.phase.toggle()
                if self.cursorBlink { self.needsDisplay = true }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
                self.requestSizeReport()
            }
        } else { timer?.invalidate(); timer = nil }
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
        requestSizeReport()
    }
    private func updateBackingScale() {
        guard let window, window.backingScaleFactor != atlasScale else { return }
        rebuildAtlas()
    }
    private func rebuildAtlas() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        atlasScale = scale
        let requested = fontName == "system" ? nil : NSFont(name: fontName, size: fontSize * scale)
        // Fall back safely if the selected font was uninstalled between launches.
        let font = (requested?.isFixedPitch == true ? requested : nil)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize * scale, weight: .regular)
        cellWidth = ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
        cellHeight = ceil(font.ascender - font.descender + font.leading) + 2
        if let device { atlas = GlyphAtlas(device: device, font: CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil),
                                           cellWidth: Int(cellWidth), cellHeight: Int(cellHeight)) }
        sizeSync.invalidate()
        requestSizeReport()
        needsDisplay = true
    }
    override func layout() { super.layout(); requestSizeReport() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        requestSizeReport()
    }
    func requestSizeReport() {
        guard !sizeReportPending else { return }
        sizeReportPending = true
        // Read the final bounds and CURRENT session/callback after SwiftUI's
        // update/layout pass. Calling the model from updateNSView synchronously
        // publishes a new screen while SwiftUI is still updating the old one.
        // Coalesce only this run-loop turn; do not debounce a live resize.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizeReportPending = false
            self.reportSize()
        }
    }
    private func reportSize() {
        guard window != nil, !isHiddenOrHasHiddenAncestor,
              let session = activeSessionID, let onResize else { return }
        let pixels = convertToBacking(bounds).size
        guard let size = NiaTerminalGrid.fitting(
            width: Double(pixels.width), height: Double(pixels.height),
            cellWidth: Double(cellWidth), cellHeight: Double(cellHeight)) else { return }
        let observed = terminalFrame.flatMap { frame -> NiaTerminalGrid? in
            guard frame.session_id == session else { return nil }
            return NiaTerminalGrid(rows: Int(frame.rows), columns: Int(frame.cols))
        }
        sizeSync.report(size, session: session, observedSize: observed, resize: onResize)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { requestSizeReport() }

    private func rowIsVisuallyBlank(_ row: Int, in frame: ScreenSnapshot) -> Bool {
        guard row >= 0 && row < frame.cells.count else { return true }
        return frame.cells[row].allSatisfy { cell in
            let trimmed = cell.t.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty && !cell.continuation
        }
    }
    private func resolvedCursorRow(in frame: ScreenSnapshot) -> Int {
        guard !frame.cells.isEmpty else { return 0 }
        var row = min(max(Int(frame.cursor_row), 0), frame.cells.count - 1)
        if rowIsVisuallyBlank(row, in: frame) {
            var probe = row
            var steps = 0
            while probe > 0 && steps < 2 && rowIsVisuallyBlank(probe, in: frame) {
                probe -= 1
                steps += 1
            }
            if !rowIsVisuallyBlank(probe, in: frame) { row = probe }
        }
        return row
    }

    private func quad(_ vertices: inout [Float], x: Float,y: Float,w: Float,h: Float,
                      uv: GlyphUV?, color: SIMD4<Float>) {
        let u0 = uv?.u0 ?? 0, v0 = uv?.v0 ?? 0, u1 = uv?.u1 ?? 0, v1 = uv?.v1 ?? 0
        let mode: Float = uv == nil ? 0 : 1
        func point(_ px: Float,_ py: Float,_ u: Float,_ v: Float) {
            vertices.append(contentsOf: [px,py,u,v,color.x,color.y,color.z,color.w,mode])
        }
        point(x,y,u0,v0); point(x+w,y,u1,v0); point(x,y+h,u0,v1)
        point(x+w,y,u1,v0); point(x+w,y+h,u1,v1); point(x,y+h,u0,v1)
    }
    func draw(in view: MTKView) {
        guard let device, let pipeline, let queue, let atlas,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua,.aqua]) == .darkAqua
        let defaultBG = palette(-1, foreground: false, dark: dark)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(defaultBG.x),
            green: Double(defaultBG.y), blue: Double(defaultBG.z), alpha: opacity)
        var bg: [Float] = [], fg: [Float] = []
        let scale: Float = Float(window?.backingScaleFactor ?? 2)
        let cw = Float(cellWidth), ch = Float(cellHeight)
        if let f = terminalFrame {
            for (r,line) in f.cells.enumerated() {
                for (c,cell) in line.enumerated() {
                    let x = Float(c)*cw, y = Float(r)*ch
                    var front = palette(cell.fg, foreground: true, dark: dark)
                    var back = palette(cell.bg, foreground: false, dark: dark)
                    if cell.flags & 16 != 0 { swap(&front,&back) }
                    if cell.flags & 2 != 0 { front.w *= 0.55 }
                    let hovering = hoveredLink.map { link in
                        r == link.row && c >= link.firstColumn && c <= link.lastColumn
                    } ?? false
                    if hovering {
                        // Accent-colored underline signals the click target.
                        // Only draw these two quads on the hovered text cells.
                        front = dark ? SIMD4(0.49,0.73,1.0,1.0) : SIMD4(0.10,0.37,0.83,1.0)
                    }
                    if selectionContains(r,c) { back = SIMD4(0.31,0.49,0.76,1) }
                    if cell.bg != -1 || cell.flags & 16 != 0 || selectionContains(r,c) {
                        quad(&bg,x:x,y:y,w:cw,h:ch,uv:nil,color:back)
                    }
                    if !cell.continuation && !cell.t.isEmpty && cell.t != " " {
                        if let u = atlas.glyph(cell.t, wide: cell.wide) {
                            quad(&fg,x:x,y:y,w:cell.wide ? cw*2 : cw,h:ch,uv:u,color:front)
                        }
                    }
                    if cell.flags & 8 != 0 || hovering {
                        quad(&fg,x:x,y:y+ch-2,w:cw,h:1.5,uv:nil,color:front)
                    }
                }
            }
            if f.scrollback_offset == 0 && f.cursor_visible && (phase || !cursorBlink) {
                let cursorRow = resolvedCursorRow(in: f)
                let x = Float(f.cursor_col)*cw, y = Float(cursorRow)*ch
                let cursorColor = palette(-1,foreground:true,dark:dark)
                switch cursorShape {
                case "block": quad(&fg,x:x,y:y,w:cw,h:ch,uv:nil,color:SIMD4(cursorColor.x,cursorColor.y,cursorColor.z,0.38))
                case "underline": quad(&fg,x:x,y:y+ch-2,w:cw,h:2,uv:nil,color:cursorColor)
                default: quad(&fg,x:x,y:y,w:max(2,scale),h:ch,uv:nil,color:cursorColor)
                }
            }
        }
        atlas.uploadIfNeeded()
        guard let cmd = queue.makeCommandBuffer(), let encoder = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        var viewport = SIMD2<Float>(Float(drawableSize.width),Float(drawableSize.height))
        encoder.setVertexBytes(&viewport,length:MemoryLayout<SIMD2<Float>>.stride,index:1)
        for vertices in [bg,fg] where !vertices.isEmpty {
            vertices.withUnsafeBytes { bytes in
                guard let ptr = bytes.baseAddress,
                      let buffer = device.makeBuffer(bytes:ptr,length:bytes.count,options:.storageModeShared) else { return }
                encoder.setVertexBuffer(buffer,offset:0,index:0)
                encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:vertices.count/9)
            }
        }
        encoder.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func cell(at point: NSPoint) -> (Int,Int) {
        let scale = window?.backingScaleFactor ?? 2
        return (max(0,Int(point.y * scale / cellHeight)),max(0,Int(point.x * scale / cellWidth)))
    }
    private func selectionContains(_ row: Int, _ col: Int) -> Bool {
        guard let start = selectionStart, let end = selectionEnd else { return false }
        switch selectionMode {
        case .rectangular:
            return row >= min(start.0, end.0) && row <= max(start.0, end.0)
                && col >= min(start.1, end.1) && col <= max(start.1, end.1)
        case .linear:
            let a = (start.0 < end.0 || (start.0 == end.0 && start.1 <= end.1)) ? start : end
            let b = (start.0 < end.0 || (start.0 == end.0 && start.1 <= end.1)) ? end : start
            return (row > a.0 || (row == a.0 && col >= a.1)) &&
                   (row < b.0 || (row == b.0 && col <= b.1))
        }
    }
    private func wordCharacter(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
    }
    // Smart links: only inspect the clicked visible row, never scan scrollback
    // on a render tick. This adds no background worker and no allocations on
    // the steady-state Metal drawing path.
    private static let webLinkPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"']+"#,
        options: [.caseInsensitive]
    )
    private var contextualURL: URL?

    private func webURL(at location: (Int, Int)) -> URL? {
        webLink(at: location)?.url
    }

    private func webLink(at location: (Int, Int)) -> HoveredLink? {
        guard let frame = terminalFrame,
              frame.cells.indices.contains(location.0),
              frame.cells[location.0].indices.contains(location.1) else { return nil }
        let cells = frame.cells[location.0]
        var value = ""
        var columns: [Int] = []
        for (column, cell) in cells.enumerated() {
            if cell.continuation { continue }
            let glyph = cell.t.isEmpty ? " " : cell.t
            value += glyph
            for _ in glyph.utf16 { columns.append(column) }
        }
        let ns = value as NSString
        guard ns.length > 0 else { return nil }
        let matches = Self.webLinkPattern.matches(
            in: value, range: NSRange(location: 0, length: ns.length)
        )
        for match in matches {
            let first = match.range.location
            let last = first + match.range.length
            guard first < columns.count, last <= columns.count,
                  columns[first] <= location.1,
                  location.1 <= columns[last - 1] else { continue }
            var candidate = ns.substring(with: match.range)
            while let lastChar = candidate.last, ".,;:!?)]}".contains(lastChar) {
                candidate.removeLast()
            }
            guard !candidate.isEmpty, candidate.count <= 2048,
                  let url = URL(string: candidate),
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { return nil }
            let actualEnd = first + (candidate as NSString).length
            guard actualEnd <= columns.count, actualEnd > first,
                  location.1 <= columns[actualEnd - 1] else { return nil }
            return HoveredLink(url: url, row: location.0,
                firstColumn: columns[first], lastColumn: columns[actualEnd - 1])
        }
        return nil
    }

    @objc private func openContextURL(_ sender: Any?) {
        if let url = contextualURL { NSWorkspace.shared.open(url) }
    }

    @objc private func copyContextURL(_ sender: Any?) {
        guard let url = contextualURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func selectWord(at location: (Int, Int)) {
        guard let f = terminalFrame, f.cells.indices.contains(location.0),
              f.cells[location.0].indices.contains(location.1) else { return }
        let line = f.cells[location.0]
        var col = location.1
        if line[col].continuation && col > 0 { col -= 1 }
        guard !line[col].t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let isWord = wordCharacter(line[col].t)
        var first = col, last = col
        while first > 0 && !line[first-1].continuation &&
              wordCharacter(line[first-1].t) == isWord &&
              !line[first-1].t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            first -= 1
        }
        while last + 1 < line.count &&
              (line[last+1].continuation || (wordCharacter(line[last+1].t) == isWord &&
               !line[last+1].t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) {
            last += 1
        }
        selectionMode = .linear
        selectionStart = (location.0, first)
        selectionEnd = (location.0, last)
        needsDisplay = true
        if copyOnSelection { copy(nil) }
    }
    private func selectLine(at row: Int) {
        guard let f = terminalFrame, f.cells.indices.contains(row),
              !f.cells[row].isEmpty else { return }
        selectionMode = .linear
        selectionStart = (row, 0)
        selectionEnd = (row, f.cells[row].count-1)
        needsDisplay = true
        if copyOnSelection { copy(nil) }
    }
    override func scrollWheel(with event: NSEvent) {
        // Three lines per wheel notch, continuous for trackpads; retain partial deltas.
        let motion = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.20 : 3.0)
        scrollRemainder += motion
        let lines = Int(scrollRemainder.rounded(.towardZero))
        if lines != 0 { scrollRemainder -= CGFloat(lines); onScroll?(lines) }
    }
    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let pasteboard = sender.draggingPasteboard
        return (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []).filter { $0.isFileURL }
    }
    private func shellQuotedPath(_ path: String) -> String {
        // POSIX single quoting covers spaces, apostrophes, dollar signs,
        // backticks and newlines without invoking the shell.
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let allowed = !fileURLs(from: sender).isEmpty
        hoveringFileDrop = allowed
        return allowed ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        hoveringFileDrop = false
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(from: sender).isEmpty
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hoveringFileDrop = false }
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        // Input only: deliberately no carriage return or newline.
        let inserted = urls.map { shellQuotedPath($0.path) }.joined(separator: " ") + " "
        window?.makeFirstResponder(self)
        onFocus?()
        onBytes?(Array(inserted.utf8))
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // Focus is assigned synchronously to the view the user clicked.
        // Inform SwiftUI only after the AppKit responder has been updated.
        window?.makeFirstResponder(self)
        onFocus?()
        let point = convert(event.locationInWindow, from: nil)
        // Explicit Cmd-click opens HTTP(S) links without touching the PTY.
        if event.modifierFlags.contains(.command),
           let url = webURL(at: cell(at: point)) {
            NSWorkspace.shared.open(url)
            mouseDownPoint = nil
            return
        }
        mouseDownPoint = point
        selectionStart = nil
        selectionEnd = nil
        selectionMode = event.modifierFlags.contains(.shift) ? .rectangular : .linear
        if event.clickCount >= 3 {
            selectLine(at: cell(at: point).0)
            mouseDownPoint = nil
        } else if event.clickCount == 2 {
            selectWord(at: cell(at: point))
            mouseDownPoint = nil
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard selectionStart != nil || hypot(current.x - origin.x, current.y - origin.y) >= 4 else { return }
        if selectionStart == nil { selectionStart = cell(at: origin) }
        selectionEnd = cell(at: current)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        if copyOnSelection, let start = selectionStart, let end = selectionEnd,
           (start.0 != end.0 || start.1 != end.1) { copy(nil) }
        else if selectionStart == nil { selectionEnd = nil; needsDisplay = true }
    }
    @objc func copy(_ sender: Any?) {
        guard let f = terminalFrame, !f.cells.isEmpty,
              let start = selectionStart, let end = selectionEnd else { return }
        let firstRow = max(0, min(start.0, end.0))
        let lastRow = min(f.cells.count-1, max(start.0, end.0))
        guard firstRow <= lastRow else { return }
        let a = (start.0 < end.0 || (start.0 == end.0 && start.1 <= end.1)) ? start : end
        let b = (start.0 < end.0 || (start.0 == end.0 && start.1 <= end.1)) ? end : start
        var result: [String] = []
        for r in firstRow...lastRow {
            let line = f.cells[r]
            guard !line.isEmpty else { result.append(""); continue }
            let first: Int, last: Int
            switch selectionMode {
            case .rectangular:
                first = min(max(0, min(start.1, end.1)), line.count)
                last = min(max(0, max(start.1, end.1)), line.count - 1)
            case .linear:
                first = r == a.0 ? min(max(0, a.1), line.count) : 0
                last = r == b.0 ? min(max(0, b.1), line.count - 1) : line.count - 1
            }
            if first <= last {
                let value = line[first...last].filter { !$0.continuation }
                    .map { $0.t.isEmpty ? " " : $0.t }.joined()
                // Rectangular selection must retain spaces inside the selected columns.
                result.append(selectionMode == .rectangular ? value :
                    value.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression))
            } else { result.append("") }
        }
        guard !result.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.joined(separator: "\n"), forType: .string)
    }
    @objc func paste(_ sender: Any?) {
        // Never steal focus from another pane to paste into this one.
        guard window?.firstResponder === self,
              let text = NSPasteboard.general.string(forType: .string) else { return }
        onBytes?(Array(text.replacingOccurrences(of: "\r\n", with: "\n").utf8))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit may ask every subview whether it handles a key equivalent.
        // Only the actual first responder may consume Cmd+C / Cmd+V.
        guard window?.firstResponder === self else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) && !mods.contains(.option) && !mods.contains(.control),
           let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "c" { copy(nil); return true }
            if key == "v" { paste(nil); return true }
            if key == "a" {
                if let f = terminalFrame {
                    selectionMode = .linear
                    selectionStart = (0,0)
                    selectionEnd = (max(0,Int(f.rows)-1), max(0,Int(f.cols)-1))
                    needsDisplay = true
                }
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    // MARK: - Quick insert and context menu

    private func secureRandomBytes(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!)
        }
        guard result == errSecSuccess else { return nil }
        return bytes
    }

    private func secureRandomIndex(upperBound: Int) -> Int? {
        guard upperBound > 0 && upperBound <= 256 else { return nil }
        let limit = 256 - (256 % upperBound)
        while true {
            guard let byte = secureRandomBytes(1)?.first else { return nil }
            if Int(byte) < limit { return Int(byte) % upperBound }
        }
    }

    private func securePassword(length: Int = 18) -> String? {
        // Randomness comes from SecRandomCopyBytes, using rejection sampling
        // to avoid modulo bias. Include at least one character from each group.
        let groups = [
            Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
            Array("abcdefghijklmnopqrstuvwxyz"),
            Array("0123456789"),
            Array("/()=?¿.:,-_%$#·")
        ]
        let alphabet = groups.flatMap { $0 }
        guard length >= groups.count else { return nil }
        var password: [Character] = []

        for group in groups {
            guard let i = secureRandomIndex(upperBound: group.count) else { return nil }
            password.append(group[i])
        }
        while password.count < length {
            guard let i = secureRandomIndex(upperBound: alphabet.count) else { return nil }
            password.append(alphabet[i])
        }
        // Fisher-Yates shuffle with cryptographically secure unbiased indices.
        if password.count > 1 {
            for i in stride(from: password.count - 1, through: 1, by: -1) {
                guard let j = secureRandomIndex(upperBound: i + 1) else { return nil }
                password.swapAt(i, j)
            }
        }
        return String(password)
    }

    private func quoteForShell(_ value: String) -> String {
        // POSIX-shell safe single-quoted argument; no quote is currently
        // present in the generated alphabet, but handle it for future changes.
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func insertGenerated(_ value: String) {
        // Right-click may open a native menu without taking keyboard focus.
        // Always route insertion through this view's session-specific callback.
        window?.makeFirstResponder(self)
        onFocus?()
        onBytes?(Array(value.utf8))
    }

    @objc private func insertUUID(_ sender: Any?) {
        insertGenerated(UUID().uuidString.lowercased())
    }
    @objc private func insertSHA1(_ sender: Any?) {
        guard let bytes = secureRandomBytes(64) else { NSSound.beep(); return }
        let digest = Insecure.SHA1.hash(data: Data(bytes))
        insertGenerated(digest.map { String(format: "%02x", $0) }.joined())
    }
    @objc private func insertMD5(_ sender: Any?) {
        guard let bytes = secureRandomBytes(64) else { NSSound.beep(); return }
        let digest = Insecure.MD5.hash(data: Data(bytes))
        insertGenerated(digest.map { String(format: "%02x", $0) }.joined())
    }
    @objc private func insertPassword(_ sender: Any?) {
        guard let password = securePassword() else { NSSound.beep(); return }
        // This is inserted as a shell argument: special characters remain
        // literal when the shell evaluates the command line.
        insertGenerated(quoteForShell(password))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        onFocus?()
        let menu = NSMenu(title: NiaL10n.string("Insertar en terminal"))
        contextualURL = webURL(at: cell(at: convert(event.locationInWindow, from: nil)))
        if contextualURL != nil {
            let open = NSMenuItem(title: NiaL10n.string("Abrir enlace"), action: #selector(openContextURL(_:)), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            let copy = NSMenuItem(title: NiaL10n.string("Copiar enlace"), action: #selector(copyContextURL(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
            menu.addItem(.separator())
        }
        func item(_ title: String, _ action: Selector) {
            let entry = NSMenuItem(title: NiaL10n.string(title), action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        item("Generar UUID v4", #selector(insertUUID(_:)))
        item("Generar SHA-1 aleatorio", #selector(insertSHA1(_:)))
        item("Generar MD5 aleatorio", #selector(insertMD5(_:)))
        menu.addItem(.separator())
        item("Generar contraseña segura (18 caracteres)", #selector(insertPassword(_:)))
        return menu
    }

    private func flushPendingEscape() {
        if pendingEscape != nil {
            pendingEscape?.cancel()
            pendingEscape = nil
            onBytes?([27])
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            flushPendingEscape()
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 && !flags.contains(.control) && !flags.contains(.option) {
            let now = ProcessInfo.processInfo.systemUptime
            if pendingEscape != nil && now - lastEscapeAt <= doubleEscapeInterval {
                pendingEscape?.cancel()
                pendingEscape = nil
                // Default Zsh/Bash emacs bindings: Ctrl+A then Ctrl+K clears
                // the entire editable line, without executing it.
                onBytes?([1, 11])
            } else {
                flushPendingEscape()
                lastEscapeAt = now
                let task = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingEscape = nil
                    // Do not send a delayed Escape to a panel that lost focus.
                    if self.window?.firstResponder === self { self.onBytes?([27]) }
                }
                pendingEscape = task
                DispatchQueue.main.asyncAfter(deadline: .now() + doubleEscapeInterval, execute: task)
            }
            return
        }
        flushPendingEscape()
        let codes: [UInt16:[UInt8]] = [36:[13],76:[13],48:[9],51:[127],
            123:[27,91,68],124:[27,91,67],125:[27,91,66],126:[27,91,65],
            115:[27,91,72],119:[27,91,70],117:[27,91,51,126]]
        if let code = codes[event.keyCode] { onBytes?(code); return }
        if flags.contains(.control), let c = event.charactersIgnoringModifiers?.lowercased().utf8.first,
            c >= 97 && c <= 122 { onBytes?([c-96]); return }
        if let text = event.characters, !text.isEmpty { onBytes?(Array(text.utf8)) }
    }
}

struct TerminalPanel: NSViewRepresentable {
    let sessionID: String
    let frame: ScreenSnapshot?
    let revision: UInt64
    let cursorBlink: Bool
    let cursorShape: String
    let opacity: Double
    let fontName: String
    let fontSize: Double
    let focusEpoch: UInt64
    let onFocus: () -> Void
    let onInput: ([UInt8]) -> Void
    let onResize: (Int,Int) -> Bool
    let onScroll: (Int) -> Void

    func makeNSView(context: Context) -> NiaMetalView {
        let view = NiaMetalView(frame: .zero)
        view.onBytes = onInput
        view.onResize = onResize
        view.onScroll = onScroll
        view.onFocus = onFocus
        view.activeSessionID = sessionID
        return view
    }
    func updateNSView(_ view: NiaMetalView, context: Context) {
        view.onBytes = onInput
        view.onResize = onResize
        view.onScroll = onScroll
        view.onFocus = onFocus
        if focusEpoch > 0 && view.focusEpochSeen != focusEpoch {
            view.focusEpochSeen = focusEpoch
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
        view.activeSessionID = sessionID
        view.present(frame, revision: revision)
        view.cursorBlink = cursorBlink
        view.cursorShape = cursorShape
        view.opacity = opacity
        let defaults = UserDefaults.standard
        view.copyOnSelection = defaults.object(forKey:"nia.copyOnSelect") as? Bool ?? true
        view.fontName = fontName
        view.fontSize = CGFloat(fontSize)
        // Also revalidate when a PTY/snapshot changes without any NSView resize.
        view.requestSizeReport()
        // Rendering is triggered by a changed snapshot or cursor timer.
    }
}
