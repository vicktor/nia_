// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI

struct NiaWindowPlacement: Codable, Equatable {
    var frame: CGRect

    var isValid: Bool {
        [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy { $0.isFinite }
            && frame.width > 0 && frame.height > 0
    }

    func fitted(to screens: [CGRect], minimumSize: CGSize) -> CGRect? {
        guard isValid else { return nil }
        let screens = screens.filter { NiaWindowPlacement(frame: $0).isValid }
        guard var screen = screens.first else { return nil }
        var largestIntersection: CGFloat = 0
        for candidate in screens {
            let overlap = frame.intersection(candidate)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > largestIntersection { screen = candidate; largestIntersection = area }
        }
        let width = min(max(frame.width, minimumSize.width), screen.width)
        let height = min(max(frame.height, minimumSize.height), screen.height)
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }
}

final class NiaWindowPlacementStore {
    private let defaults: UserDefaults
    private let lastKey = "nia.window.lastPlacement"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func placement(for id: String) -> NiaWindowPlacement? {
        read("nia.window.placement.\(id)")
    }
    var lastPlacement: NiaWindowPlacement? { read(lastKey) }

    private func read(_ key: String) -> NiaWindowPlacement? {
        guard let data = defaults.data(forKey: key),
              let placement = try? JSONDecoder().decode(NiaWindowPlacement.self, from: data),
              placement.isValid else { return nil }
        return placement
    }
    func save(_ placement: NiaWindowPlacement, for id: String) {
        guard placement.isValid, let data = try? JSONEncoder().encode(placement) else { return }
        for key in ["nia.window.placement.\(id)", lastKey] where defaults.data(forKey: key) != data {
            defaults.set(data, forKey: key)
        }
    }
}

@MainActor
final class NiaWindowPlacementController {
    private weak var window: NSWindow?
    private var windowID = ""
    private let store: NiaWindowPlacementStore
    private var observers: [NSObjectProtocol] = []
    private var restoring = false
    private var transitioningFullScreen = false

    init(store: NiaWindowPlacementStore = NiaWindowPlacementStore()) { self.store = store }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func attach(to window: NSWindow, id: String) {
        guard self.window !== window || windowID != id else { return }
        detach()
        self.window = window
        windowID = id
        restoring = true
        // Wait for SwiftUI's initial layout/defaultSize before applying the
        // saved frame. Later body updates must never move an existing window.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, self.windowID == id else { return }
            self.restore()
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeKeyNotification] {
            observe(name, object: window) { $0.save() }
        }
        observe(NSWindow.willCloseNotification, object: window) { $0.detach() }
        observe(NSApplication.willTerminateNotification, object: nil) { $0.save() }
        observe(NSWindow.willEnterFullScreenNotification, object: window) {
            $0.save()
            $0.transitioningFullScreen = true
        }
        observe(NSWindow.willExitFullScreenNotification, object: window) { $0.transitioningFullScreen = true }
        observe(NSWindow.didEnterFullScreenNotification, object: window) { $0.transitioningFullScreen = false }
        observe(NSWindow.didExitFullScreenNotification, object: window) {
            $0.transitioningFullScreen = false
            $0.save()
        }
    }

    private func observe(_ name: Notification.Name, object: AnyObject?, action: @escaping (NiaWindowPlacementController) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    private func restore() {
        guard let window else { return }
        defer { restoring = false }
        guard !window.styleMask.contains(.fullScreen) else { return }
        let placement = store.placement(for: windowID) ?? store.lastPlacement
        guard var placement else { return }
        // A fresh Cmd+N window inherits the size, but should not cover the
        // existing terminal exactly. Restored scene identities keep their frame.
        if store.placement(for: windowID) == nil,
           NSApp.windows.contains(where: { $0 !== window && $0.isVisible && $0.contentView?.containsNiaWindowPlacementHost == true }) {
            placement.frame.origin.x += 24
            placement.frame.origin.y -= 24
        }
        let screens = NSScreen.screens
        let ordered = ([window.screen ?? NSScreen.main].compactMap { $0 } + screens)
            .map(\.visibleFrame)
        let minimum = window.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 720, height: 420)).size
        if let frame = placement.fitted(to: ordered, minimumSize: minimum) {
            window.setFrame(frame, display: false)
        }
    }

    private func save() {
        guard let window, !restoring, !transitioningFullScreen,
              !window.styleMask.contains(.fullScreen), !window.isMiniaturized, !window.inLiveResize else { return }
        store.save(NiaWindowPlacement(frame: window.frame), for: windowID)
    }

    func detach() {
        save()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window = nil
        restoring = false
        transitioningFullScreen = false
    }
}

private extension NSView {
    var containsNiaWindowPlacementHost: Bool {
        self is NiaWindowPlacementHost || subviews.contains { $0.containsNiaWindowPlacementHost }
    }
}

private final class NiaWindowPlacementHost: NSView {
    let controller = NiaWindowPlacementController()
    var windowID = "" { didSet { attach() } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controller.detach() } else { attach() }
    }
    private func attach() {
        if let window, !windowID.isEmpty { controller.attach(to: window, id: windowID) }
    }
}

struct NiaWindowPlacementView: NSViewRepresentable {
    let windowID: String
    func makeNSView(context: Context) -> NSView {
        let view = NiaWindowPlacementHost(frame: .zero)
        view.windowID = windowID
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? NiaWindowPlacementHost)?.windowID = windowID
    }
    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? NiaWindowPlacementHost)?.controller.detach()
    }
}
