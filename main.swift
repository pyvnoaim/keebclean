// keebclean: lock the keyboard for cleaning, with a live mock keyboard in the terminal.
// Seizes the HID devices, so nothing reaches macOS: caps lock, fn, media/brightness keys included.
// Keys you press light up on screen and turn green once wiped, so you can see what you missed.
// Layout (ANSI/ISO) and key labels come from your macOS keyboard settings.
//
// build:  swiftc -O main.swift -o keebclean
// run:    keebclean [--timeout 60] [--mute]   (asks for sudo itself if macOS needs it)
//         blocks keyboard and trackpad/mouse; unlock: type "unlock" (auto-unlocks after 15 min by default)
//         --screen   also black out every display, to clean the screen
// setup:  automatic on the first lock and after updates (one password prompt each), or keebclean --install
//         keebclean --uninstall
// test:   keebclean --test                    (real presses shown, nothing locked: for screenshots)
// demo:   keebclean --demo                    (no lock, simulated presses; exits 0 if unlock works)
import AppKit
import AudioToolbox
import Carbon
import Foundation
import IOKit.hid

// MARK: layout
struct Key { let id: Int; let units: Double; let labels: [String]; var below: Int? = nil; var part = 0 }
func k(_ id: Int, _ units: Double, _ labels: String...) -> Key { Key(id: id, units: units, labels: labels) }

// HID usage -> macOS virtual key code, for asking the active layout what each key types
let vk: [Int: Int] = {
    var m = [Int: Int]()
    for (c, v) in zip("abcdefghijklmnopqrstuvwxyz", [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]) {
        m[Int(c.asciiValue! - 97) + 0x04] = v
    }
    for (i, v) in [18, 19, 20, 21, 23, 22, 26, 28, 25, 29].enumerated() { m[0x1E + i] = v }
    for (h, v) in [(0x2D, 27), (0x2E, 24), (0x2F, 33), (0x30, 30), (0x31, 42), (0x32, 42), (0x33, 41),
                   (0x34, 39), (0x35, 50), (0x36, 43), (0x37, 47), (0x38, 44), (0x64, 10)] { m[h] = v }
    return m
}()

let layoutData: Data? = {
    let src = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
    guard let p = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    return Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue() as Data
}()

func typed(_ code: Int) -> String? {
    guard let data = layoutData else { return nil }
    return data.withUnsafeBytes { raw -> String? in
        var dead: UInt32 = 0, len = 0, chars = [UniChar](repeating: 0, count: 4)
        let ok = UCKeyTranslate(raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self), UInt16(code),
                                UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &len, &chars)
        guard ok == noErr, len > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: len), up = s.uppercased()
        return up.count == 1 ? up : s  // ß stays ß, not SS
    }
}

func c(_ id: Int, _ us: String) -> Key { k(id, 1, vk[id].flatMap(typed) ?? us) }
func letters(_ s: String) -> [Key] { s.map { c(Int($0.asciiValue! - 97) + 0x04, $0.uppercased()) } }

let FN = 0x1_0003  // fn/globe arrives on Apple vendor pages, give it one id
let TP = 0x2_0000  // the trackpad, drawn under the keyboard and cleaned like a key

// MacBook layout in key units, every row sums to 15.
// Apple ISO hardware reports the key left of 1 as 0x64 and the key next to left shift as 0x35.
func layout(iso: Bool) -> [[Key]] {
    let fnRow = [k(0x29, 1.5, "esc")] + (1...12).map { k(0x39 + $0, 1, "F\($0)") } + [k(-1, 1.5, "◉")]
    let digits = "1234567890".enumerated().map { c(0x1E + $0.offset, String($0.element)) }
    let bottom = [k(FN, 1, "fn"), k(0xE0, 1, "⌃"), k(0xE2, 1, "⌥"), k(0xE3, 1.25, "⌘"), k(0x2C, 5.5, ""),
                  k(0xE7, 1.25, "⌘"), k(0xE6, 1, "⌥"), k(0x50, 1, "←"),
                  Key(id: 0x52, units: 1, labels: ["↑"], below: 0x51), k(0x4F, 1, "→")]
    let tab = k(0x2B, 1.5, "⇥ tab", "tab", "⇥"), caps = k(0x39, 1.75, "⇪ caps", "caps", "⇪")
    let rshift = k(0xE5, 2.75, "shift ⇧", "shift", "⇧"), delete = k(0x2A, 2, "delete", "⌫")
    let punct = [c(0x36, ","), c(0x37, "."), c(0x38, "/")]
    if iso {
        return [
            fnRow,
            [c(0x64, "§")] + digits + [c(0x2D, "-"), c(0x2E, "="), delete],
            [tab] + letters("qwertyuiop") + [c(0x2F, "["), c(0x30, "]"), Key(id: 0x28, units: 1.5, labels: ["⏎"], part: 1)],
            [caps] + letters("asdfghjkl") + [c(0x33, ";"), c(0x34, "'"), c(0x32, "\\"), Key(id: 0x28, units: 1.25, labels: [""], part: 2)],
            [k(0xE1, 1.25, "⇧ shift", "shift", "⇧"), c(0x35, "`")] + letters("zxcvbnm") + punct + [rshift],
            bottom,
        ]
    }
    return [
        fnRow,
        [c(0x35, "`")] + digits + [c(0x2D, "-"), c(0x2E, "="), delete],
        [tab] + letters("qwertyuiop") + [c(0x2F, "["), c(0x30, "]"), k(0x31, 1.5, "\\")],
        [caps] + letters("asdfghjkl") + [c(0x33, ";"), c(0x34, "'"), k(0x28, 2.25, "⏎ return", "return", "⏎")],
        [k(0xE1, 2.25, "⇧ shift", "shift", "⇧")] + letters("zxcvbnm") + punct + [rshift],
        bottom,
    ]
}

let rows = layout(iso: KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO)
var names = Dictionary(rows.joined().map { ($0.id, $0.labels.last!) }, uniquingKeysWith: { a, _ in a })
names[0x2C] = "space"; names[0x51] = "↓"; names[0x28] = "⏎"; names[TP] = "trackpad"
let lockable = Set(rows.joined().flatMap { [$0.id] + ($0.below.map { [$0] } ?? []) }.filter { $0 >= 0 } + [TP])
// "unlock" by what the keys type in your layout, not by US position
let unlockSeq = "unlock".map { ch in
    rows.joined().first { vk[$0.id] != nil && $0.labels[0].lowercased() == String(ch) }?.id ?? Int(ch.asciiValue! - 97) + 0x04
}

// MARK: state
let args = CommandLine.arguments
let demo = args.contains("--demo")
let test = args.contains("--test")  // listen without seizing, keys still reach macOS
let screenMode = args.contains("--screen")
// the sudo rule lets anything running as you start keebclean as root without a password, so as root only
// the lock itself is allowed: test mode would be a keylogger that skips Input Monitoring, and the timeout is capped
let viaSudo = getuid() == 0 && ProcessInfo.processInfo.environment["SUDO_USER"] != nil
if viaSudo, let bad = ["--test", "--install", "--uninstall"].first(where: args.contains) {
    print("\(bad) can't run through sudo, run keebclean \(bad) as yourself"); exit(1)
}
if viaSudo && (isatty(STDIN_FILENO) == 0 || isatty(STDOUT_FILENO) == 0) {  // redirected output would log every key
    print("keebclean only runs as root in a terminal"); exit(1)
}
let timeoutArg = args.firstIndex(of: "--timeout").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
    .map { viaSudo ? min($0, 30 * 60) : $0 }
// safety net: typing "unlock" is the only way out, so a real lock always ends eventually
var deadline: Date? = (timeoutArg ?? (demo || test ? nil : 15 * 60)).map { Date().addingTimeInterval($0) }
var down = Set<Int>(), cleaned = Set<Int>(), lastPress = [Int: Date](), pressCount = [Int: Int]()
var presses = 0, last = "-", typedKeys = [Int]()
var seized: [IOHIDDevice] = [], lockedNames: [String] = [], unlockedNames: [String] = []
var origTerm = termios()

// MARK: drawing
typealias RGB = (Int, Int, Int)
// monochrome: untouched keys dim grey, cleaned keys get brighter with every wipe, held keys filled white
let dimBorder: RGB = (104, 104, 108), dimLabel: RGB = (150, 150, 154), ghost: RGB = (72, 72, 76)
let cleanBorder: RGB = (158, 158, 163), cleanLabel: RGB = (205, 205, 209)
let accent: RGB = (238, 238, 240), flash: RGB = (255, 255, 255), dark: RGB = (16, 16, 18)
let muted: RGB = (140, 140, 144), bright: RGB = (232, 232, 235)
let fade = 0.45
let R = "\u{1B}[0m", B = "\u{1B}[1m"
func fg(_ c: RGB) -> String { "\u{1B}[38;2;\(c.0);\(c.1);\(c.2)m" }
func bg(_ c: RGB) -> String { "\u{1B}[48;2;\(c.0);\(c.1);\(c.2)m" }
func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
    (a.0 + Int(Double(b.0 - a.0) * t), a.1 + Int(Double(b.1 - a.1) * t), a.2 + Int(Double(b.2 - a.2) * t))
}
func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: max(0, n)) }
func fit(_ labels: [String], _ w: Int) -> String {
    labels.first { $0.count <= ($0.count == 1 ? w : w - 2) } ?? String(labels.last!.prefix(w))
}

func style(_ id: Int, _ now: Date) -> (border: RGB, label: RGB, held: Bool) {
    if id < 0 { return (ghost, ghost, false) }  // Touch ID: not part of the keyboard, can't be locked
    let age = now.timeIntervalSince(lastPress[id] ?? .distantPast)
    if down.contains(id) || (id == TP && age < 0.15) { return (flash, dark, true) }  // trackpad: lit while touched
    guard cleaned.contains(id) else { return (dimBorder, dimLabel, false) }
    let heat = min(1, Double((pressCount[id] ?? 1) - 1) / 4)  // full white after 5 wipes
    let (b, l) = (mix(cleanBorder, flash, heat), mix(cleanLabel, flash, heat))
    return age < fade ? (mix(flash, b, age / fade), mix(flash, l, age / fade), false) : (b, l, false)
}

// one keycap, 3 lines tall, w columns wide. The heavy bottom edge reads as a raised cap;
// held keys flip it (heavy top, light bottom) and fill, so they look pushed in.
func cap(_ key: Key, _ w: Int, _ u: Double, _ now: Date) -> [String] {
    let inner = w - 2
    let up = style(key.id, now), d = key.below.map { style($0, now) }
    var s = up
    if let below = key.below, let d {  // shared ↑↓ cap: lit while either is held, "cleaned" only once both are
        let both = cleaned.contains(key.id) && cleaned.contains(below)
        s = up.held || d.held ? (flash, up.label, true) : (both ? cleanBorder : dimBorder, up.label, false)
    }
    let (tl, tr, th, bl, br, bh) = s.held ? ("┍", "┑", "━", "╰", "╯", "─") : ("╭", "╮", "─", "┕", "┙", "━")
    let paint = fg(s.border), fill = s.held ? bg(accent) + fg(dark) + B : fg(s.label)
    func mid(_ text: String, _ n: Int) -> String {  // centered text in n columns, filled while held
        let l = (n - text.count) / 2
        return fill + rep(" ", l) + text + rep(" ", n - text.count - l) + R + paint
    }
    let top = paint + tl + rep(th, inner) + tr + R, bottom = paint + bl + rep(bh, inner) + br + R
    if let d {  // ↑ and ↓ share one cap, each arrow lit on its own
        func arrow(_ a: String, _ st: (border: RGB, label: RGB, held: Bool)) -> String {
            (st.held ? bg(accent) + fg(dark) + B : fg(st.label)) + a + R + paint
        }
        let gap = inner >= 3 ? " " : ""
        let l = (inner - 2 - gap.count) / 2
        let body = rep(" ", l) + arrow("↑", up) + gap + arrow("↓", d) + rep(" ", inner - 2 - gap.count - l)
        return [top, paint + "│" + body + "│" + R, bottom]
    }
    let label = fit(key.labels, inner)
    switch key.part {
    case 1:  // ISO return, top half: notch where the narrower bottom half hangs down
        let wb = Int((15 * u).rounded()) - Int((13.75 * u).rounded()) - 1
        return [top, paint + "│" + mid(label, inner) + "│" + R,
                paint + bl + rep(bh, w - wb - 1) + (s.held ? "╮" : "┑") + mid("", wb - 2) + "│" + R]
    case 2:  // ISO return, bottom half: open at the top
        return [paint + "│" + mid("", inner) + "│" + R, paint + "│" + mid("", inner) + "│" + R, bottom]
    default:
        return [top, paint + "│" + mid(label, inner) + "│" + R, bottom]
    }
}

// visible width of a styled string
func vis(_ s: String) -> Int { s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression).count }
func spread(_ l: String, _ r: String, _ w: Int) -> String { l + rep(" ", w - vis(l) - vis(r)) + r }

var lastDraw = Date.distantPast
func draw() {
    let now = Date()
    lastDraw = now
    var ws = winsize()
    _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws)
    let cols = ws.ws_col > 0 ? Int(ws.ws_col) : 80, lines = ws.ws_row > 0 ? Int(ws.ws_row) : 24
    let u = cols >= 94 ? 6.0 : cols >= 78 ? 5.0 : 4.0
    let width = Int(15 * u) - 1  // keyboard's visible width, without the trailing gap

    let (dot, mode) = demo ? (bright, "demo") : test ? (bright, "test mode") : (bright, "locked")
    let hint = demo ? "presses are simulated" : test ? "keys still reach your Mac" : "nothing reaches your Mac"
    var out = [spread(fg(bright) + B + "keebclean" + R + fg(muted) + "  " + hint + R, fg(dot) + "● " + B + mode + R, width), ""]

    for row in rows {
        var l = ["", "", ""], cum = 0.0
        for key in row {  // cumulative rounding keeps every row's right edge aligned
            let start = Int((cum * u).rounded()), end = Int(((cum + key.units) * u).rounded())
            let c = cap(key, end - start - 1, u, now)
            for i in 0..<3 { l[i] += c[i] + " " }
            cum += key.units
        }
        out += l
    }
    let tpW = Int((6 * u).rounded()) - 1
    out.append("")
    out += cap(Key(id: TP, units: 6, labels: ["trackpad"]), tpW, u, now).map { rep(" ", (width - tpW) / 2) + $0 }

    var stats = fg(bright) + "\(presses)" + fg(muted) + " presses   last " + fg(bright) + last
    if let d = deadline, !demo {
        let left = max(0, Int(d.timeIntervalSince(now).rounded(.up)))
        stats += fg(muted) + "   auto-unlock " + fg(bright) + String(format: "%d:%02d", left / 60, left % 60)
    }
    stats += R
    let count = "  " + fg(bright) + B + "\(cleaned.count)" + R + fg(muted) + "/\(lockable.count)" + R
    let barW = max(8, width - vis(stats) - vis(count) - 12)
    let done = cleaned.count * barW / lockable.count
    out.append("")
    out.append(spread(fg(muted) + "cleaned  " + fg(accent) + rep("━", done) + fg(ghost) + rep("━", barW - done) + R + count, stats, width))
    if !demo { out.append(fg(muted) + (test ? "watching " : "locked   ") + lockedNames.joined(separator: ", ") + R) }
    if !unlockedNames.isEmpty { out.append(fg(bright) + "not locked  " + unlockedNames.joined(separator: ", ") + R) }

    let m = (0...unlockSeq.count).last { typedKeys.suffix($0).elementsEqual(unlockSeq.prefix($0)) } ?? 0
    let word = "unlock".enumerated().map { ($0.offset < m ? fg(accent) + B : fg(bright)) + String($0.element) + R }.joined()
    out.append("")
    out.append(fg(muted) + "type " + word + fg(muted) + " to unlock" + R)

    let topPad = max(0, (lines - out.count) / 2), padN = max(0, (cols - width) / 2)
    let pad = rep(" ", padN)
    let frame = "\u{1B}[H" + rep("\u{1B}[K\n", topPad) + out.map { pad + $0 + "\u{1B}[K" }.joined(separator: "\n") + "\u{1B}[J"
    print(frame, terminator: "")
    fflush(stdout)
}

// MARK: input
func restoreTerm() {
    CGAssociateMouseAndMouseCursorPosition(1)
    var t = origTerm
    tcflush(STDIN_FILENO, TCIFLUSH)  // test mode: don't hand what you typed to the shell
    tcsetattr(STDIN_FILENO, TCSANOW, &t)
    print("\u{1B}[?25h\u{1B}[?1049l", terminator: "")
    fflush(stdout)
}

func finish(_ reason: String, _ code: Int32) -> Never {
    for d in seized { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone)) }
    restoreTerm()
    print("\(reason): \(presses) presses, \(cleaned.count)/\(lockable.count) keys cleaned")
    exit(code)
}

func handle(_ id: Int, _ isDown: Bool) {
    if isDown {
        down.insert(id); presses += 1; lastPress[id] = Date(); pressCount[id, default: 0] += 1
        play(pressFor[id], pressGeneric)
        if lockable.contains(id) { cleaned.insert(id) }
        last = names[id] ?? String(format: "media 0x%X", id & 0xFFFF)
        typedKeys = Array((typedKeys + [id]).suffix(unlockSeq.count))
        if typedKeys == unlockSeq { finish("unlocked", 0) }
    } else {
        down.remove(id)
        play(releaseFor[id], releaseGeneric)
    }
    draw()
}

// switch recordings next to the binary in sounds/: press-generic*.wav (random pick per press), release-generic.wav,
// and press-/release-space|enter|backspace.wav for those keys. wav/aiff/caf; a missing folder just means silence.
var pressGeneric: [SystemSoundID] = [], releaseGeneric: [SystemSoundID] = []
var pressFor: [Int: [SystemSoundID]] = [:], releaseFor: [Int: [SystemSoundID]] = [:]

func makeSounds() {
    let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? args[0]).resolvingSymlinksInPath()
    let dir = exe.deletingLastPathComponent().appendingPathComponent("sounds")
    let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { ["wav", "aif", "aiff", "caf"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    func load(_ prefix: String) -> [SystemSoundID] {
        files.filter { $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(prefix) }.compactMap {
            var id: SystemSoundID = 0
            return AudioServicesCreateSystemSoundID($0 as CFURL, &id) == noErr ? id : nil
        }
    }
    pressGeneric = load("press-generic"); releaseGeneric = load("release-generic")
    for (name, id) in [("space", 0x2C), ("enter", 0x28), ("backspace", 0x2A)] {
        pressFor[id] = load("press-\(name)"); releaseFor[id] = load("release-\(name)")
    }
}

func play(_ special: [SystemSoundID]?, _ generic: [SystemSoundID]) {
    if let snd = (special?.isEmpty == false ? special! : generic).randomElement() { AudioServicesPlaySystemSound(snd) }
}

// Trackpads are multitouch devices that can't be seized like keyboards, so pointer events (move, click,
// scroll, gestures) are dropped in an event tap instead, and the cursor is frozen. Test mode only listens.
var tap: CFMachPort?
let pointerTypes: [UInt32] = [1, 2, 3, 4, 5, 6, 7, 18, 19, 20, 22, 25, 26, 27, 29, 30, 31, 32, 34]

func pointerSeen() {
    let now = Date()
    if now.timeIntervalSince(lastPress[TP] ?? .distantPast) > 0.5 { last = "trackpad"; pressCount[TP, default: 0] += 1 }
    lastPress[TP] = now
    cleaned.insert(TP)
}

func startPointerTap() -> Bool {
    let cb: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        } else if pointerTypes.contains(type.rawValue) {
            pointerSeen()
            if !test { return nil }
        }
        return Unmanaged.passUnretained(event)
    }
    let mask = pointerTypes.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1)) }
    guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                    options: test ? .listenOnly : .defaultTap,
                                    eventsOfInterest: mask, callback: cb, userInfo: nil) else { return false }
    tap = t
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    if !test { CGAssociateMouseAndMouseCursorPosition(0) }
    return true
}

// black borderless windows above everything on every display; keys stay locked, "unlock" still works
var blackWindows: [NSWindow] = []
func blackOut() {
    NSApplication.shared.setActivationPolicy(.accessory)
    for screen in NSScreen.screens {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: true)
        w.backgroundColor = .black
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hint = NSTextField(labelWithString: "type unlock to exit")
        hint.textColor = NSColor(white: 0.2, alpha: 1)
        hint.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        hint.sizeToFit()
        hint.setFrameOrigin(NSPoint(x: (screen.frame.width - hint.frame.width) / 2, y: 40))
        w.contentView?.addSubview(hint)
        w.orderFrontRegardless()
        blackWindows.append(w)
    }
    NSApp.activate(ignoringOtherApps: true)
    NSCursor.hide()
}

// password-free locking: a root-owned copy plus a sudo rule for exactly that file.
// Root-owned so nothing running as you can swap the binary and get root through the rule.
// /Library/PrivilegedHelperTools is root-owned on every Mac; /usr/local isn't on Intel Macs with Homebrew
let installDir = "/Library/PrivilegedHelperTools/keebclean", installed = installDir + "/keebclean"
let me = URL(fileURLWithPath: Bundle.main.executablePath ?? args[0]).resolvingSymlinksInPath()

func sudo(_ a: [String], quiet: Bool = false) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    p.arguments = a
    if quiet { p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice }
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

// one password prompt: root-owned copy, hash-pinned sudo rule, /usr/local/bin link
func install() -> Bool {
    let src = me.deletingLastPathComponent().path, user = ProcessInfo.processInfo.environment["SUDO_USER"] ?? NSUserName()
    let script = """
    set -e
    install -d -o root -g wheel -m 755 \(installDir) \(installDir)/sounds
    install -o root -g wheel -m 755 '\(me.path)' \(installed)
    # every folder on the way must be root-owned and writable only by root, or the binary could be swapped
    for d in / /Library /Library/PrivilegedHelperTools \(installDir); do
      if [ "$(stat -f %u "$d")" != 0 ] || [ $(( 0$(stat -f %Lp "$d") & 022 )) != 0 ]; then
        echo "refusing: $d is not root-owned or is writable by others" >&2; exit 1
      fi
    done
    rm -f \(installDir)/sounds/*
    for f in '\(src)'/sounds/*; do  # skip symlinks: they could pull protected files into a world-readable place
      if [ -f "$f" ] && [ ! -L "$f" ]; then install -o root -g wheel -m 644 "$f" \(installDir)/sounds/; fi
    done
    # pin the rule to this exact binary: sudo refuses anything else at that path
    h=$(openssl dgst -sha256 -binary \(installed) | base64)
    t=$(mktemp)
    echo "\(user) ALL=(root) NOPASSWD: sha256:$h \(installed)" > "$t"
    visudo -cf "$t" >/dev/null
    install -o root -g wheel -m 440 "$t" /etc/sudoers.d/keebclean
    rm -f "$t"
    # put keebclean on PATH, without touching a link Homebrew already made
    install -d -m 755 /usr/local/bin
    [ -e /usr/local/bin/keebclean ] || ln -s \(installed) /usr/local/bin/keebclean
    """
    guard sudo(["/bin/sh", "-c", script]) else { print("setup failed, nothing changed in sudo"); return false }
    let ok = sudo(["-n", "-l", installed], quiet: true)
    print(ok ? "set up: keebclean now locks without a password"
             : "set up, but sudo still asks for a password: /etc/sudoers.d may not be read on this Mac")
    return ok
}
if args.contains("--install") { exit(install() ? 0 : 1) }
if args.contains("--uninstall") {
    let link = "/usr/local/bin/keebclean"  // only remove the link if it's ours
    let ok = sudo(["/bin/sh", "-c", "rm -f /etc/sudoers.d/keebclean && rm -rf \(installDir) && "
                   + "if [ \"$(readlink \(link))\" = \(installed) ]; then rm -f \(link); fi"])
    print(ok ? "uninstalled" : "uninstall failed")
    exit(ok ? 0 : 1)
}

func reexecAsRoot() -> Never {
    var cargs = (["sudo", installed] + args.dropFirst()).map { strdup($0) } + [nil]
    execv("/usr/bin/sudo", &cargs)
    print("could not run sudo"); exit(1)
}

signal(SIGINT) { _ in restoreTerm(); exit(130) }
signal(SIGTERM) { _ in restoreTerm(); exit(143) }

if demo {
    // ponytail: demo doubles as the self-check, random presses then "unlock"; nonzero exit = something broke
    precondition([true, false].allSatisfy { layout(iso: $0).allSatisfy { $0.reduce(0) { $0 + $1.units } == 15 } },
                 "a row doesn't sum to 15 units")
    let all = Array(lockable)
    var script = (0..<60).flatMap { _ -> [(Int, Bool)] in let k = all.randomElement()!; return [(k, true), (k, false)] }
    script += unlockSeq.flatMap { [($0, true), ($0, false)] }
    deadline = Date().addingTimeInterval(Double(script.count) * 0.06 + 2)
    Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
        if !script.isEmpty { let (k, d) = script.removeFirst(); handle(k, d) }
    }
} else {
    // locking runs as the installed root-owned copy. First run, or after an update, set it up (one password prompt).
    if !test && getuid() != 0 {
        if !FileManager.default.contentsEqual(atPath: installed, andPath: me.path) {
            print(FileManager.default.fileExists(atPath: installed)
                  ? "keebclean changed, updating its password-free setup from \(me.path) (asks for your password once)..."
                  : "first run: setting up password-free locking from \(me.path) (asks for your password once)...")
            guard install() else { exit(1) }
        }
        reexecAsRoot()
    }
    if !test {
        print("hands off the keyboard, locking in 1s...")
        Thread.sleep(forTimeInterval: 1)
    }  // let the Enter key-up land first, or macOS sees it stuck down
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatchingMultiple(m, [
        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
        [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer, kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl],
    ] as CFArray)
    let onValue: IOHIDValueCallback = { _, _, _, value in
        let el = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(el)), usage = Int(IOHIDElementGetUsage(el))
        let id: Int
        switch page {
        case 0x07 where (0x04...0xE7).contains(usage): id = usage
        case 0xFF where usage == 3, 0xFF00 where usage == 3: id = FN
        case 0x0C where usage != 0: id = 0x0C_0000 | usage
        default: return
        }
        handle(id, IOHIDValueGetIntegerValue(value) != 0)
    }
    // seize each device on its own: some (headphone remote, ...) are held exclusively by their driver,
    // and one refusal must not block the rest
    var failed: [(name: String, r: IOReturn, keyboard: Bool)] = []
    for dev in (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? [] {
        let name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "unknown"
        let keyboard = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int == kHIDPage_GenericDesktop
        let r = IOHIDDeviceOpen(dev, IOOptionBits(test ? kIOHIDOptionsTypeNone : kIOHIDOptionsTypeSeizeDevice))
        guard r == kIOReturnSuccess else { failed.append((name, r, keyboard)); continue }
        IOHIDDeviceRegisterInputValueCallback(dev, onValue, nil)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        seized.append(dev)
        if keyboard && !lockedNames.contains(name) { lockedNames.append(name) }
    }
    unlockedNames = failed.filter { $0.keyboard && !lockedNames.contains($0.name) }
        .map { "\($0.name) (0x\(String(UInt32(bitPattern: $0.r), radix: 16)))" }
    if lockedNames.isEmpty {
        finish("could not \(test ? "read" : "lock") any keyboard: \(unlockedNames.isEmpty ? "none found" : unlockedNames.joined(separator: ", "))"
               + (test ? ", allow your terminal in Settings > Privacy & Security > Input Monitoring" : ""), 1)
    }
    if startPointerTap() { lockedNames.append("trackpad") }
    else { unlockedNames.append("trackpad (allow your terminal in Settings > Privacy & Security > Accessibility)") }
}

if !args.contains("--mute") { makeSounds() }
tcgetattr(STDIN_FILENO, &origTerm)
var raw = origTerm
raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
tcsetattr(STDIN_FILENO, TCSANOW, &raw)
print("\u{1B}[?1049h\u{1B}[?25l", terminator: "")  // alternate screen, hidden cursor
// 30 fps while a key is fading out, otherwise just tick the countdown
Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
    let now = Date()
    if let d = deadline, now >= d { finish(demo ? "demo FAILED, never unlocked" : "timed out, unlocked", demo ? 1 : 0) }
    let fading = lastPress.values.contains { now.timeIntervalSince($0) < fade }
    if fading || now.timeIntervalSince(lastDraw) > 0.5 { draw() }
}
draw()
if screenMode && !demo {
    blackOut()
    NSApp.run()
} else {
    CFRunLoopRun()
}
