import AppKit
import IOKit.pwr_mgt
import Darwin

// 所有功能默认关闭，由用户在菜单栏主动开启。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var summaryItem: NSMenuItem?
    private var timer: Timer?
    private var displayEnabled = false
    private var lidEnabled = false
    private var lockOnClose: Bool {
        get { defaults.bool(forKey: "合盖时锁定屏幕") }
        set { defaults.set(newValue, forKey: "合盖时锁定屏幕") }
    }
    private var busy = false
    private var enableIssue = ""
    private var watchdogPID: pid_t?
    private var lastWatchdogCheck = Date.distantPast
    private var lastClosed = false
    private var displaySleepPending = false
    private var displaySleepFailed = false
    private var locked = false
    private var displayAssertion: IOPMAssertionID = 0
    private var activityAssertion: IOPMAssertionID = 0
    private var lastActivity = Date.distantPast
    private let defaults = UserDefaults.standard
    private let recoveryKey = "待恢复的原休眠设置"
    private let loginHandle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY)

    private func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    private var lockFunction: (@convention(c) () -> Int32)? {
        guard let handle = loginHandle, let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count <= 1 else {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "合盖不休眠")
        lastClosed = lidClosed() ?? false
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(didLock), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        center.addObserver(self, selector: #selector(didUnlock), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        refreshMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        if defaults.object(forKey: recoveryKey) != nil {
            if let original = defaults.object(forKey: recoveryKey) as? Int, (try? sleepValue()) == original {
                defaults.removeObject(forKey: recoveryKey)
                refreshMenu()
            } else {
                alert("上次的休眠设置需要恢复", "请点击菜单中的“恢复上次的休眠设置”。完成后再开启功能。")
            }
        }
    }

    @objc private func didLock() {
        locked = true
        tick()
        if lidEnabled && lidClosed() == true { turnDisplayOffAfterLock() }
    }
    @objc private func didUnlock() { locked = false; releaseDisplay() }

    private func tick() {
        defer { updateSummary() }
        if lidEnabled && !busy && Date().timeIntervalSince(lastWatchdogCheck) >= 2 {
            lastWatchdogCheck = Date()
            if let pid = watchdogPID, kill(pid, 0) == -1 && errno == ESRCH {
                watchdogPID = nil
                restoreSleep(quitAfter: false)
            }
        }
        guard let closed = lidClosed() else {
            releaseDisplay()
            return
        }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], let isLocked = session["CGSSessionScreenIsLocked"] as? Bool {
            locked = isLocked
        }
        let justClosed = closed && !lastClosed
        // 先记录状态，避免锁屏通知再次处理同一次合盖。
        lastClosed = closed
        if justClosed && lidEnabled {
            releaseDisplay()
            if lockOnClose && lockFunction?() != 0 {
                // 锁定失败时停止保持运行，避免以未锁定状态继续工作。
                restoreSleep(quitAfter: false, lockFailure: true)
            } else {
                turnDisplayOffAfterLock()
            }
        }
        guard displayEnabled && locked && !closed else { releaseDisplay(); return }
        if displayAssertion == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "锁屏保持亮屏" as CFString, &displayAssertion)
            if result != kIOReturnSuccess {
                displayEnabled = false
                refreshMenu()
                alert("保持亮屏没有开启", "macOS 没有接受保持亮屏请求。请关闭后重新尝试。")
                return
            }
        }
        // 锁屏后的熄屏可能不遵循普通空闲计时；仅在开盖且锁定时续期。
        if Date().timeIntervalSince(lastActivity) >= 2 {
            _ = IOPMAssertionDeclareUserActivity("锁屏界面保持可见" as CFString, kIOPMUserActiveLocal, &activityAssertion)
            lastActivity = Date()
        }
    }

    private func turnDisplayOffAfterLock() {
        requestDisplaySleep()
        // 锁屏界面可能在第一次熄屏请求后亮起；仅对仍合盖的状态补发。
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.requestDisplaySleep()
            }
        }
    }

    private func requestDisplaySleep() {
        guard lidEnabled, lidClosed() == true, !displaySleepPending else { return }
        releaseDisplay()
        displaySleepPending = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        // 只请求显示器立即休眠，不修改设置，也不让 Mac 休眠。
        process.arguments = ["displaysleepnow"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                guard let self else { return }
                self.displaySleepPending = false
                self.displaySleepFailed = task.terminationStatus != 0
                self.refreshMenu()
            }
        }
        do { try process.run() }
        catch {
            displaySleepPending = false
            displaySleepFailed = true
            refreshMenu()
        }
    }

    private func releaseDisplay() {
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        if activityAssertion != 0 { IOPMAssertionRelease(activityAssertion); activityAssertion = 0 }
        lastActivity = .distantPast
    }

    private func item(_ title: String, _ action: Selector?, checked: Bool = false, enabled: Bool = true) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self
        result.state = checked ? .on : .off
        result.isEnabled = enabled
        return result
    }

    private var summary: String {
        if busy { return "正在等待系统授权…" }
        if !lidEnabled && defaults.object(forKey: recoveryKey) != nil { return "需要恢复上次的休眠设置" }
        if displaySleepFailed && lidEnabled { return "立即熄屏请求失败，请反馈" }
        if displayEnabled && lidEnabled { return "两项功能均已开启" }
        if displayEnabled { return "仅锁屏保持亮屏已开启" }
        if lidEnabled { return "仅合盖继续运行已开启" }
        return "两项功能均已关闭"
    }

    private func updateSummary() {
        summaryItem?.title = summary
        let active = displayEnabled || lidEnabled
        statusItem.button?.title = active ? " ·" : ""
        statusItem.button?.toolTip = "合盖不休眠：\(summary)"
        statusItem.button?.setAccessibilityLabel("合盖不休眠：\(summary)")
    }

    func menuWillOpen(_ menu: NSMenu) { updateSummary() }

    private func refreshMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let heading = item("合盖不休眠", nil, enabled: false)
        heading.attributedTitle = NSAttributedString(string: "合盖不休眠", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        menu.addItem(heading)
        summaryItem = item(summary, nil, enabled: false)
        menu.addItem(summaryItem!)
        menu.addItem(.separator())
        let needsRecovery = !lidEnabled && defaults.object(forKey: recoveryKey) != nil
        menu.addItem(item("开启全部功能", #selector(enableAll), enabled: !busy && !needsRecovery && !(displayEnabled && lidEnabled)))
        menu.addItem(item("全部关闭，恢复正常休眠", #selector(disableAll), enabled: !busy && (displayEnabled || lidEnabled || needsRecovery)))
        menu.addItem(.separator())
        menu.addItem(item("锁屏保持亮屏", #selector(toggleDisplay), checked: displayEnabled, enabled: !busy))
        menu.addItem(item("开盖锁屏后，锁屏界面持续亮着", nil, enabled: false))
        menu.addItem(item("合盖继续运行", #selector(toggleLid), checked: lidEnabled, enabled: !busy && !needsRecovery))
        menu.addItem(item(lockOnClose ? "合盖立即黑屏并锁定，任务继续" : "合盖立即黑屏，任务继续", nil, enabled: false))
        menu.addItem(item("合盖时锁定屏幕", #selector(toggleLockOnClose), checked: lockOnClose, enabled: !busy && lockFunction != nil))
        if needsRecovery {
            menu.addItem(item("恢复上次的休眠设置…", #selector(recover), enabled: !busy))
        }
        menu.addItem(.separator())
        menu.addItem(item("现在锁定屏幕", #selector(lockNow), enabled: !busy && lockFunction != nil))
        menu.addItem(item("使用说明…", #selector(showHelp)))
        menu.addItem(item("关于合盖不休眠…", #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("恢复休眠并退出", #selector(quit), enabled: !busy))
        statusItem.menu = menu
        updateSummary()
    }

    @objc private func enableAll() {
        guard !busy else { return }
        if lidEnabled { displayEnabled = true; tick(); refreshMenu() }
        else { enableLid(alsoDisplay: true) }
    }

    @objc private func disableAll() {
        guard !busy else { return }
        displayEnabled = false
        releaseDisplay()
        refreshMenu()
        if defaults.object(forKey: recoveryKey) != nil { restoreSleep(quitAfter: false) }
    }

    @objc private func toggleLockOnClose() {
        lockOnClose.toggle()
        refreshMenu()
    }

    @objc private func toggleDisplay() { displayEnabled.toggle(); tick(); refreshMenu() }
    @objc private func lockNow() {
        guard lockFunction?() == 0 else { alert("没有成功锁定", "请用 macOS 自带的“锁定屏幕”操作。"); return }
    }

    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "系统操作", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""]) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func sleepValue() throws -> Int {
        let output = try run("/usr/bin/pmset", ["-g"])
        for line in output.components(separatedBy: .newlines) {
            let words = line.split(whereSeparator: { $0.isWhitespace })
            if words.count == 2 && words[0] == "SleepDisabled", let value = Int(words[1]), value == 0 || value == 1 { return value }
        }
        throw NSError(domain: "无法读取当前休眠设置", code: 1)
    }

    private func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func administratorCommand(_ command: String) throws -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return try run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }

    private func setSleep(_ value: Int, completion: @escaping (Bool) -> Void) {
        busy = true
        refreshMenu()
        let parent = getpid()
        let helperURL = Bundle.main.resourceURL?.appendingPathComponent("恢复守护.sh")
        // 在普通用户权限下读取自带脚本，授权进程不再读取 Documents 中的应用文件。
        let helperText = helperURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        DispatchQueue.global(qos: .userInitiated).async {
            var succeeded = false
            var launchedPID: pid_t?
            var issue = "系统授权未完成，或启动请求没有成功。"
            var logPath: String?
            do {
                if value == 1 {
                    issue = "无法读取应用自带的恢复程序。"
                    guard let helperText else { throw NSError(domain: "恢复进程缺失", code: 1) }
                    issue = "无法读取主程序的身份信息。"
                    let birth = try self.run("/usr/bin/env", ["LC_ALL=C", "TZ=UTC", "/bin/ps", "-p", String(parent), "-o", "lstart="]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !birth.isEmpty else { throw NSError(domain: "无法识别主程序", code: 1) }
                    let launch = "/bin/sh -c " + self.shellQuote(helperText) + " lidawake " + self.shellQuote(String(parent)) + " " + self.shellQuote(birth)
                    // 日志由授权进程创建于临时目录，只保存恢复过程的错误，不含密码。
                    let command = "trap '' HUP; log=$(/usr/bin/mktemp /private/tmp/lidawake-watchdog.XXXXXXXX) || exit 1; /bin/chmod 644 \"$log\"; " + launch + " </dev/null >\"$log\" 2>&1 & printf '%s\\n%s\\n' \"$!\" \"$log\""
                    issue = "系统授权未完成，或系统没有接受恢复进程的启动请求。"
                    let output = try self.administratorCommand(command)
                    let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    launchedPID = lines.first.flatMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
                    if lines.count > 1 { logPath = lines[1] }
                    issue = "恢复进程已经收到启动请求，但没有完成初始化。"

                    for _ in 0..<30 {
                        if let pid = launchedPID, kill(pid, 0) == -1 && errno == ESRCH { break }
                        if try self.sleepValue() == 1 { succeeded = launchedPID != nil; break }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                } else {
                    if try self.sleepValue() != value {
                        _ = try self.administratorCommand("/usr/bin/pmset -a disablesleep 0")
                    }
                    succeeded = try self.sleepValue() == value
                }
            } catch {
                succeeded = false
                if error.localizedDescription.contains("-128") { issue = "管理员授权已取消。" }
            }
            if !succeeded, let logPath, logPath.hasPrefix("/private/tmp/lidawake-watchdog."),
               let log = try? String(contentsOfFile: logPath, encoding: .utf8),
               let detail = log.components(separatedBy: .newlines).first(where: { $0.hasPrefix("恢复检查：") }) {
                issue = detail
            }
            DispatchQueue.main.async {
                self.enableIssue = issue
                self.busy = false
                if value == 1 { self.watchdogPID = launchedPID }
                if value == 0 && succeeded { self.watchdogPID = nil }
                completion(succeeded)
                self.refreshMenu()
            }
        }
    }

    @objc private func toggleLid() {
        guard !busy else { return }
        if lidEnabled { restoreSleep(quitAfter: false); return }
        enableLid(alsoDisplay: false)
    }

    private func enableLid(alsoDisplay: Bool) {
        guard lidClosed() == false, !lockOnClose || lockFunction != nil else {
            alert("暂时不能开启", "请先打开 Mac。如果开启了合盖锁屏，程序还需要能调用系统锁屏功能。")
            return
        }
        let original: Int
        do { original = try sleepValue() } catch {
            alert("无法读取休眠设置", "为避免改错设置，合盖功能没有开启。")
            return
        }
        guard original == 0 else {
            alert("系统已经禁止休眠", "请先恢复现有的禁止休眠设置，再使用本工具。这样关闭本工具时才能准确恢复。")
            return
        }
        let confirmation = NSAlert()
        confirmation.messageText = "开启合盖继续运行？"
        confirmation.informativeText = "这会修改整台 Mac 的系统休眠设置，在接电源和使用电池时都禁止 Mac 休眠，也会影响手动休眠。合盖时内置屏幕立即黑掉；是否主动锁屏由“合盖时锁定屏幕”开关决定。\n\n关闭功能或正常退出时会恢复原设置，并可能再次要求管理员授权。本次授权还会启动独立恢复进程：程序崩溃或被强制退出时，它会恢复正常休眠。突然断电等情况下，请重新打开应用检查恢复入口。持续运行会耗电、发热，请保持通风，不要放进包里。"
        confirmation.addButton(withTitle: "开启并授权")
        confirmation.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        defaults.set(original, forKey: recoveryKey)
        _ = defaults.synchronize()
        setSleep(1) { success in
            if success {
                self.lidEnabled = true
                if alsoDisplay { self.displayEnabled = true }
                self.lastClosed = false
                self.tick()
            }
            else {
                if (try? self.sleepValue()) == original { self.defaults.removeObject(forKey: self.recoveryKey) }
                self.alert("合盖继续运行未开启", self.enableIssue + "\n\n如果菜单出现恢复入口，请先点击恢复。把这条提示告诉我，就能继续定位。")
            }
        }
    }

    @objc private func recover() { restoreSleep(quitAfter: false) }
    private func restoreSleep(quitAfter: Bool, lockFailure: Bool = false) {
        guard !busy else { return }
        guard let value = defaults.object(forKey: recoveryKey) as? Int, value == 0 || value == 1 else {
            if quitAfter { NSApp.terminate(nil) }
            return
        }
        setSleep(value) { success in
            if success {
                self.lidEnabled = false
                self.defaults.removeObject(forKey: self.recoveryKey)
                _ = self.defaults.synchronize()
                if lockFailure { self.alert("合盖锁屏失败", "已恢复原休眠设置，合盖继续运行已关闭。请重新打开 Mac 并手动锁屏。") }
                if quitAfter { NSApp.terminate(nil) }
            } else {
                self.alert("休眠设置尚未恢复", "请再次点击关闭或恢复，并完成管理员授权。程序会保留恢复入口。")
            }
        }
    }

    @objc private func quit() {
        if defaults.object(forKey: recoveryKey) != nil { restoreSleep(quitAfter: true) }
        else { NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if defaults.object(forKey: recoveryKey) != nil {
            restoreSleep(quitAfter: true)
            return .terminateCancel
        }
        releaseDisplay()
        return .terminateNow
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSAlert()
        dialog.messageText = title
        dialog.informativeText = text
        dialog.addButton(withTitle: "知道了")
        dialog.runModal()
    }

    @objc private func showHelp() {
        alert("点开菜单就能控制", "“开启全部功能”：同时开启锁屏亮屏与合盖运行，合盖功能需要管理员授权。\n\n两个开关也能分别使用。“合盖时锁定屏幕”默认关闭，单独记住你的选择；关闭后应用不会在合盖时主动锁屏，macOS 自身的锁定设置仍会生效。勾选表示已开启；菜单栏图标旁的小点表示至少一项已开启。\n\n“全部关闭，恢复正常休眠”：关闭两项功能，恢复本工具开启前的系统休眠设置，应用留在菜单栏。\n\n“恢复休眠并退出”：恢复设置后退出应用。恢复时可能需要管理员授权。\n\n合盖继续运行会耗电、发热，请保持通风。程序崩溃或被强制退出后，独立恢复进程会尝试自动恢复。突然断电或恢复进程也被强制结束时，请重新打开应用使用恢复入口。")
    }

    @objc private func showAbout() {
        alert("合盖不休眠 · 1.0.1", "用于控制锁屏亮屏与合盖运行的菜单栏工具。\n\n锁屏保持亮屏；合盖立即黑屏，Mac 继续运行。可单独选择合盖时是否主动锁屏。\n\n当前版本按每次打开后主动开启功能的方式使用，不会自动开机启动。已加入本次运行的独立恢复进程；异常退出后自动恢复，重新打开时也会检查原设置。")
    }

}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
