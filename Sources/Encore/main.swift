import AppKit
import ServiceManagement
import SwiftUI

// Test mode: Encore --state prints what Music is playing (checks the AppleScript side).
if CommandLine.arguments.contains("--state") {
    let done = DispatchSemaphore(value: 0)
    let music = MusicBridge()
    music.fetch { playing, _ in
        print(playing.map { "\($0.playing ? "playing" : "paused") \($0.title) — \($0.artist) \(Int($0.position))/\(Int($0.duration))s id \($0.id)" }
              ?? (MusicBridge.isRunning ? "Music has nothing playing" : "Music isn't running"))
        music.artwork { image in
            print("artwork: \(image.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "none")")
            done.signal()
        }
    }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

/// Test mode: Encore --snapshot <dir> renders the panel with stand-in tracks to PNGs.
@MainActor
func renderSnapshots(to dir: URL) {
    PanelBackground.flat = true
    let model = PlayerModel()
    let art = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
        NSGradient(starting: NSColor(red: 0.95, green: 0.35, blue: 0.4, alpha: 1),
                   ending: NSColor(red: 0.35, green: 0.2, blue: 0.75, alpha: 1))!.draw(in: rect, angle: -45)
        return true
    }
    func save(_ name: String) {
        let renderer = ImageRenderer(content: EncoreView(model: model).padding(20).background(Color(white: 0.45)))
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("render failed: \(name)")
            return
        }
        let url = dir.appendingPathComponent(name + ".png")
        try? data.write(to: url)
        print(url.path)
    }
    model.now = NowPlaying(id: "1", title: "Midnight City", artist: "M83", duration: 243, position: 71, playing: true)
    model.position = 71
    model.artwork = art
    save("1-playing")
    model.now = NowPlaying(id: "2", title: "A Really Long Song Title That Has To Be Cut Off", artist: "Someone & Another Person feat. A Third",
                           duration: 3725, position: 12, playing: false)
    model.position = 12
    model.artwork = nil
    save("2-paused-long")
    model.scrub = 0.62
    save("3-scrubbing")
    model.scrub = nil
    model.artwork = art
    model.pinned = true
    model.hovering = true
    save("4-pinned-hover")
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
    MainActor.assumeIsolated { renderSnapshots(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
    exit(0)
}

/// Shows the panel above Music's Dock icon while the pointer is on the icon or the panel.
@MainActor
final class Coordinator {
    let model = PlayerModel()
    private let dock = DockWatcher()
    private lazy var panel = EncorePanel(model: model)
    private var timer: Timer?
    private var shown = false
    private var trusted = false
    private var iconFrame: NSRect?
    private var hoverSince: Date?
    private var askedThisHover = false
    private var leftAt: Date?
    private var tickCount = 0
    private var previewing = false
    /// Left somewhere with ⌘ held: stays put and stops following the Dock hover.
    private var pinned = false
    /// Panel origin and pointer where the current drag started.
    private var dragFrom: (origin: NSPoint, mouse: NSPoint)?

    func start() {
        model.onDrag = { [weak self] translation, ended in self?.drag(translation, ended: ended) }
        model.onClose = { [weak self] in self?.hide() }
        trusted = dock.trusted
        if !trusted { dock.requestAccess() }
        // Music posts this on every play, pause and track change.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                if self.shown { self.model.refresh() }
            }
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.write("Encore started; accessibility: \(trusted), Music running: \(MusicBridge.isRunning)")
    }

    /// Shows the panel in the middle of the screen with live data, for checking the look (Encore --preview).
    func preview() {
        previewing = true
        guard let screen = NSScreen.main?.visibleFrame else { return }
        model.refresh { [self] in
            panel.setFrameOrigin(NSPoint(x: screen.midX - EncoreView.size.width / 2, y: screen.midY))
            shown = true
            appear()
        }
    }

    /// The card follows the pointer. Let go with ⌘ held and it stays there; otherwise it goes away.
    private func drag(_ translation: CGSize, ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if ended {
            guard dragFrom != nil else { return }
            dragFrom = nil
            if commandHeld() { pin() } else { hide() }
            return
        }
        // The gesture only starts after a few points of movement; count those too (SwiftUI's y points down).
        let from = dragFrom ?? (panel.frame.origin, NSPoint(x: mouse.x - translation.width, y: mouse.y + translation.height))
        dragFrom = from
        leftAt = nil
        panel.setFrameOrigin(NSPoint(x: from.origin.x + mouse.x - from.mouse.x, y: from.origin.y + mouse.y - from.mouse.y))
        dragHint()
    }

    /// Dimmed while a drop would dismiss the card, solid while ⌘ is held.
    private func dragHint() {
        let alpha: CGFloat = commandHeld() ? 1 : 0.55
        if panel.alphaValue != alpha { panel.animator().alphaValue = alpha }
    }

    /// ⌘ as the mouse event being handled saw it, or the keyboard right now.
    private func commandHeld() -> Bool {
        if let event = NSApp.currentEvent, [.leftMouseDragged, .leftMouseUp].contains(event.type),
           event.modifierFlags.contains(.command) { return true }
        return NSEvent.modifierFlags.contains(.command)
    }

    private func pin() {
        pinned = true
        model.pinned = true
        panel.level = .statusBar
        // Keep the whole card on the screen it was dropped on.
        let mouse = NSEvent.mouseLocation
        if let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            var frame = panel.frame
            frame.origin.x = min(max(frame.minX, screen.minX + 8), screen.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, screen.minY + 8), screen.maxY - frame.height - 8)
            panel.setFrame(frame.integral, display: true, animate: true)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        Log.write("card pinned at \(Int(panel.frame.minX)),\(Int(panel.frame.minY))")
    }

    private func tick() {
        tickCount += 1
        if dragFrom != nil {
            // A gesture that never reports its end (e.g. cancelled by the system) still finishes here.
            if NSEvent.pressedMouseButtons & 1 == 0 { drag(.zero, ended: true) } else { dragHint() }
        }
        if pinned {
            let over = panel.frame.contains(NSEvent.mouseLocation)
            if model.hovering != over { model.hovering = over }
        }
        if previewing {
            model.tick()
            if tickCount % 20 == 0 { model.refresh() }
            return
        }
        if !trusted {
            if tickCount % 40 == 0, dock.trusted {
                trusted = true
                Log.write("accessibility granted")
            }
            return
        }

        var icon = dock.musicIconUnderPointer()
        if icon != nil && !MusicBridge.isRunning { icon = nil }

        if pinned || dragFrom != nil {
            // Off the Dock's leash: neither hovering the icon nor leaving the card moves or hides it.
            leftAt = nil
        } else if let icon {
            iconFrame = icon
            leftAt = nil
            if shown {
                place()
            } else {
                if hoverSince == nil { hoverSince = Date() }
                // A short dwell so sweeping across the Dock doesn't flash the panel; one read of Music per hover.
                if !askedThisHover, Date().timeIntervalSince(hoverSince!) >= 0.12 {
                    askedThisHover = true
                    model.refresh { [weak self] in
                        guard let self, hoverSince != nil, model.now != nil else { return }
                        show()
                    }
                }
            }
        } else {
            hoverSince = nil
            if shown {
                if keepOpen() {
                    leftAt = nil
                } else if let leftAt {
                    if Date().timeIntervalSince(leftAt) > 0.3 { hide() }
                } else {
                    leftAt = Date()
                }
            } else {
                askedThisHover = false
            }
        }

        if shown {
            if model.now == nil { hide(); return }
            model.tick()
            if tickCount % 20 == 0 { model.refresh() }
        }
    }

    /// True while the pointer is on the panel, crossing the gap between icon and panel, or dragging the timeline.
    private func keepOpen() -> Bool {
        if model.scrub != nil { return true }
        let mouse = NSEvent.mouseLocation
        let card = panel.frame
        if card.insetBy(dx: -6, dy: -6).contains(mouse) { return true }
        guard let icon = iconFrame else { return false }
        let gap: NSRect
        switch dock.edge {
        case .bottom: gap = NSRect(x: card.minX, y: icon.maxY - 4, width: card.width, height: card.minY - icon.maxY + 8)
        case .left: gap = NSRect(x: icon.maxX - 4, y: card.minY, width: card.minX - icon.maxX + 8, height: card.height)
        case .right: gap = NSRect(x: card.maxX - 4, y: card.minY, width: icon.minX - card.maxX + 8, height: card.height)
        }
        return gap.contains(mouse)
    }

    private func show() {
        place()
        guard !shown else { return }
        shown = true
        leftAt = nil
        appear()
    }

    private func appear() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// Above the icon, clear of the Dock's own name label (or beside it for a side Dock).
    private func place() {
        guard let icon = iconFrame else { return }
        let size = EncoreView.size
        var origin: NSPoint
        switch dock.edge {
        case .bottom: origin = NSPoint(x: icon.midX - size.width / 2, y: icon.maxY + 44)
        case .left: origin = NSPoint(x: icon.maxX + 14, y: icon.midY - size.height / 2)
        case .right: origin = NSPoint(x: icon.minX - 14 - size.width, y: icon.midY - size.height / 2)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(icon) })?.frame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        }
        let frame = NSRect(origin: origin, size: size).integral
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
    }

    private func hide() {
        guard shown else { return }
        shown = false
        askedThisHover = false
        model.scrub = nil
        pinned = false
        model.pinned = false
        model.hovering = false
        dragFrom = nil
        panel.level = .popUpMenu
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            MainActor.assumeIsolated {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }
}

/// No menu bar icon: Encore runs invisibly. Opening it again from Applications shows a small dialog to quit or change login.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = Coordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didSetUpLogin") {
            defaults.set(true, forKey: "didSetUpLogin")
            setOpenAtLogin(true)
        }
        if CommandLine.arguments.contains("--preview") { coordinator.preview() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return false
    }

    private func showControls() {
        let loginOn = SMAppService.mainApp.status == .enabled
        let trusted = AXIsProcessTrusted()
        let alert = NSAlert()
        alert.messageText = "Encore is running"
        alert.informativeText = (trusted
            ? "Hover over Music in the Dock to see what's playing."
            : "Encore needs Accessibility access to see when you hover over the Dock. Turn it on in System Settings › Privacy & Security › Accessibility.")
            + "\n\nOpen at Login is \(loginOn ? "on" : "off")."
        alert.addButton(withTitle: trusted ? "OK" : "Open Accessibility Settings")
        alert.addButton(withTitle: loginOn ? "Turn Off Open at Login" : "Turn On Open at Login")
        alert.addButton(withTitle: "Quit Encore")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if !trusted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn: setOpenAtLogin(!loginOn)
        case .alertThirdButtonReturn: NSApp.terminate(nil)
        default: break
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.write("open at login: \(on)")
        } catch {
            Log.write("login item: \(error.localizedDescription)")
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
