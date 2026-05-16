// clipboard-manager — a lightweight macOS clipboard history manager.
//
// Menu-bar only (LSUIElement). Watches NSPasteboard for plain-text
// clips, keeps a capped de-duplicated in-memory ring, and offers two
// global hotkeys to paste an old clip back into the frontmost app:
//
//   ⌘⌥V  searchable panel  (also: status-item left-click)
//   ⌃⌥V  cycle bezel       (press to step older, pause to paste)
//
// See design.md for the full rationale. One source file, built with
// `swiftc -O` and hand-bundled by the justfile.

import ApplicationServices
import Carbon.HIToolbox
import Cocoa
import CoreGraphics

// MARK: - Tunables

enum Cfg {
    static let historyCap = 200
    static let pollInterval: TimeInterval = 0.5
    static let cycleCommitDelay: TimeInterval = 1.0
    static let pasteKeystrokeDelay: TimeInterval = 0.12
    static let panelHotkeyID: UInt32 = 1
    static let cycleHotkeyID: UInt32 = 2
}

// Pasteboard types that mark a clip as "do not record".
let kConcealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
let kTransientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

// MARK: - History

final class History {
    private(set) var items: [String] = []

    func add(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if let i = items.firstIndex(of: s) { items.remove(at: i) }
        items.insert(s, at: 0)
        if items.count > Cfg.historyCap {
            items.removeLast(items.count - Cfg.historyCap)
        }
    }

    func clear() { items.removeAll() }
}

// MARK: - Keyable panel

// A borderless NSPanel won't become key by default, which would stop
// the search field from receiving text. Force it.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate
{
    static var shared: AppController?

    let history = History()

    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    private var hotkeyRefs: [EventHotKeyRef?] = []

    // App that was frontmost when a hotkey fired — the paste target.
    private var prevApp: NSRunningApplication?

    private var axTrusted = false

    // Searchable panel
    private var panel: KeyablePanel?
    private var searchField: NSSearchField!
    private var table: NSTableView!
    private var filtered: [String] = []
    private var panelMonitor: Any?

    // Cycle bezel
    private var bezel: NSWindow?
    private var bezelLabel: NSTextField!
    private var bezelCounter: NSTextField!
    private var cycleIndex = 0
    private var cycleTimer: Timer?
    private var escMonitor: Any?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        axTrusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)

        setupStatusItem()
        startWatching()
        installHotkeys()
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

        menu.addItem(disabled("Panel:  ⌘⌥V"))
        menu.addItem(disabled("Cycle:  ⌃⌥V"))
        if !axTrusted {
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
        guard let s = pb.string(forType: .string) else { return }
        history.add(s)
    }

    // Call right after we write the pasteboard ourselves so the next
    // poll doesn't re-ingest our own clip.
    private func markPasteboardWritten() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: Hotkeys

    private func installHotkeys() {
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
                let id = hk.id
                DispatchQueue.main.async { AppController.shared?.handleHotkey(id) }
                return noErr
            },
            1, &spec, nil, nil)

        register(id: Cfg.panelHotkeyID,
                 keyCode: UInt32(kVK_ANSI_V),
                 modifiers: UInt32(cmdKey | optionKey))
        register(id: Cfg.cycleHotkeyID,
                 keyCode: UInt32(kVK_ANSI_V),
                 modifiers: UInt32(controlKey | optionKey))
    }

    private func register(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        let hkID = EventHotKeyID(
            signature: OSType(0x434C_4250 /* 'CLBP' */), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("clipboard-manager: RegisterEventHotKey \(id) failed (\(status)) — chord may be in use")
        }
        hotkeyRefs.append(ref)
    }

    func handleHotkey(_ id: UInt32) {
        // Capture the paste target before any of our UI takes focus.
        prevApp = NSWorkspace.shared.frontmostApplication
        switch id {
        case Cfg.panelHotkeyID: showPanel()
        case Cfg.cycleHotkeyID: cycleStep()
        default: break
        }
    }

    // MARK: Paste

    private func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        markPasteboardWritten()

        history.add(text)  // promote to most-recent

        guard axTrusted else {
            NSLog("clipboard-manager: clip on pasteboard; grant Accessibility for auto-paste")
            return
        }

        prevApp?.activate(options: [])
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
        if prevApp == nil { prevApp = NSWorkspace.shared.frontmostApplication }
        if panel == nil { buildPanel() }
        guard let panel else { return }

        searchField.stringValue = ""
        applyFilter("")
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        panelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] e in self?.panelKeyDown(e) ?? e
        }
    }

    private func buildPanel() {
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false

        let content = NSView(frame: p.contentLayoutRect)
        content.autoresizingMask = [.width, .height]

        let sf = NSSearchField(frame: .zero)
        sf.placeholderString = "Filter clips…"
        sf.delegate = self
        sf.translatesAutoresizingMaskIntoConstraints = false
        searchField = sf

        let tv = NSTableView()
        tv.headerView = nil
        tv.rowHeight = 22
        tv.allowsMultipleSelection = false
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
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(sf)
        content.addSubview(scroll)
        p.contentView = content

        NSLayoutConstraint.activate([
            sf.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            sf.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            sf.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: sf.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        panel = p
    }

    private func applyFilter(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = q.isEmpty
            ? history.items
            : history.items.filter { $0.lowercased().contains(q) }
        table?.reloadData()
        if !filtered.isEmpty {
            table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func dismissPanel() {
        if let m = panelMonitor { NSEvent.removeMonitor(m); panelMonitor = nil }
        panel?.orderOut(nil)
        prevApp?.activate(options: [])
    }

    private func commitPanelSelection() {
        let row = table.selectedRow
        guard row >= 0, row < filtered.count else { dismissPanel(); return }
        let text = filtered[row]
        dismissPanel()
        paste(text)
    }

    @objc private func panelDoubleClick() { commitPanelSelection() }

    private func panelKeyDown(_ e: NSEvent) -> NSEvent? {
        switch Int(e.keyCode) {
        case kVK_Escape:
            dismissPanel(); return nil
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
        let id = NSUserInterfaceItemIdentifier("cell")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
            field.font = .systemFont(ofSize: 12)
        }
        let oneLine = filtered[row]
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        field.stringValue = oneLine
        return field
    }

    // NSSearchField delegate
    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    // MARK: Cycle bezel

    private func cycleStep() {
        guard !history.items.isEmpty else {
            flashBezel("no clips")
            return
        }
        if bezel == nil { buildBezel() }
        if bezel?.isVisible != true {
            cycleIndex = 0
            startEscMonitor()
        } else {
            cycleIndex = (cycleIndex + 1) % history.items.count
        }
        renderBezel()
        bezel?.center()
        bezel?.orderFrontRegardless()

        cycleTimer?.invalidate()
        cycleTimer = Timer.scheduledTimer(
            withTimeInterval: Cfg.cycleCommitDelay, repeats: false
        ) { [weak self] _ in self?.commitCycle() }
    }

    private func commitCycle() {
        guard let items = bezelItemsSnapshot(), cycleIndex < items.count else {
            hideBezel(); return
        }
        let text = items[cycleIndex]
        hideBezel()
        paste(text)
    }

    private func bezelItemsSnapshot() -> [String]? {
        history.items.isEmpty ? nil : history.items
    }

    private func cancelCycle() { hideBezel() }

    private func hideBezel() {
        cycleTimer?.invalidate(); cycleTimer = nil
        stopEscMonitor()
        bezel?.orderOut(nil)
    }

    private func startEscMonitor() {
        stopEscMonitor()
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] e in
            if Int(e.keyCode) == kVK_Escape { self?.cancelCycle() }
        }
    }

    private func stopEscMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    private func buildBezel() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        let label = NSTextField(wrappingLabelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        bezelLabel = label

        let counter = NSTextField(labelWithString: "")
        counter.alignment = .center
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.textColor = .secondaryLabelColor
        counter.translatesAutoresizingMaskIntoConstraints = false
        bezelCounter = counter

        blur.addSubview(label)
        blur.addSubview(counter)
        w.contentView = blur

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: blur.centerYAnchor, constant: -8),
            counter.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            counter.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -12),
        ])
        bezel = w
    }

    private func renderBezel() {
        let items = history.items
        guard cycleIndex < items.count else { return }
        let raw = items[cycleIndex]
        let trimmed = raw.count > 240 ? String(raw.prefix(240)) + "…" : raw
        bezelLabel.stringValue = trimmed
            .replacingOccurrences(of: "\t", with: "    ")
        bezelCounter.stringValue = "\(cycleIndex + 1) / \(items.count)   ·   Esc to cancel"
    }

    private func flashBezel(_ text: String) {
        if bezel == nil { buildBezel() }
        bezelLabel.stringValue = text
        bezelCounter.stringValue = ""
        bezel?.center()
        bezel?.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.bezel?.orderOut(nil)
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
AppController.shared = controller
app.delegate = controller
app.run()
