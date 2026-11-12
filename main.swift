import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement
import IOKit.pwr_mgt

// MARK: - Global tap state (event tap callback runs on the main run loop)

var hyperDown = false
var otherKeyPressed = false
var downTime: UInt64 = 0
var tapPort: CFMachPort?

let kF18: Int64 = 79
let kVKEscape: CGKeyCode = 53
let hyperJSON = #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#
let restoreJSON = #"{"UserKeyMapping":[]}"#

func shouldSendEscape(heldMs: Double, otherKeyPressed: Bool, timeoutMs: Double = 200) -> Bool {
    !otherKeyPressed && heldMs < timeoutMs
}

/// Caps Lock remapping is active only for Meh / Hyper (not Default).
func isModifierMode(_ mode: String?) -> Bool {
    mode == "meh" || mode == "hyper"
}

let githubRepo = "maxmeis/MyMug"
let githubReleasesURL = URL(string: "https://github.com/\(githubRepo)/releases")!
let githubLatestAPI = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!

func currentAppVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
}

/// Compare dotted versions like "0.1" / "v1.2.3". Returns true if `remote` is newer than `local`.
func isRemoteNewer(_ remote: String, than local: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
    let a = parts(local)
    let b = parts(remote)
    let n = max(a.count, b.count)
    for i in 0..<n {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if y != x { return y > x }
    }
    return false
}

func showUpdateAlert(title: String, text: String, openURL: URL? = nil) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.alertStyle = .informational
    if openURL != nil {
        alert.addButton(withTitle: "Open GitHub")
        alert.addButton(withTitle: "OK")
    } else {
        alert.addButton(withTitle: "OK")
    }
    if alert.runModal() == .alertFirstButtonReturn, let openURL {
        NSWorkspace.shared.open(openURL)
    }
}

func checkForUpdates() {
    let local = currentAppVersion()
    var req = URLRequest(url: githubLatestAPI)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("MyMug/\(local)", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 15

    URLSession.shared.dataTask(with: req) { data, response, error in
        DispatchQueue.main.async {
            if let error {
                showUpdateAlert(
                    title: "Update check failed",
                    text: error.localizedDescription,
                    openURL: githubReleasesURL
                )
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // No releases published yet
            if status == 404 {
                showUpdateAlert(
                    title: "MyMug \(local)",
                    text: "No GitHub releases yet — you're on the latest build."
                )
                return
            }
            guard status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                showUpdateAlert(
                    title: "Update check failed",
                    text: "Unexpected response from GitHub (HTTP \(status)).",
                    openURL: githubReleasesURL
                )
                return
            }
            let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? githubReleasesURL
            if isRemoteNewer(tag, than: local) {
                showUpdateAlert(
                    title: "Update available",
                    text: "MyMug \(tag) is on GitHub (you have \(local)).",
                    openURL: htmlURL
                )
            } else {
                showUpdateAlert(
                    title: "MyMug \(local)",
                    text: "You're up to date with GitHub (\(tag))."
                )
            }
        }
    }.resume()
}

func runSelfTest() -> Never {
    precondition(shouldSendEscape(heldMs: 80, otherKeyPressed: false), "fast tap should escape")
    precondition(!shouldSendEscape(heldMs: 500, otherKeyPressed: false), "long hold should not escape")
    precondition(!shouldSendEscape(heldMs: 80, otherKeyPressed: true), "meh combo should not escape")
    precondition(!shouldSendEscape(heldMs: 200, otherKeyPressed: false), "boundary 200 should not escape")
    precondition(isRemoteNewer("0.2", than: "0.1"), "0.2 newer than 0.1")
    precondition(isRemoteNewer("v1.0.0", than: "0.9"), "v1.0.0 newer than 0.9")
    precondition(!isRemoteNewer("0.1", than: "0.1"), "same version not newer")
    precondition(!isRemoteNewer("0.1.0", than: "0.1"), "0.1.0 not newer than 0.1")
    print("selftest ok")
    exit(0)
}

func setRemap(_ json: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    p.arguments = ["property", "--set", json]
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        print("hidutil failed: \(error)")
    }
}

func postEscape() {
    for down in [true, false] {
        CGEvent(keyboardEventSource: nil, virtualKey: kVKEscape, keyDown: down)?.post(tap: .cghidEventTap)
    }
}

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = tapPort { CGEvent.tapEnable(tap: tap, enable: true) }
        hyperDown = false
        return Unmanaged.passUnretained(event)
    }
    let mode = UserDefaults.standard.string(forKey: "mode") ?? "meh"
    guard isModifierMode(mode) else { return Unmanaged.passUnretained(event) }

    if event.getIntegerValueField(.keyboardEventKeycode) == kF18 && (type == .keyDown || type == .keyUp) {
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 && !hyperDown {
                hyperDown = true
                otherKeyPressed = false
                downTime = DispatchTime.now().uptimeNanoseconds
            }
        } else if hyperDown {
            let heldMs = Double(DispatchTime.now().uptimeNanoseconds - downTime) / 1_000_000
            hyperDown = false
            if shouldSendEscape(heldMs: heldMs, otherKeyPressed: otherKeyPressed) { postEscape() }
        }
        return nil
    }

    if hyperDown && (type == .keyDown || type == .keyUp) {
        otherKeyPressed = true
        // Meh = ⌃⌥⌘; Hyper = ⌃⌥⇧⌘; Default = normal Caps Lock
        var flags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        if mode == "hyper" { flags.insert(.maskShift) }
        event.flags.insert(flags)
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Engine: remap only when tap is live; caffeine assertion

final class Engine: ObservableObject {
    @Published var tapActive = false
    @Published var caffeineOn = false
    private var remapOn = false
    private var retryTimer: Timer?
    private var caffeineAssertion: IOPMAssertionID = 0

    func start() {
        // Default: Meh mode, Caffeine off
        UserDefaults.standard.register(defaults: [
            "mode": "meh",
            "caffeine": false
        ])
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sync()
        }
        // Clear leftover Capsule/crash remap before deciding whether to remap again
        setRemap(restoreJSON)
        sync()
    }

    func sync() {
        let mode = UserDefaults.standard.string(forKey: "mode") ?? "meh"
        let modifierOn = isModifierMode(mode)
        let wantCaffeine = UserDefaults.standard.bool(forKey: "caffeine")
        let trusted = AXIsProcessTrusted()

        if modifierOn && trusted {
            if tapPort == nil { createTap() }
        }

        let tapReady = tapPort != nil && trusted
        tapActive = tapReady

        // CRITICAL: never leave Caps Lock remapped to F18 without a live tap
        let shouldRemap = modifierOn && tapReady
        if shouldRemap != remapOn {
            remapOn = shouldRemap
            setRemap(shouldRemap ? hyperJSON : restoreJSON)
        }

        if !modifierOn || !trusted {
            hyperDown = false
        }

        setCaffeine(wantCaffeine)
    }

    private func createTap() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: nil
        ) else { return }
        tapPort = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func setCaffeine(_ on: Bool) {
        if on && !caffeineOn {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "MyMug Caffeine" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                caffeineAssertion = id
                caffeineOn = true
            }
        } else if !on && caffeineOn {
            IOPMAssertionRelease(caffeineAssertion)
            caffeineAssertion = 0
            caffeineOn = false
        }
    }

    func shutdown() {
        setRemap(restoreJSON)
        remapOn = false
        setCaffeine(false)
        if let tap = tapPort {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tapPort = nil
        tapActive = false
        hyperDown = false
    }
}

let engine = Engine()

func setLaunchAtLogin(_ on: Bool) {
    do {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    } catch {
        print("launch at login failed: \(error)")
    }
}

// MARK: - UI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }
}

struct MenuContent: View {
    @AppStorage("mode") private var mode = "meh"
    @AppStorage("caffeine") private var caffeine = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ObservedObject var engine: Engine

    private var modifierOn: Bool { isModifierMode(mode) }

    var body: some View {
        Section("Hyperkey") {
            Picker("Hyperkey", selection: $mode) {
                Text("Default").tag("default")
                Text("Meh  ⌃⌥⌘").tag("meh")
                Text("Hyper  ⌃⌥⇧⌘").tag("hyper")
            }
            .labelsHidden()
            .pickerStyle(.inline)
            if !engine.tapActive && modifierOn {
                Button("Grant Accessibility…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }

        Section("Caffeine") {
            Toggle("Active", isOn: $caffeine)
        }

        Section {
            Button("Check for Updates…") { checkForUpdates() }
            Toggle("Start with Machine", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    setLaunchAtLogin(newValue)
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
        }

        Divider()
        Button("Quit MyMug") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@main
struct MyMugApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("caffeine") private var caffeine = false

    init() {
        if CommandLine.arguments.contains("--selftest") { runSelfTest() }
        // Migrate old mode labels → Default
        if let m = UserDefaults.standard.string(forKey: "mode"), m == "uppercase" || m == "deactivated" {
            UserDefaults.standard.set("default", forKey: "mode")
        }
        engine.start()
    }

    var body: some Scene {
        // Full mug = caffeine/keepalive on; empty mug = off
        MenuBarExtra {
            MenuContent(engine: engine)
        } label: {
            Image(systemName: caffeine ? "mug.fill" : "mug")
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel(caffeine ? "MyMug — Caffeine on" : "MyMug — Caffeine off")
        }
    }
}
