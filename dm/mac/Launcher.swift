// Mac app launcher: the settings window shown before the game starts, in the launcher's own process (launcher.c calls dm_mac_launcher before it starts the host). Its settings come from the
// app's Resources/dm/launcher.json (dm/games/settings.py with SETTINGS_PLATFORM=mac); the model and the rows are the iOS launcher's (dm/ios/Sources/LauncherSettings.swift, LauncherRow.swift),
// and so is the store: launcher.<VAR> in the app's preferences, which launcher.c reads when the window is not shown (docs/frontends.md, Saved choices). Basic settings (level basic) come
// first, the others under Advanced settings, each in the list's sections. An Input tab beside them edits the controls profile (LauncherControls.swift). Play puts the settings into this process's environment, which the host inherits; Quit and closing the window end the
// app without the game. "Show this window at launch" off: no window unless Option is held at launch, and launcher.c applies the saved choices. The window never takes focus by itself: an app
// opened in the background (open -g) keeps its window behind until the player switches to it. While the game runs, the game's Settings… (⌘,) shows the window again (LiveSettings below)
import AppKit
import AVFAudio
import CoreAudio
import QuartzCore
import SwiftUI

private func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

/// The host's comparison of the two saves (dm/host/save_sync.c). This launcher links save_sync.o but imports no C header (pack_app.py builds it with swiftc and no bridging
/// header), so the symbol is declared here.
@_silgen_name("save_sync_report")
private func save_sync_report(_ save: UnsafePointer<CChar>, _ title: UnsafePointer<CChar>, _ folder: UnsafePointer<CChar>?, _ waitMs: Int32,
                              _ out: UnsafeMutablePointer<CChar>, _ n: Int) -> Int32

/// Cloud saves before Play: this Mac's save against the cloud's (SaveSyncReport, shared with the iPhone launcher), and the question it needs, as alerts.
/// It runs with the window's Play and, with the window off, before dmMacLauncher returns; DM_LAUNCHER=0 asks nothing (the host takes the newer save).
enum SaveCheck {
    enum Outcome { case play(String?), retry, cancel }

    /// Blocks while the cloud's file comes (SaveSyncReport.waitMs at most): call it off the main thread. nil: no report (sync is then left to the host as before)
    static func report() -> SaveSyncReport? {
        // getenv, not ProcessInfo.environment: launcher.c sets DM_SAVE and applies the env files in this process before the window
        guard let save = getenv("DM_SAVE") else { fputs("launcher: save sync: no DM_SAVE\n", stderr); return nil }
        guard let id = info("DMTitleID"), !id.isEmpty else { fputs("launcher: save sync: no DMTitleID\n", stderr); return nil }
        // the folder as launcher.c will pass it (cloud_saves_folder): DM_SAVE_SYNC from the launch environment or an env file, else the window's choice; "0" = off
        let folder = getenv("DM_SAVE_SYNC").map { String(cString: $0) } ?? (UserDefaults.standard.string(forKey: "cloudSaves.folder") ?? "")
        var buf = [CChar](repeating: 0, count: 1024)
        let r = (folder.isEmpty ? "0" : folder).withCString { save_sync_report(save, id, $0, SaveSyncReport.waitMs, &buf, buf.count) }
        let line = String(cString: buf)
        guard r == 0 else { fputs("launcher: save sync: no report on \(String(cString: save))\n", stderr); return nil }
        fputs("launcher: save sync: \(line)\n", stderr)
        return SaveSyncReport(line: line)
    }

    /// The question the report needs, as a modal alert; `cancel` names the way back ("Cancel" to the window, "Quit" without one)
    static func ask(_ r: SaveSyncReport?, cancel: String) -> Outcome {
        switch SaveSyncReport.step(r) {
        case .play(let choice): return .play(choice)
        case .choose:
            guard let r else { return .play(nil) }
            let a = NSAlert()
            a.messageText = SaveSyncReport.chooseTitle
            a.informativeText = r.chooseMessage(here: "Mac")
            a.alertStyle = .warning
            a.addButton(withTitle: r.localLabel(here: "Mac"))
            a.addButton(withTitle: r.cloudLabel)
            a.addButton(withTitle: cancel)
            a.buttons[0].keyEquivalent = ""   // no default: Return must not pick a save (the newer is not always the one to keep)
            a.buttons[2].keyEquivalent = "\u{1b}"
            switch a.runModal() {
            case .alertFirstButtonReturn: return .play(r.localChoice)
            case .alertSecondButtonReturn: return .play(r.cloudChoice)
            default: return .cancel
            }
        case .missing:
            guard let r else { return .play(nil) }
            let a = NSAlert()
            a.messageText = SaveSyncReport.missingTitle
            a.informativeText = r.missingMessage(here: "Mac")
            a.alertStyle = .warning
            a.addButton(withTitle: "Try Again")
            a.addButton(withTitle: "Play Without Sending")
            a.addButton(withTitle: r.sendLabel(here: "Mac"))
            a.addButton(withTitle: cancel)
            a.buttons[2].hasDestructiveAction = true
            a.buttons[3].keyEquivalent = "\u{1b}"
            switch a.runModal() {
            case .alertFirstButtonReturn: return .retry
            case .alertSecondButtonReturn: return .play("offline")   // this Mac's save, not sent: the next start compares again
            case .alertThirdButtonReturn: return .play(r.localChoice)   // local:none
            default: return .cancel
            }
        case .unreadable:
            let a = NSAlert()
            a.messageText = SaveSyncReport.unreadableTitle
            a.informativeText = r?.unreadableMessage(here: "Mac") ?? ""
            a.addButton(withTitle: "Play This Mac's Save")
            a.addButton(withTitle: "Try Again")
            a.addButton(withTitle: cancel)
            a.buttons[2].keyEquivalent = "\u{1b}"
            switch a.runModal() {
            case .alertFirstButtonReturn: return .play("offline")   // the mount does not wait for the cloud again
            case .alertSecondButtonReturn: return .retry
            default: return .cancel
            }
        }
    }

    static func apply(_ choice: String?) {
        guard let choice else { return }
        setenv("DM_SAVE_SYNC_CHOICE", choice, 1)
        fputs("launcher: DM_SAVE_SYNC_CHOICE=\(choice)\n", stderr)
    }

    /// With the window off: the check and its question before the game, the app in front only while it asks. false: the player quit
    static func withoutWindow() -> Bool {
        final class Box: @unchecked Sendable { let lock = NSLock(); var report: SaveSyncReport?; var waiting = false }
        let app = NSApplication.shared
        defer { app.setActivationPolicy(.prohibited) }
        while true {
            let box = Box(), sem = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                let r = report()
                box.lock.lock(); box.report = r; box.lock.unlock()
                sem.signal()
                DispatchQueue.main.async { if box.waiting { app.abortModal() } }   // runs inside the waiting alert's modal loop, if there is one
            }
            if sem.wait(timeout: .now() + 0.5) == .timedOut {   // a cloud file to download: say so, and let the player go on without it
                app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "Checking the cloud save…"
                a.informativeText = "Waiting for iCloud to deliver this game's save."
                a.addButton(withTitle: "Play Without It")
                a.addButton(withTitle: "Quit")
                box.waiting = true
                let answer = a.runModal()
                box.waiting = false
                if answer == .alertFirstButtonReturn { apply("offline"); return true }
                if answer == .alertSecondButtonReturn { return false }
                sem.wait()   // aborted: the report is in
            }
            box.lock.lock(); let r = box.report; box.lock.unlock()
            if case .play(let choice) = SaveSyncReport.step(r) { apply(choice); return true }
            app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
            switch ask(r, cancel: "Quit") {
            case .play(let choice): apply(choice); return true
            case .retry: continue
            case .cancel: return false
            }
        }
    }
}

struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let done: (Bool) -> Void
    let fit: (CGFloat) -> Void
    @ObservedObject var controls: ControlsModel
    var live = false   // the game runs: Done instead of Quit and Play, and the settings the host cannot change now say so
    @AppStorage("window.show") private var show = true
    @AppStorage("window.advanced") private var advanced = false
    @AppStorage("window.tab") private var tab = 0
    @State private var checking = false
    @State private var check = 0   // which Play the running check is for: one the player went on from without it is dropped

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info("CFBundleName") ?? "Game").font(.headline)
                    HStack(spacing: 0) {
                        Text("Version \(info("DMGameVersion") ?? info("CFBundleShortVersionString") ?? "Unknown")")
                        if let c = info("DMCommit"), !c.isEmpty {
                            Text(" (")
                            CommitLink(commit: c, url: info("DMCommitURL").flatMap(URL.init(string:)))
                            Text(")")
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    Text("App bundle version \(info("CFBundleShortVersionString") ?? "1.0.0")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 2)   // the title bar's safe area already keeps it below the traffic lights
            TabBar(tab: $tab, titles: ["Settings", "Input"])
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20).padding(.top, 10)
            Form {
                if tab == 1 { ControlsTab(c: controls) } else { settings }
            }
            .formStyle(.grouped)
            .contentMargins(.top, 6, for: .scrollContent)
            .background(OverlayScrollers())
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom - $0.containerSize.height
            } action: { _, extraHeight in
                fit(extraHeight)
            }
            HStack {
                Toggle("Show this window at launch", isOn: $show).toggleStyle(.checkbox)
                Spacer()
                if live {
                    Button("Done") { done(true) }.keyboardShortcut(.defaultAction)
                } else {
                    if checking {
                        ProgressView().controlSize(.small)
                        Text("Checking the cloud save…").foregroundStyle(.secondary)
                        Button("Play Without It") { checking = false; SaveCheck.apply("offline"); done(true) }
                    }
                    Button("Quit") { done(false) }
                    Button("Play") { start() }.keyboardShortcut(.defaultAction).disabled(checking)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 560)
    }

    /// Play, once the cloud's save is compared with this Mac's: a save that changed on both sides is the player's pick, not the newer file's (SaveCheck)
    private func start() {
        check += 1; checking = true
        let mine = check
        DispatchQueue.global(qos: .userInitiated).async {
            let r = SaveCheck.report()
            DispatchQueue.main.async {
                guard checking, check == mine else { return }   // the player played without it
                checking = false
                switch SaveCheck.ask(r, cancel: "Cancel") {
                case .play(let choice): SaveCheck.apply(choice); done(true)
                case .retry: start()
                case .cancel: break   // back to the window, nothing chosen
                }
            }
        }
    }

    // Basic settings and the Advanced settings row share one card; the advanced ones open in a second card below it
    @ViewBuilder private var settings: some View {
        Section {
            settingRows(basic: true)
            Button { advanced.toggle() } label: {
                HStack {
                    Text("Advanced settings")
                    Spacer()
                    Image(systemName: advanced ? "chevron.down" : "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(advanced ? "Shown" : "Hidden")
        }
        if advanced {
            Section { settingRows(basic: false) }
            Section {
                Button("Reset to tested defaults") { m.reset() }
                    .disabled(!m.changed)
            } footer: {
                Text("Brings back all settings this game was tested with.")
            }
        }
        if m.values["DM_MIC"] == "1" { MicrophoneDevicePicker() }
        CloudSavesSection(nextStart: live)
    }

    static let nextStartNote = "Applies the next time the game starts."
    /// While the game runs: a row the host cannot change now says so, and a row the game reports on (LauncherModel.now) shows what it does now
    private func shown(_ s: Setting) -> Setting {
        guard live else { return s }
        let extra = [LiveSettings.keys.contains(s.env) ? nil : Self.nextStartNote, m.now[s.env]].compactMap { $0 }
        guard !extra.isEmpty else { return s }
        let note = ([s.note].filter { !$0.isEmpty } + extra).joined(separator: " ")
        return Setting(env: s.env, kind: s.kind, label: s.label, note: note, def: s.def, section: s.section,
                       needs: s.needs, level: s.level, base: s.base, options: s.options, min: s.min, max: s.max, step: s.step, on: s.on, off: s.off)
    }

    /// The rows of each of the list's sections, under the section's name as a small caption inside the card
    @ViewBuilder private func settingRows(basic: Bool) -> some View {
        ForEach(m.sections(basic: basic), id: \.self) { section in
            let rows = m.rows(in: section, basic: basic)
            if !rows.isEmpty {
                if !section.isEmpty {
                    Text(section.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4).accessibilityAddTraits(.isHeader)
                }
                ForEach(rows) { SettingRow(s: shown($0), m: m) }
            }
        }
    }
}

private struct MicrophoneDevicePicker: View {
    @AppStorage("launcher.DM_MIC_DEVICE") private var savedDevice = "default"
    @State private var devices = MicrophoneInputDevices.list()

    var body: some View {
        Section {
            if let uid = getenv("DM_MIC_DEVICE") {
                let value = String(cString: uid)
                LabeledContent("Microphone input", value: devices.first { $0.uid == value }?.name ?? "System Default")
            } else {
                Picker("Microphone input", selection: $savedDevice) {
                    Text("System Default").tag("default")
                    if savedDevice != "default", !devices.contains(where: { $0.uid == savedDevice }) {
                        Text("Selected device unavailable").tag(savedDevice)
                    }
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            devices = MicrophoneInputDevices.list()
        }
    }
}

private struct MicrophoneInputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

private enum MicrophoneInputDevices {
    static func list() -> [MicrophoneInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.compactMap { device in
            guard hasInput(device), let uid = string(device, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(device, selector: kAudioObjectPropertyName), !uid.isEmpty else { return nil }
            return MicrophoneInputDevice(uid: uid, name: dualSenseOverUSB(device) ? "\(name) (USB)" : name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, data) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    // A DualSense or DualSense Edge on USB: CoreAudio exposes its USB VID:PID at the end of ModelUID ("<name>:054C:0CE6" / ":0DF2").
    private static func dualSenseOverUSB(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeUSB,
              let model = string(device, selector: kAudioDevicePropertyModelUID) else { return false }
        let parts = model.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let vid = UInt32(parts[parts.count - 2], radix: 16),
              let pid = UInt32(parts[parts.count - 1], radix: 16) else { return false }
        return vid == 0x054C && (pid == 0x0CE6 || pid == 0x0DF2)
    }

    private static func string(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer))
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

/// "Version 1.6.0 (d0ab754c)": the commit that packed the app (DMCommit, pack_app.py source_commit) beside the game's version. A link to the commit's page when the packer
/// found it on GitHub (DMCommitURL; a local commit has no page there): blue under the pointer, a click opens it. Its menu copies the commit ID and the link
struct CommitLink: View {
    let commit: String, url: URL?
    @State private var hover = false

    var body: some View {
        let id = commit.hasSuffix("+dirty") ? String(commit.dropLast(6)) : commit
        Button { if let url { NSWorkspace.shared.open(url) } } label: {
            Text("\(id.prefix(8))\(commit.hasSuffix("+dirty") ? "+dirty" : "")")
                .foregroundStyle(url != nil && hover ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain).focusable(false)
        .onHover { inside in
            hover = inside
            guard url != nil else { return }
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(url != nil ? "Open this commit on GitHub" : "This commit is not on GitHub")
        .contextMenu {
            Button("Copy Commit ID") { Self.copy(id) }
            if let url { Button("Copy Link") { Self.copy(url.absoluteString) } }
        }
    }

    private static func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
}

/// The Form's scroll bar as an overlay: thin, shown while scrolling or under the pointer, whatever "Show scroll bars" says in System Settings
/// (with a mouse connected, the default there is a permanent wide bar). AppKit sets the style again when that setting changes, so it is set again then
struct OverlayScrollers: NSViewRepresentable {
    final class Probe: NSView {
        private var token: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            if token == nil {
                token = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { self?.apply() }
                }
            }
        }
        deinit { if let t = token { NotificationCenter.default.removeObserver(t) } }
        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let root = self?.window?.contentView else { return }
                func walk(_ v: NSView) {
                    if let s = v as? NSScrollView {
                        s.scrollerStyle = .overlay; s.autohidesScrollers = true
                        s.verticalScroller?.controlSize = .small
                    }
                    v.subviews.forEach(walk)
                }
                walk(root)
            }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) { v.apply() }
}

/// The window's tabs, across its whole width: SwiftUI's segmented Picker keeps its own width on the Mac, AppKit's control can fill the row
struct TabBar: NSViewRepresentable {
    @Binding var tab: Int
    let titles: [String]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        c.segmentDistribution = .fillEqually; c.controlSize = .large
        c.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return c
    }
    func updateNSView(_ c: NSSegmentedControl, context: Context) { c.selectedSegment = tab; context.coordinator.tab = $tab }
    func makeCoordinator() -> Coordinator { Coordinator(tab: $tab) }

    final class Coordinator: NSObject {
        var tab: Binding<Int>
        init(tab: Binding<Int>) { self.tab = tab }
        @objc func changed(_ c: NSSegmentedControl) { tab.wrappedValue = c.selectedSegment }
    }
}

/// Cloud saves: a folder the save is synced through (dm/host/save_sync.h), the one the iPhone app picks in its launcher's Cloud saves section. It is kept in this app's
/// preferences as cloudSaves.folder, which launcher.c puts into DM_SAVE_SYNC before the host starts; a DM_SAVE_SYNC an env file or the launch environment set wins, and is shown here.
struct CloudSavesSection: View {
    var nextStart = false
    @AppStorage("cloudSaves.folder") private var folder = ""
    private let fixed: String? = {
        let env = ProcessInfo.processInfo.environment
        let keys = ((env["DM_ENV_FILE_KEYS"] ?? "") + " " + (env["DM_ENV_LAUNCH_KEYS"] ?? "")).split(separator: " ")
        return keys.contains("DM_SAVE_SYNC") || env["DM_SAVE_SYNC"] != nil ? env["DM_SAVE_SYNC"] : nil
    }()

    var body: some View {
        Section {
            LabeledContent("Cloud saves") {
                Text(fixed.map { "\(Self.shown($0)) (env.txt)" } ?? (folder.isEmpty ? "Off" : Self.shown(folder)))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            if fixed == nil {
                HStack {
                    Button(folder.isEmpty ? "Choose a folder…" : "Choose a different folder…", action: choose)
                    if !folder.isEmpty { Button("Turn off") { folder = "" } }
                }
            }
        } footer: {
            Text("Choose the iCloud Drive folder the iPhone app uses for this game. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in the save's -backups folder."
                 + (nextStart ? " " + LauncherView.nextStartNote : ""))
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "Use for Cloud Saves"
        panel.message = "The folder the iPhone app chose in its launcher's Cloud saves"
        panel.directoryURL = URL(fileURLWithPath: folder.isEmpty ? Self.drive : folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    static let drive = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"   // iCloud Drive, as the Finder shows it

    /// A path under iCloud Drive as the Finder and the Files app name it: iCloud Drive › Documents › dev › Zelda; any other path as it is
    static func shown(_ path: String) -> String {
        guard path == drive || path.hasPrefix(drive + "/") else { return path }
        return (["iCloud Drive"] + path.dropFirst(drive.count).split(separator: "/").map(String.init)).joined(separator: " › ")
    }
}

/// The settings window, at the top of the screen, centred; its content's height fits the window (fitWindow)
private func settingsWindow<V: View>(_ root: V, delegate: NSWindowDelegate) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    w.title = info("CFBundleName") ?? "Game"; w.isReleasedWhenClosed = false; w.delegate = delegate
    w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.titlebarSeparatorStyle = .none   // one surface with the header, which shows the name
    w.isMovableByWindowBackground = true   // the header stands where the title bar was, so dragging it moves the window as the title bar did
    w.contentMinSize = NSSize(width: 520, height: 0)
    if let screen = w.screen ?? NSScreen.main {
        w.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.midX - w.frame.width / 2, y: screen.visibleFrame.maxY))
    }
    let host = NSHostingView(rootView: root)
    host.sizingOptions = []   // the Form's measured scroll content owns the height, including after collapse
    w.contentView = host
    host.layoutSubtreeIfNeeded()
    return w
}
private func fitWindow(_ w: NSWindow?, _ extraHeight: CGFloat) {
    guard let w, let screen = w.screen else { return }
    let frame = LauncherWindowLayout.fitted(w.frame, extraHeight: extraHeight, visible: screen.visibleFrame)
    if abs(frame.height - w.frame.height) > 0.5 { w.setFrame(frame, display: true) }
}
/// NSApp.run returns at the next event after stop, so one is posted
private func stopRun() {
    NSApp.stop(nil)
    NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
}

private final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: LauncherModel
    let controls = ControlsModel()
    var window: NSWindow?
    var play = false

    init(_ model: LauncherModel) { self.model = model }

    func applicationDidFinishLaunching(_ n: Notification) {
        let name = info("CFBundleName") ?? "Game"
        let menu = NSMenu(), item = NSMenuItem(), app = NSMenu()
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app; menu.addItem(item); NSApp.mainMenu = menu
        let w = settingsWindow(LauncherView(m: model, done: { [weak self] in self?.finish($0) }, fit: { [weak self] in fitWindow(self?.window, $0) }, controls: controls), delegate: self)
        window = w
        // no activation and no ordering in front of another app's windows: LaunchServices activates an app opened from Finder or the Dock (applicationDidBecomeActive), open -g does not
        if NSApp.isActive { w.makeKeyAndOrderFront(nil) } else { w.orderBack(nil) }
    }
    func applicationDidBecomeActive(_ n: Notification) { window?.makeKeyAndOrderFront(nil) }
    // No control holds the focus when the window first becomes key, so none shows a focus ring until the player presses Tab. AppKit gives the first key view the focus
    // then (with keyboard navigation on in System Settings, a ring around a button); Return still presses Play, the window's default button
    private var focusCleared = false
    func windowDidBecomeKey(_ n: Notification) {
        guard !focusCleared, let w = window else { return }
        focusCleared = true
        DispatchQueue.main.async { w.makeFirstResponder(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {   // ⌘Q, or a logout or restart: the app ends without the game (exit 0, as Quit)
        fputs("launcher: quit without starting the game\n", stderr)
        return .terminateNow   // not terminateCancel, which a logout or restart takes as a refusal and stops
    }
    func windowWillClose(_ n: Notification) { finish(false) }

    func finish(_ play: Bool) {
        guard let w = window else { return }
        window = nil; self.play = play
        // The main thread blocks in launcher.c's waitpid once run() returns, so the window must leave the screen now: no fade-out (it runs on later run-loop passes),
        // and dmMacLauncher flushes the order-out (AppKit commits it at the end of a pass). Without both, the window stayed on screen, not responding, until the game ended
        w.animationBehavior = .none
        w.delegate = nil; w.orderOut(nil)
        stopRun()
    }
}

/// The settings window while the game runs: the game's Settings… (⌘,; dm/host/front_mac.m) sends SIGUSR1 to this process, which waits for the host in dm_mac_launcher_wait.
/// Done (or closing the window) saves every choice for the next start, writes the live settings the player changed to live.env in the game's Application Support folder
/// (this process's working folder, the host's DM_ROOT) and sends SIGUSR1 back; the host applies them and takes the front again. keys: what the host can change live
/// (front_mac.m live_settings_apply; dm/tools/tests/test_nsp_mac_app.py checks that the lists match). A setting an env file or the launch environment set is never sent
final class LiveSettings: NSObject, NSWindowDelegate {
    static let keys: Set<String> = ["DM_KEYMAP", "DM_PAD_MAP", "DM_PAD_ABXY", "DM_PAD_STICK_DZ", "DM_PAD_STICK_SENS", "DM_RUMBLE_GAIN", "DM_RUMBLE_MIN", "DM_FPS_HOLD", "DM_PRESENT_UPSCALE", "DM_FULLSCREEN"]
    let settings: [Setting], host: pid_t
    private var window: NSWindow?, model: LauncherModel?, controls: ControlsModel?, before: [String: String] = [:], timer: Timer?

    init(_ settings: [Setting], host: pid_t) { self.settings = settings; self.host = host }

    func show() {
        if let w = window { NSApp.activate(); w.makeKeyAndOrderFront(nil); return }
        let m = LauncherModel(settings), c = ControlsModel()
        model = m; controls = c; before = current()
        NSApp.setActivationPolicy(.accessory)   // a window and the front, without a second Dock icon beside the game's
        let w = settingsWindow(LauncherView(m: m, done: { [weak self] _ in self?.done() }, fit: { [weak self] in fitWindow(self?.window, $0) }, controls: c, live: true), delegate: self)
        window = w
        readNow()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.readNow() }
        NSApp.activate(); w.makeKeyAndOrderFront(nil)
        fputs("launcher: settings window while the game runs\n", stderr)
    }

    /// The host's report of its upscaling (nvn_mtl.m fx_status), in words under the Upscaling row
    private func readNow() {
        guard let m = model else { return }
        let path = FileManager.default.currentDirectoryPath + "/upscaling_now.txt"
        let f = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let n = f.dropFirst().compactMap(Int.init)
        let text: String?
        switch (f.first, n.count) {
        case ("off", _): text = "Now: Standard."
        case ("idle", 2): text = "Now: Standard. MetalFX starts when the window is larger than the picture (\(n[0]) × \(n[1]))."
        case ("metalfx", 4): text = "Now: MetalFX, \(n[0]) × \(n[1]) to \(n[2]) × \(n[3])."
        default: text = nil
        }
        if m.now["DM_PRESENT_UPSCALE"] != text { m.now["DM_PRESENT_UPSCALE"] = text }
    }

    /// The live settings as the host would take them now; the controls as launcher.c puts them together: a saved launcher.DM_KEYMAP or DM_PAD_MAP wins over the profile
    private func current() -> [String: String] {
        guard let m = model, let c = controls else { return [:] }
        var v: [String: String] = [:]
        for s in m.settings where Self.keys.contains(s.env) && !m.fixed.contains(s.env) { v[s.env] = m.values[s.env] ?? s.def }
        for (k, x) in c.env() where !c.fixed.contains(k) && UserDefaults.standard.string(forKey: "launcher." + k) == nil { v[k] = x }
        for k in ["DM_KEYMAP", "DM_PAD_MAP"] where !c.fixed.contains(k) {
            if let saved = UserDefaults.standard.string(forKey: "launcher." + k) { v[k] = saved }
        }
        return v
    }

    func windowWillClose(_ n: Notification) { done() }

    func done() {
        guard window != nil, let m = model else { return }
        let changed = current().filter { before[$0.key] != $0.value }.sorted { $0.key < $1.key }
        m.apply()   // saves the choices; the environment it sets is this process's, which the running host does not see
        let file = FileManager.default.currentDirectoryPath + "/live.env"
        do { try changed.map { "\($0.key)=\($0.value)\n" }.joined().write(toFile: file, atomically: true, encoding: .utf8) }
        catch { fputs("[RED] launcher: cannot write \(file): \(error.localizedDescription)\n", stderr) }
        fputs("launcher: live settings: \(changed.isEmpty ? "none changed" : changed.map { "\($0.key)=\($0.value)" }.joined(separator: " "))\n", stderr)
        close()
        if let h = NSRunningApplication(processIdentifier: host) { NSApp.yieldActivation(to: h) }
        NSApp.setActivationPolicy(.prohibited)
        kill(host, SIGUSR1)
    }

    func close() {
        guard let w = window else { return }
        window = nil; model = nil; controls = nil
        timer?.invalidate(); timer = nil
        w.delegate = nil; w.orderOut(nil)
    }
}

enum LauncherWindowLayout {
    static func fitted(_ frame: NSRect, extraHeight: CGFloat, visible: NSRect) -> NSRect {
        let top = min(frame.maxY, visible.maxY)
        let height = min(frame.height + extraHeight, top - visible.minY)
        return NSRect(x: frame.minX, y: top - height, width: frame.width, height: height)
    }
}

// Called on the main thread after settings and cloud-save decisions. The OS can present
// its consent alert even when the settings window is suppressed.
@_cdecl("dm_mac_microphone_consent")
public func dmMacMicrophoneConsent() -> Int32 {
    switch AVAudioApplication.shared.recordPermission {
    case .granted: return 1
    case .undetermined:
        _ = NSApplication.shared
        var allowed: Bool?
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { allowed = granted }
        }
        while allowed == nil {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        if allowed == true {
            fputs("launcher: microphone permission allowed\n", stderr)
            return 1
        }
    default: break
    }
    fputs("launcher: microphone permission denied\n", stderr)
    return 0
}

/// The bundle's settings (dm/launcher.json); nil without them. quiet: no red line for a file that cannot be read
private func settingsFile(quiet: Bool = false) -> SettingsFile? {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return nil }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else {
        if !quiet { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr) }
        return nil
    }
    return file
}

// 1: Play (the window's settings are in the environment), 0: the player quit, 2: no window (no launcher.json, or "Show this window at launch" off): launcher.c applies the saved choices
@_cdecl("dm_mac_launcher")
public func dmMacLauncher() -> Int32 {
    guard let file = settingsFile() else { return 2 }
    if (UserDefaults.standard.object(forKey: "window.show") as? Bool) == false && !NSEvent.modifierFlags.contains(.option) {
        fputs("launcher: settings window off (hold Option at launch to show it)\n", stderr)
        return SaveCheck.withoutWindow() ? 2 : 0
    }
    let model = LauncherModel(file.settings)
    let app = NSApplication.shared, launcher = Launcher(model)
    app.setActivationPolicy(.regular)
    app.delegate = launcher
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    app.run()
    CATransaction.flush()   // finish's order-out
    app.setActivationPolicy(.prohibited)   // the host is the game's app from here on
    guard launcher.play else { fputs("launcher: quit without starting the game\n", stderr); return 0 }
    model.apply()
    return 1
}

// 1: the settings window can be shown while the game runs (dm_mac_launcher_wait), so launcher.c sets DM_SETTINGS_PID for the host's Settings… item
@_cdecl("dm_mac_settings_available")
public func dmMacSettingsAvailable() -> Int32 { settingsFile(quiet: true) != nil ? 1 : 0 }

// Waits for the host with this process's run loop, so the game's Settings… can show the settings window (LiveSettings); returns waitpid's status, -1 when the wait failed
@_cdecl("dm_mac_launcher_wait")
public func dmMacLauncherWait(_ pid: Int32) -> Int32 {
    guard let file = settingsFile(quiet: true) else { return -1 }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let live = LiveSettings(file.settings, host: pid)
    signal(SIGUSR1, SIG_IGN)
    let ask = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    ask.setEventHandler { live.show() }
    ask.resume()
    var status: Int32 = 0
    // polled: a process source registered after a quick exit would never fire
    let poll = DispatchSource.makeTimerSource(queue: .main)
    poll.schedule(deadline: .now(), repeating: 0.25)
    poll.setEventHandler {
        let r = waitpid(pid, &status, WNOHANG)
        guard r == pid || (r < 0 && errno != EINTR) else { return }
        if r < 0 { status = -1 }
        poll.cancel(); live.close(); stopRun()
    }
    poll.resume()
    app.run()
    ask.cancel()
    return status
}

// The keyboard map in the Mac settings window: the Keyboard section (default or custom, and a button that opens the map) and the map's sheet, where each button and stick direction
// of the controller shows its key; click one and press a key to bind it, or hold Shift, Control or Option and press a key for a chord (Esc stops without a change). The map itself is the host's (dm/host/keymap.h, reached through launcher.c's
// dm_km_* functions: this launcher imports no C header). It is kept as the saved choice launcher.DM_KEYMAP in keymap.h's full form, absent while it is the default (docs/frontends.md, Saved choices);
// launcher.c checks it with the host's parser and makes it DM_KEYMAP before the host starts, with or without this window. A DM_KEYMAP the launch environment or an env file set wins, and is shown here as fixed.

@_silgen_name("dm_km_target_label") private func dm_km_target_label(_ t: Int32) -> UnsafePointer<CChar>
@_silgen_name("dm_km_slot_label") private func dm_km_slot_label(_ slot: Int32) -> UnsafePointer<CChar>
@_silgen_name("dm_km_slots") private func dm_km_slots() -> Int32
@_silgen_name("dm_km_format_max") private func dm_km_format_max() -> Int32
@_silgen_name("dm_km_bind") private func dm_km_bind(_ key: UnsafeMutablePointer<UInt8>, _ target: Int32, _ slot: Int32, _ add: Int32) -> Int32
@_silgen_name("dm_km_slot") private func dm_km_slot(_ code: Int32, _ mods: Int32) -> Int32
@_silgen_name("dm_km_groups") private func dm_km_groups() -> Int32
@_silgen_name("dm_km_group_title") private func dm_km_group_title(_ g: Int32) -> UnsafePointer<CChar>
@_silgen_name("dm_km_group_size") private func dm_km_group_size(_ g: Int32) -> Int32
@_silgen_name("dm_km_group_target") private func dm_km_group_target(_ g: Int32, _ i: Int32) -> Int32
@_silgen_name("dm_km_keys") private func dm_km_keys() -> Int32
@_silgen_name("dm_km_bindable") private func dm_km_bindable(_ code: Int32) -> Int32
@_silgen_name("dm_km_read") private func dm_km_read(_ map: UnsafePointer<CChar>?, _ key: UnsafeMutablePointer<UInt8>, _ src: UnsafeMutablePointer<Int32>, _ speed: UnsafeMutablePointer<Float>, _ invert: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("dm_km_outs") private func dm_km_outs() -> Int32
@_silgen_name("dm_km_out_label") private func dm_km_out_label(_ o: Int32) -> UnsafePointer<CChar>
@_silgen_name("dm_km_src_off") private func dm_km_src_off() -> Int32
@_silgen_name("dm_km_src_mouse") private func dm_km_src_mouse() -> Int32
@_silgen_name("dm_km_mouse_key") private func dm_km_mouse_key(_ button: Int32) -> Int32
@_silgen_name("dm_km_src_label") private func dm_km_src_label(_ src: Int32) -> UnsafePointer<CChar>
@_silgen_name("dm_km_mouse_set") private func dm_km_mouse_set(_ src: UnsafeMutablePointer<Int32>, _ out: Int32, _ v: Int32)
@_silgen_name("dm_km_presets_load") private func dm_km_presets_load() -> Int32
@_silgen_name("dm_km_preset_save") private func dm_km_preset_save(_ key: UnsafePointer<UInt8>, _ src: UnsafePointer<Int32>, _ speed: UnsafePointer<Float>, _ invert: UnsafePointer<Int32>, _ name: UnsafePointer<CChar>, _ path: UnsafeMutablePointer<CChar>, _ n: Int) -> Int32
@_silgen_name("dm_km_preset_dir") private func dm_km_preset_dir() -> UnsafePointer<CChar>
@_silgen_name("dm_km_preset_name") private func dm_km_preset_name(_ i: Int32) -> UnsafePointer<CChar>
@_silgen_name("dm_km_preset_map") private func dm_km_preset_map(_ i: Int32) -> UnsafePointer<CChar>
@_silgen_name("dm_km_write") private func dm_km_write(_ key: UnsafePointer<UInt8>, _ src: UnsafePointer<Int32>, _ speed: UnsafePointer<Float>, _ invert: UnsafePointer<Int32>, _ out: UnsafeMutablePointer<CChar>, _ n: Int) -> Int32

/// A keyboard map: the target each binding presses (keymap.h: a binding is layer * keys + key code, the layers plain, Shift, Control, Option; 0xff none; mouse buttons from
/// key code 128), and what mouse movement moves: each output's source, speed and Invert Y (keymap.h MOUSERSTICK, MOUSELSTICK, MOUSEMOTION)
struct KeyMap: Equatable {
    static let none: UInt8 = 0xff
    static let slots = Int(dm_km_slots()), keyCount = Int(dm_km_keys()), outs = Int(dm_km_outs())
    static let srcOff = dm_km_src_off(), srcMouse = dm_km_src_mouse()   // an output's source: none, the plain mouse; else the key to hold (keymap.h KM_SRC_*)
    static let outputs = (0..<dm_km_outs()).map { String(cString: dm_km_out_label($0)) }   // keymap.h KM_OUT_*
    static func mouseKey(_ button: Int) -> Int? { let k = dm_km_mouse_key(Int32(button)); return k < 0 ? nil : Int(k) }   // a mouse button's key code
    var key = [UInt8](repeating: KeyMap.none, count: KeyMap.slots)
    var mouseSrc = [Int32](repeating: KeyMap.srcOff, count: KeyMap.outs)
    var mouseSpeed = [Float](repeating: 0, count: KeyMap.outs)   // all three filled by init (keymap.h km_default)
    var mouseInvert = [Int32](repeating: 0, count: KeyMap.outs)
    static func srcSlot(_ o: Int) -> Int { -10 - o }   // the capture slot of an output's mouse key (row targets are 0...)

    /// keymap.h's DM_KEYMAP over the default map (an empty string: the default)
    init(_ map: String = "") {
        _ = map.withCString { s in key.withUnsafeMutableBufferPointer { k in dm_km_read(s, k.baseAddress!, &mouseSrc, &mouseSpeed, &mouseInvert) } }
    }
    /// An output's source; another output with the plain mouse or the same key gets none (keymap.h km_mouse_set)
    mutating func setSource(_ o: Int, _ v: Int32) { dm_km_mouse_set(&mouseSrc, Int32(o), v) }
    static func label(source v: Int32) -> String { String(cString: dm_km_src_label(v)) }

    /// The full form ("A=j B=k ... SHAKE=space"), as launcher.DM_KEYMAP keeps it
    var string: String {
        var out = [CChar](repeating: 0, count: Int(dm_km_format_max()))   // any map's full form fits
        _ = key.withUnsafeBufferPointer { dm_km_write($0.baseAddress!, mouseSrc, mouseSpeed, mouseInvert, &out, out.count) }
        return String(cString: out)
    }
    func keys(_ target: Int) -> [Int] { (0..<KeyMap.slots).filter { key[$0] == UInt8(target) } }
    /// The binding (a key or a chord) presses target, which keeps no other unless add; returns the target that had the key before, if another (keymap.h km_bind)
    @discardableResult mutating func bind(_ target: Int, _ code: Int, add: Bool = false) -> Int? {
        let was = key.withUnsafeMutableBufferPointer { dm_km_bind($0.baseAddress!, Int32(target), Int32(code), add ? 1 : 0) }
        return was < 0 ? nil : Int(was)
    }
    mutating func clear(_ target: Int) { _ = key.withUnsafeMutableBufferPointer { dm_km_bind($0.baseAddress!, Int32(target), -1, 0) } }

    static let standard = KeyMap()
    /// The presets, the in-game panel's too: Default and the keymap files of the presets folder (keymap.h), read now: (name, map)
    static func presets() -> [(String, KeyMap)] {
        (0..<Int(dm_km_presets_load())).map { (String(cString: dm_km_preset_name(Int32($0))), KeyMap(String(cString: dm_km_preset_map(Int32($0))))) }
    }
    static var presetsFolder: URL { URL(fileURLWithPath: String(cString: dm_km_preset_dir())) }
    /// Saved as a keymap file named name (one of that name replaced); the file's path, or nil
    func savePreset(_ name: String) -> String? {
        var path = [CChar](repeating: 0, count: 1024)
        let r = key.withUnsafeBufferPointer { k in name.withCString { dm_km_preset_save(k.baseAddress!, mouseSrc, mouseSpeed, mouseInvert, $0, &path, path.count) } }
        return r == 0 ? String(cString: path) : nil
    }

    static func label(target: Int) -> String { String(cString: dm_km_target_label(Int32(target))) }
    static func label(key slot: Int) -> String { String(cString: dm_km_slot_label(Int32(slot))) }   // ⇧↑ for a chord
    static func bindable(_ code: Int) -> Bool { dm_km_bindable(Int32(code)) != 0 }

    /// The sheet's groups: keymap.h's (km_groups), the panel's and the keymap files' order
    static let groups: [(String, [Int])] = (0..<dm_km_groups()).map { g in
        (String(cString: dm_km_group_title(g)), (0..<dm_km_group_size(g)).map { Int(dm_km_group_target(g, $0)) })
    }
    /// A key pressed with the event's modifiers as a binding: the chord of a modifier held (keymap.h km_layer), else the key
    static func slot(_ code: Int, _ f: NSEvent.ModifierFlags) -> Int {
        Int(dm_km_slot(Int32(code), (f.contains(.shift) ? 1 : 0) | (f.contains(.control) ? 2 : 0) | (f.contains(.option) ? 4 : 0)))
    }
}

/// The section in the settings window: what the map is, and the button that opens it
struct KeyboardSection: View {
    var profileMap: String = ""
    @AppStorage("launcher.DM_KEYMAP") private var saved = ""
    @State private var editing = false
    @State private var presets: [(String, KeyMap)] = []
    private let fixed: String? = {
        let env = ProcessInfo.processInfo.environment
        let keys = ((env["DM_ENV_FILE_KEYS"] ?? "") + " " + (env["DM_ENV_LAUNCH_KEYS"] ?? "")).split(separator: " ")
        return keys.contains("DM_KEYMAP") ? env["DM_KEYMAP"] : nil
    }()

    private var summary: String {
        if fixed != nil { return "Set by an env file" }
        let m = KeyMap(UserDefaults.standard.object(forKey: "launcher.DM_KEYMAP") == nil ? profileMap : saved)
        return presets.first { $0.1 == m }?.0 ?? "Custom"
    }

    var body: some View {
        Section {
            LabeledContent("Keyboard and mouse") {
                HStack {
                    Text(summary).foregroundStyle(.secondary)
                    Button("Customize…") { editing = true }.disabled(fixed != nil)
                }
            }
        } footer: {
            Text("Choose which key or mouse button presses each button and stick direction, and what mouse movement moves. Keys are kept by their place on the keyboard.")
        }
        .sheet(isPresented: $editing, onDismiss: { presets = KeyMap.presets() }) { KeyMapSheet(saved: $saved) }
        .onAppear {
            if UserDefaults.standard.object(forKey: "launcher.DM_KEYMAP") == nil && !profileMap.isEmpty { saved = KeyMap(profileMap).string }
            presets = KeyMap.presets()
        }
    }
}

/// The map: one row per target, its key on a button; click it, then press a key
struct KeyMapSheet: View {
    @Binding var saved: String
    @Environment(\.dismiss) private var dismiss
    @State private var map = KeyMap()
    @State private var capturing: Int?
    @State private var adding = false   // the key awaited joins the target's (Add Key…)
    @State private var status = ""
    @State private var monitor: Any?
    @State private var presets: [(String, KeyMap)] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(KeyMap.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1, id: \.self) { t in row(t) }
                    }
                }
                Section {   // what mouse movement moves: per output, as the keys above are per button
                    ForEach(0..<KeyMap.outs, id: \.self) { o in mouseRows(o) }
                } header: { Text("Mouse and trackpad") } footer: {
                    Text("The mouse moves one output at a time: the one whose key is held, else the one set to Mouse. In the game a click captures the pointer; Esc lets it go.")
                }
            }
            .formStyle(.grouped)
            Text(status.isEmpty ? footnote : status)
                .font(.footnote).foregroundStyle(status.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 8)
            HStack {
                Menu("Presets") {
                    ForEach(presets.indices, id: \.self) { i in
                        Button(presets[i].0) { use(presets[i].1, "\(presets[i].0) map.") }
                    }
                    Divider()
                    Button("Save as Preset…") { savePreset() }
                    Button("Show Presets Folder") {
                        try? FileManager.default.createDirectory(at: KeyMap.presetsFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(KeyMap.presetsFolder)
                    }
                }
                .fixedSize()
                Spacer()
                Button("Done") { stop(); dismiss() }.keyboardShortcut(.defaultAction).disabled(capturing != nil)
            }
            .padding(20)
        }
        .frame(width: 460, height: 640)
        .onAppear { map = KeyMap(saved); presets = KeyMap.presets() }
        .onDisappear { stop() }
    }

    private var footnote: String { "Click a button, then press its key, or hold Shift, Control or Option and press a key; a mouse button counts as a key; right-click for No Key or Add Key…." }

    private func row(_ t: Int) -> some View {
        LabeledContent(KeyMap.label(target: t)) {
            let keys = map.keys(t)
            Button(capturing == t ? "Press a key…" : keys.isEmpty ? "None" : keys.map { KeyMap.label(key: $0) }.joined(separator: ", ")) {
                capturing == t ? stop() : start(t)
            }
            .frame(minWidth: 140)
            .foregroundStyle(keys.isEmpty && capturing != t ? .secondary : .primary)
            .contextMenu {
                Button("No Key") { map.clear(t); save("\(KeyMap.label(target: t)) has no key.") }
                Button("Add Key…") { start(t, add: true) }
            }
        }
    }

    /// An output's row under Mouse and trackpad: its source (None, Mouse, or a key + Mouse: while it is held); then its speed and Invert Y
    @ViewBuilder private func mouseRows(_ o: Int) -> some View {
        let name = KeyMap.outputs[o]
        LabeledContent(name) {
            Menu(capturing == KeyMap.srcSlot(o) ? "Press a key…" : KeyMap.label(source: map.mouseSrc[o])) {
                Button("None") { map.setSource(o, KeyMap.srcOff); save("\(name): no mouse.") }
                Button("Mouse") { map.setSource(o, KeyMap.srcMouse); save("\(name): Mouse; in the game a click captures the pointer.") }
                Button("Hold a Key or Button…") { start(KeyMap.srcSlot(o)) }
            }
            .frame(width: 150)
        }
        if map.mouseSrc[o] != KeyMap.srcOff {
            LabeledContent("Speed") {
                HStack {
                    speedSlider($map.mouseSpeed[o], name)
                    Toggle("Invert Y", isOn: Binding(get: { map.mouseInvert[o] != 0 }, set: { map.mouseInvert[o] = $0 ? 1 : 0; save("\(name): Invert Y \($0 ? "on" : "off").") }))
                }
            }
        }
    }

    /// A speed slider (0.2 to 6, tenths) with its value beside it, saved when the drag ends
    private func speedSlider(_ value: Binding<Float>, _ what: String) -> some View {
        HStack {
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float(($0 * 10).rounded() / 10) }), in: 0.2...10) { editing in
                if !editing { save(String(format: "%@: mouse speed %.1f.", what, value.wrappedValue)) }
            }
            .frame(width: 110)
            Text(String(format: "%.1f", value.wrappedValue)).monospacedDigit().frame(width: 30)
        }
    }

    private func use(_ m: KeyMap, _ note: String) { stop(); map = m; save(note) }

    /// The map as a keymap file in the presets folder, under a name the player types
    private func savePreset() {
        stop()
        let a = NSAlert()
        a.messageText = "Save as Preset"; a.informativeText = "A keymap file in the presets folder, for every game. A preset of the same name is replaced."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.placeholderString = "Name"
        a.accessoryView = f; a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let typed = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        if let path = map.savePreset(typed) { status = "Saved as \(typed) (\((path as NSString).lastPathComponent))."; presets = KeyMap.presets() }
        else { status = "Could not save the preset." }
    }

    /// The map as launcher.DM_KEYMAP: removed while it is the default, so the default of a later build applies
    private func save(_ note: String) {
        saved = map == .standard ? "" : map.string
        status = note
    }

    private func start(_ t: Int, add: Bool = false) {
        stop()
        capturing = t; adding = add
        status = t <= KeyMap.srcSlot(0) ? "Press the key to hold for the mouse to move the \(KeyMap.outputs[KeyMap.srcSlot(0) - t]) (Esc stops)." : "Press \(add ? "another" : "a") key for \(KeyMap.label(target: t)) (Esc stops)."
        var pending: Int?   // a modifier pressed: bound alone if let go before a key
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { e in
            guard let t = capturing else { return e }
            let f = e.modifierFlags
            if e.type == .leftMouseDown || e.type == .rightMouseDown || e.type == .otherMouseDown {   // a mouse button is an input as a key is (the click that started this has ended)
                pending = nil
                let b = Int(e.buttonNumber)
                if let k = KeyMap.mouseKey(b) { bind(t, KeyMap.slot(k, f)) } else { NSSound.beep() }
                return nil
            }
            let code = Int(e.keyCode)
            if e.type == .flagsChanged {
                // a Shift, Control or Option key: down, it may start a chord; up with no key between, it is the binding. ⌘, Caps Lock and fn are not bindable
                // that very key, left or right: the device-dependent bits (NX_DEVICE*KEYMASK), as keyboard_mac.h's kb_modifier_down
                let bits: [Int: UInt] = [56: 0x2, 60: 0x4, 59: 0x1, 62: 0x2000, 58: 0x20, 61: 0x40]
                guard let bit = bits[code] else { return e }
                let down = f.rawValue & bit != 0
                if down && t <= KeyMap.srcSlot(0) { bind(t, code) }   // an output's mouse key takes a modifier at once
                else if down { pending = code } else if pending == code { pending = nil; bind(t, code) }
                return nil
            }
            pending = nil
            if e.isARepeat { return nil }
            if f.contains(.command) { return e }   // ⌘ shortcuts stay the menus'
            if code == 53 && !f.contains(.shift) && !f.contains(.control) && !f.contains(.option) { stop(); status = ""; return nil }   // Esc: no change
            let slot = KeyMap.slot(code, f)
            if KeyMap.bindable(slot) { bind(t, slot) } else { NSSound.beep() }
            return nil
        }
    }

    private func bind(_ t: Int, _ code: Int, add: Bool? = nil) {
        if t <= KeyMap.srcSlot(0) {   // an output's mouse key: any key, which keeps its own button too
            let o = KeyMap.srcSlot(0) - t, k = Int32(code % KeyMap.keyCount)
            map.setSource(o, k); stop()
            save("\(KeyMap.outputs[o]): \(KeyMap.label(source: k)), while it is held.")
            return
        }
        let also = add ?? adding
        let was = map.bind(t, code, add: also)
        stop()
        let key = KeyMap.label(key: code), name = KeyMap.label(target: t)
        save(was.map { "\(key) is \(name)\(also ? " too" : "") now; \(KeyMap.label(target: $0)) \(map.keys($0).isEmpty ? "has no key" : "keeps its other keys")." } ?? "\(key) is \(name)\(also ? " too" : "").")
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil; capturing = nil; adding = false
    }
}
