// clipboard-manager — a lightweight macOS clipboard history manager.
//
// Menu-bar only (LSUIElement). Watches NSPasteboard, keeps a capped
// de-duplicated history of text / styled-text / image clips, and binds
// one global hotkey — Hyper+V (⌃⇧⌥⌘V) — that opens a searchable
// Catppuccin command-palette panel; pick a clip and it's pasted into
// the app that was frontmost.
//
// Images are not held in memory: the full image is written once to a
// disk cache (keyed by content hash) and only a thumbnail + metadata
// is kept. The cache is bounded by the history ring, a total-size cap,
// and is wiped on launch and on quit. See design.md.

import ApplicationServices
import Carbon.HIToolbox
import Cocoa
import CoreGraphics
import CryptoKit

// MARK: - Tunables

enum Cfg {
    static let historyCap = 200
    static let imageByteCap = 256 * 1024 * 1024  // 256 MB on-disk cache ceiling
    static let pollInterval: TimeInterval = 0.5
    static let pasteKeystrokeDelay: TimeInterval = 0.20
    static let panelHotkeyID: UInt32 = 1
    static let thumbMax: CGFloat = 40
}

// MARK: - Catppuccin theme
//
// Latte in a light appearance, Frappé in a dark one. Each colour is a
// dynamic NSColor whose provider picks the palette from the resolved
// appearance, so "auto" (follow system) just works — nothing forces an
// appearance anywhere.

enum Cat {
    private static func rgb(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: a)
    }

    // light = Latte, dark = Frappé
    private static func dyn(_ light: UInt32, _ dark: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? rgb(dark, a) : rgb(light, a)
        }
    }

    static let base = dyn(0xeff1f5, 0x303446)
    static let crust = dyn(0xdce0e8, 0x232634)
    static let text = dyn(0x4c4f69, 0xc6d0f5)
    static let subtext0 = dyn(0x6c6f85, 0xa5adce)
    static let overlay1 = dyn(0x8c8fa1, 0x838ba7)
    static let surface0 = dyn(0xccd0da, 0x414559)
    static let accent = dyn(0x1e66f5, 0x8caaee)  // blue
    static let selFill = dyn(0x1e66f5, 0x8caaee, 0.20)
    static let selStroke = dyn(0x1e66f5, 0x8caaee, 0.55)
}

// Resolve a layer-backed view's theme colours under its *own*
// effective appearance, so light/dark stays correct.
extension NSView {
    func withTheme(_ body: () -> Void) {
        effectiveAppearance.performAsCurrentDrawingAppearance(body)
    }
}

// Flat rounded card — replaces a blurred panel so the Catppuccin
// colours aren't washed out by vibrancy.
final class ThemedCard: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        withTheme {
            layer?.backgroundColor = Cat.base.cgColor
            layer?.borderColor = Cat.surface0.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// 1-pt surface0 hairline.
final class ThemedHairline: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        withTheme { layer?.backgroundColor = Cat.surface0.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// Rounded, accent-tinted selection instead of the system highlight.
final class ThemedRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        withTheme {
            let r = bounds.insetBy(dx: 6, dy: 1)
            let p = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
            Cat.selFill.setFill()
            p.fill()
            Cat.selStroke.setStroke()
            p.lineWidth = 1
            p.stroke()
        }
    }
}

// Pasteboard types that mark a clip as "do not record".
let kConcealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
let kTransientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

// MARK: - Helpers

func sha256Hex(_ d: Data) -> String {
    SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

func humanBytes(_ n: Int) -> String {
    let u = ["B", "KB", "MB", "GB"]
    var v = Double(n), i = 0
    while v >= 1024, i < u.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, u[i])
}

func makeThumb(_ img: NSImage, max: CGFloat) -> NSImage {
    let s = img.size
    guard s.width > 0, s.height > 0 else { return img }
    let scale = Swift.min(max / s.width, max / s.height, 1)
    let ns = NSSize(width: s.width * scale, height: s.height * scale)
    let t = NSImage(size: ns)
    t.lockFocus()
    img.draw(in: NSRect(origin: .zero, size: ns),
             from: NSRect(origin: .zero, size: s),
             operation: .copy, fraction: 1)
    t.unlockFocus()
    return t
}

// MARK: - On-disk image cache

enum ImageCache {
    static let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipboard-manager-cache", isDirectory: true)

    // Wipe + recreate — called on launch (history is in-memory only,
    // so a fresh run starts with a fresh cache).
    static func reset() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
    }

    static func wipe() { try? FileManager.default.removeItem(at: dir) }

    static func store(_ data: Data, hash: String) -> URL {
        let url = dir.appendingPathComponent("\(hash).png")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
        }
        return url
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

// MARK: - Clip model

final class Clip {
    enum Kind {
        case text(String)
        case rich(rtf: Data, plain: String)
        case image(url: URL, thumb: NSImage, label: String, bytes: Int)
    }

    let kind: Kind
    let dedupKey: String
    let plain: String  // search / dedup / fallback text

    init(text s: String) {
        kind = .text(s)
        plain = s
        dedupKey = "t:" + s
    }

    init(rtf: Data, plain p: String) {
        kind = .rich(rtf: rtf, plain: p)
        plain = p
        dedupKey = "r:" + sha256Hex(rtf)
    }

    init(imageURL url: URL, hash: String, thumb: NSImage, label: String, bytes: Int) {
        kind = .image(url: url, thumb: thumb, label: label, bytes: bytes)
        plain = label
        dedupKey = "i:" + hash
    }
}

// MARK: - History

final class History {
    private(set) var items: [Clip] = []
    private var imageBytes = 0

    func add(_ c: Clip) {
        if let i = items.firstIndex(where: { $0.dedupKey == c.dedupKey }) {
            // Re-copy: promote the existing entry, discard the dup
            // (its backing file, if any, is identical and already
            // referenced by the kept entry).
            let existing = items.remove(at: i)
            items.insert(existing, at: 0)
            return
        }
        items.insert(c, at: 0)
        if case let .image(_, _, _, b) = c.kind { imageBytes += b }
        evict()
    }

    private func evict() {
        while items.count > Cfg.historyCap
            || (imageBytes > Cfg.imageByteCap && !items.isEmpty)
        {
            guard let last = items.popLast() else { break }
            drop(last)
        }
    }

    private func drop(_ c: Clip) {
        if case let .image(url, _, _, b) = c.kind {
            imageBytes -= b
            ImageCache.remove(url)
        }
    }

    func clear() {
        items.forEach(drop)
        items.removeAll()
        imageBytes = 0
    }
}

// MARK: - Styled rendering

// Render an RTF clip with its bold/italic preserved but recoloured to
// the theme text colour and normalised to one truncatable line — the
// source's own colours/sizes would clash with (or vanish on) the
// Catppuccin card.
func styledDisplay(_ rtf: Data) -> NSAttributedString {
    guard let a = NSAttributedString(rtf: rtf, documentAttributes: nil) else {
        return NSAttributedString(string: "")
    }
    let m = NSMutableAttributedString(attributedString: a)
    let full = NSRange(location: 0, length: m.length)
    let fm = NSFontManager.shared

    m.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
        var traits: NSFontTraitMask = []
        if let f = value as? NSFont {
            let t = fm.traits(of: f)
            if t.contains(.boldFontMask) { traits.insert(.boldFontMask) }
            if t.contains(.italicFontMask) { traits.insert(.italicFontMask) }
        }
        var f = NSFont.systemFont(ofSize: 13)
        if traits.contains(.boldFontMask) { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if traits.contains(.italicFontMask) { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        m.addAttribute(.font, value: f, range: range)
    }
    m.addAttribute(.foregroundColor, value: Cat.text, range: full)
    m.removeAttribute(.backgroundColor, range: full)

    // Equal-length substitutions keep attribute ranges intact.
    let s = m.mutableString
    s.replaceOccurrences(of: "\n", with: " ", options: [], range: full)
    s.replaceOccurrences(of: "\t", with: " ", options: [],
                         range: NSRange(location: 0, length: m.length))
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byTruncatingTail
    m.addAttribute(.paragraphStyle, value: para,
                   range: NSRange(location: 0, length: m.length))
    return m
}

// MARK: - Clip cell

final class ClipCell: NSView {
    static let id = NSUserInterfaceItemIdentifier("ClipCell")
    let thumb = NSImageView()
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = ClipCell.id
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.imageScaling = .scaleProportionallyDown
        thumb.setContentHuggingPriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.font = .systemFont(ofSize: 13)
        addSubview(thumb)
        addSubview(label)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: Cfg.thumbMax),
            thumb.heightAnchor.constraint(equalToConstant: 30),
            label.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ clip: Clip) {
        switch clip.kind {
        case let .text(s):
            thumb.image = nil
            label.attributedStringValue = NSAttributedString(
                string: s.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " "),
                attributes: [.foregroundColor: Cat.text,
                             .font: NSFont.systemFont(ofSize: 13)])
        case let .rich(rtf, _):
            thumb.image = nil
            label.attributedStringValue = styledDisplay(rtf)
        case let .image(_, t, lbl, _):
            thumb.image = t
            label.attributedStringValue = NSAttributedString(
                string: lbl,
                attributes: [.foregroundColor: Cat.subtext0,
                             .font: NSFont.systemFont(ofSize: 13)])
        }
    }
}

// MARK: - Keyable panel

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate
{
    static var shared: AppController?

    let history = History()

    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    private var hotkeyRef: EventHotKeyRef?

    // Searchable panel
    private var panel: KeyablePanel?
    private var searchField: NSTextField!
    private var table: NSTableView!
    private var filtered: [Clip] = []
    private var panelMonitor: Any?
    private var panelVisible = false

    // Transient notice HUD
    private var notice: NSWindow?
    private var noticeLabel: NSTextField!
    private var noticeToken = UUID()

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        ImageCache.reset()
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)

        setupStatusItem()
        startWatching()
        installHotkey()
    }

    func applicationWillTerminate(_ note: Notification) {
        ImageCache.wipe()
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            if let img = NSImage(systemSymbolName: "doc.on.clipboard",
                                 accessibilityDescription: "Clipboard Manager")?
                .withSymbolConfiguration(cfg) {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "⎘"
            }
            button.action = #selector(statusClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            showPanel()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let count = history.items.count
        let header = NSMenuItem(
            title: count == 1 ? "1 clip" : "\(count) clips", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(disabled("Open panel:  ⌃⇧⌥⌘V"))
        if !AXIsProcessTrusted() {
            menu.addItem(.separator())
            let warn = NSMenuItem(
                title: "Enable Accessibility to auto-paste…",
                action: #selector(openAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }
        menu.addItem(.separator())

        let clear = NSMenuItem(
            title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = count > 0
        menu.addItem(clear)

        let quit = NSMenuItem(
            title: "Quit Clipboard Manager", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func clearHistory() { history.clear() }

    @objc private func openAccessibility() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Pasteboard watcher

    private func startWatching() {
        let t = Timer.scheduledTimer(withTimeInterval: Cfg.pollInterval, repeats: true) {
            [weak self] _ in self?.pollPasteboard()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func pollPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        let types = pb.types ?? []
        if types.contains(kConcealedType) || types.contains(kTransientType) { return }

        // Priority: image → styled text → plain text.
        if let clip = imageClip(pb) ?? richClip(pb) ?? textClip(pb) {
            history.add(clip)
        }
    }

    private func imageClip(_ pb: NSPasteboard) -> Clip? {
        guard let img = NSImage(pasteboard: pb),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        let hash = sha256Hex(png)
        let url = ImageCache.store(png, hash: hash)
        let label = "Image · \(rep.pixelsWide)×\(rep.pixelsHigh) · \(humanBytes(png.count))"
        return Clip(imageURL: url, hash: hash,
                    thumb: makeThumb(img, max: Cfg.thumbMax),
                    label: label, bytes: png.count)
    }

    private func richClip(_ pb: NSPasteboard) -> Clip? {
        guard let rtf = pb.data(forType: .rtf),
              let a = NSAttributedString(rtf: rtf, documentAttributes: nil)
        else { return nil }
        let plain = a.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        return Clip(rtf: rtf, plain: plain)
    }

    private func textClip(_ pb: NSPasteboard) -> Clip? {
        guard let s = pb.string(forType: .string) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return Clip(text: t)
    }

    private func markPasteboardWritten() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: Hotkey

    private func installHotkey() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hk = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async { AppController.shared?.handleHotkey() }
                return noErr
            },
            1, &spec, nil, nil)

        // Hyper+V — Control+Shift+Option+Command+V. Pairs with a
        // Caps-Lock-as-Hyper remap (e.g. the sibling `caps` tool).
        let hkID = EventHotKeyID(signature: OSType(0x434C_4250 /* 'CLBP' */),
                                 id: Cfg.panelHotkeyID)
        let mods = UInt32(controlKey | shiftKey | optionKey | cmdKey)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V), mods, hkID, GetApplicationEventTarget(), 0, &hotkeyRef)
        if status != noErr {
            NSLog("clipboard-manager: RegisterEventHotKey failed (\(status)) — chord may be in use")
        }
    }

    func handleHotkey() { showPanel() }

    // MARK: Paste

    private func paste(_ clip: Clip) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch clip.kind {
        case let .text(s):
            pb.setString(s, forType: .string)
        case let .rich(rtf, plain):
            pb.setData(rtf, forType: .rtf)
            pb.setString(plain, forType: .string)
        case let .image(url, _, _, _):
            if let data = try? Data(contentsOf: url) {
                pb.setData(data, forType: .png)
                if let img = NSImage(data: data), let tiff = img.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
            }
        }
        markPasteboardWritten()

        guard AXIsProcessTrusted() else {
            showNotice("Enable Accessibility for auto-paste\n(clip is on the clipboard — ⌘V to paste)")
            NSLog("clipboard-manager: not Accessibility-trusted; clip left on pasteboard")
            return
        }

        // Relinquish our accessory app — macOS returns activation to
        // the app that was frontmost before us — then synthesize ⌘V.
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Cfg.pasteKeystrokeDelay) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let v = CGKeyCode(kVK_ANSI_V)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
            else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: Searchable panel

    private func showPanel() {
        if panel == nil { buildPanel() }
        guard let panel else { return }

        searchField.stringValue = ""
        applyFilter("")
        positionPanel(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        panelVisible = true

        // Remove any prior monitor first — re-showing the panel
        // without this stacks monitors, so each ↑/↓ moves twice.
        if let m = panelMonitor { NSEvent.removeMonitor(m); panelMonitor = nil }
        panelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] e in self?.panelKeyDown(e) ?? e
        }
    }

    private func positionPanel(_ panel: NSWindow) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let x = screen.midX - size.width / 2
        let y = screen.minY + screen.height * 0.62 - size.height / 2
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    private func buildPanel() {
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 440),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.animationBehavior = .utilityWindow

        let card = ThemedCard(frame: p.contentView!.bounds)
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.autoresizingMask = [.width, .height]

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "magnifyingglass",
                              accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        glyph.contentTintColor = Cat.overlay1
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let sf = NSTextField(frame: .zero)
        sf.delegate = self
        sf.isBordered = false
        sf.drawsBackground = false
        sf.focusRingType = .none
        sf.font = .systemFont(ofSize: 22, weight: .light)
        sf.textColor = Cat.text
        sf.placeholderAttributedString = NSAttributedString(
            string: "Search clipboard…",
            attributes: [.foregroundColor: Cat.subtext0,
                         .font: NSFont.systemFont(ofSize: 22, weight: .light)])
        sf.lineBreakMode = .byTruncatingTail
        sf.cell?.usesSingleLineMode = true
        sf.translatesAutoresizingMaskIntoConstraints = false
        searchField = sf

        let divider = ThemedHairline()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false

        let tv = NSTableView()
        tv.headerView = nil
        tv.rowHeight = 38
        tv.style = .inset
        tv.backgroundColor = .clear
        tv.selectionHighlightStyle = .regular
        tv.allowsEmptySelection = false
        tv.allowsMultipleSelection = false
        tv.intercellSpacing = NSSize(width: 0, height: 2)
        tv.dataSource = self
        tv.delegate = self
        tv.target = self
        tv.doubleAction = #selector(panelDoubleClick)
        let col = NSTableColumn(identifier: .init("clip"))
        col.resizingMask = .autoresizingMask
        tv.addTableColumn(col)
        table = tv

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "↑ ↓ navigate     ↵ paste     click away to dismiss")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Cat.subtext0
        hint.alignment = .center
        hint.drawsBackground = false
        hint.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(glyph)
        card.addSubview(sf)
        card.addSubview(divider)
        card.addSubview(scroll)
        card.addSubview(hint)
        p.contentView = card

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            glyph.centerYAnchor.constraint(equalTo: sf.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 22),

            sf.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            sf.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            sf.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),

            divider.topAnchor.constraint(equalTo: sf.bottomAnchor, constant: 16),
            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),

            hint.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        panel = p
    }

    private func applyFilter(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = q.isEmpty
            ? history.items
            : history.items.filter { $0.plain.lowercased().contains(q) }
        table?.reloadData()
        if !filtered.isEmpty {
            table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func dismissPanel() {
        guard panelVisible else { return }
        panelVisible = false
        if let m = panelMonitor { NSEvent.removeMonitor(m); panelMonitor = nil }
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ note: Notification) {
        if (note.object as? NSWindow) === panel { dismissPanel() }
    }

    private func commitPanelSelection() {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { dismissPanel(); return }
        let clip = filtered[row]
        dismissPanel()
        paste(clip)
    }

    @objc private func panelDoubleClick() { commitPanelSelection() }

    private func panelKeyDown(_ e: NSEvent) -> NSEvent? {
        switch Int(e.keyCode) {
        case kVK_Escape:
            dismissPanel()
            NSApp.hide(nil)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            commitPanelSelection(); return nil
        case kVK_DownArrow:
            moveSelection(+1); return nil
        case kVK_UpArrow:
            moveSelection(-1); return nil
        default:
            return e
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let cur = table.selectedRow < 0 ? -1 : table.selectedRow
        let next = min(max(cur + delta, 0), filtered.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // NSTableView data source / delegate
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let cell = (tableView.makeView(withIdentifier: ClipCell.id, owner: self) as? ClipCell)
            ?? ClipCell(frame: .zero)
        cell.configure(filtered[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedRowView()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    // MARK: Notice HUD

    private func showNotice(_ text: String) {
        if notice == nil { buildNotice() }
        noticeLabel.stringValue = text
        guard let notice else { return }
        notice.center()
        notice.orderFrontRegardless()
        let token = UUID()
        noticeToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            if self?.noticeToken == token { self?.notice?.orderOut(nil) }
        }
    }

    private func buildNotice() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 110),
            styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let card = ThemedCard(frame: NSRect(x: 0, y: 0, width: 420, height: 110))
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.autoresizingMask = [.width, .height]

        let label = NSTextField(wrappingLabelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = Cat.text
        label.maximumNumberOfLines = 3
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        noticeLabel = label

        card.addSubview(label)
        w.contentView = card
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        notice = w
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
AppController.shared = controller
app.delegate = controller
app.run()
