import AppKit
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Darwin

// IOMessage.h 的 C 宏无法直接导入 Swift，以下值对应系统公开的通知编号。
private enum PowerMessage {
    static let canSleep: UInt32 = 0xe0000270
    static let willSleep: UInt32 = 0xe0000280
    static let hasPoweredOn: UInt32 = 0xe0000300
}

// 接电源规则默认开启，首次使用仍需系统授权；其他功能由用户主动开启。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var summaryItem: NSMenuItem?
    private var timer: Timer?
    private var displayEnabled = false
    private var lidEnabled = false
    private var powerRulesActive = false
    private var batteryKeepAwake = false
    private var autoOnPower: Bool {
        get { defaults.object(forKey: "接电源时合盖继续运行") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "接电源时合盖继续运行") }
    }
    private var ruleFile: URL?
    private var watchdogLog: String?
    private var lastRuleStatus = ""
    private var ruleError = false
    private var lastStatusRead = Date.distantPast
    private var onACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return type as String == kIOPSACPowerValue
    }
    private var ruleValue: String { "\(autoOnPower ? 1 : 0)\(batteryKeepAwake ? 1 : 0)" }

    private var lockOnClose: Bool {
        get { defaults.bool(forKey: "合盖时锁定屏幕") }
        set { defaults.set(newValue, forKey: "合盖时锁定屏幕") }
    }
    private var busy = false
    private var enableIssue = ""
    private var watchdogPID: pid_t?
    private var lastWatchdogCheck = Date.distantPast
    private var lastClosed = false
    private var lidLockRequested = false
    private var lidLockFailed = false
    private var powerConnection: io_connect_t = 0
    private var powerNotifier: io_object_t = 0
    private var powerPort: IONotificationPortRef?
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
            exit(0)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "合盖不休眠")
        lastClosed = lidClosed() ?? false
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(didLock), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        center.addObserver(self, selector: #selector(didUnlock), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        registerPowerNotifications()
        refreshMenu()
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        if defaults.object(forKey: recoveryKey) != nil {
            if let original = defaults.object(forKey: recoveryKey) as? Int, (try? sleepValue()) == original {
                defaults.removeObject(forKey: recoveryKey)
                refreshMenu()
            } else {
                alert("上次的休眠设置需要恢复", "请点击菜单中的“恢复上次的休眠设置”。完成后再开启功能。")
            }
        }
        if autoOnPower && defaults.object(forKey: recoveryKey) == nil {
            DispatchQueue.main.async { self.enableLid(alsoDisplay: false) }
        }
    }

    @objc private func didLock() {
        locked = true
        tick()
        if lidEnabled && lidClosed() == true { turnDisplayOffAfterLock() }
    }
    @objc private func didUnlock() { locked = false; releaseDisplay() }

    private func registerPowerNotifications() {
        powerConnection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &powerPort, { context, _, message, argument in
            guard let context else { return }
            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            app.handlePowerMessage(message, argument: argument)
        }, &powerNotifier)
        if powerConnection != 0, let port = powerPort,
           let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func handlePowerMessage(_ message: UInt32, argument: UnsafeMutableRawPointer?) {
        switch message {
        case PowerMessage.canSleep:
            IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
        case PowerMessage.willSleep:
            // 先请求锁屏，再确认休眠；不取消正常休眠，也不等待授权弹窗。
            defer { IOAllowPowerChange(powerConnection, Int(bitPattern: argument)) }
            releaseDisplay()
            if lidClosed() == true {
                lastClosed = true
                requestLidLock()
            }
        case PowerMessage.hasPoweredOn:
            tick()
        default:
            break
        }
    }

    @discardableResult
    private func requestLidLock() -> Bool {
        guard lockOnClose, !lidLockRequested else { return true }
        let succeeded = lockFunction?() == 0
        lidLockFailed = !succeeded
        if succeeded { lidLockRequested = true }
        return succeeded
    }

    private func tick() {
        defer { updateSummary() }
        refreshPowerStatus()
        if powerRulesActive && !busy && Date().timeIntervalSince(lastWatchdogCheck) >= 2 {
            lastWatchdogCheck = Date()
            if let pid = watchdogPID, kill(pid, 0) == -1 && errno == ESRCH {
                watchdogPID = nil
                ruleError = true
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
        if !closed { lidLockRequested = false }
        if justClosed {
            releaseDisplay()
            let lockSucceeded = requestLidLock()
            if !lockSucceeded && lidEnabled {
                // 锁定失败时停止保持运行，避免以未锁定状态继续工作。
                restoreSleep(quitAfter: false, lockFailure: true)
            } else if lidEnabled {
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

    private func refreshPowerStatus() {
        guard powerRulesActive, !busy, Date().timeIntervalSince(lastStatusRead) >= 0.25,
              let log = watchdogLog, let text = try? String(contentsOfFile: log, encoding: .utf8) else { return }
        lastStatusRead = Date()
        if let line = text.components(separatedBy: .newlines).last(where: { $0.hasPrefix("状态：") }), line != lastRuleStatus {
            lastRuleStatus = line
            let wasEnabled = lidEnabled
            lidEnabled = line == "状态：1"
            if lidEnabled && !wasEnabled && lidClosed() == true { turnDisplayOffAfterLock() }
            refreshMenu()
        }
    }

    private func writeRule(_ value: String) throws {
        guard ["00", "01", "10", "11", "stop"].contains(value), let file = ruleFile else {
            throw NSError(domain: "电源规则未就绪", code: 1)
        }
        try Data(value.utf8).write(to: file, options: .atomic)
    }

    private func applyPowerRule() {
        guard powerRulesActive else { enableLid(alsoDisplay: false); return }
        do { try writeRule(ruleValue) }
        catch { ruleError = true; alert("电源规则没有更新", "请恢复休眠并退出，再重新打开软件。"); }
        refreshMenu()
    }

    private var summary: String {
        if busy { return "正在等待系统授权…" }
        if lidLockFailed && lockOnClose { return "合盖锁屏请求失败，请手动锁屏" }
        if powerConnection == 0 && lockOnClose { return "未能监听系统休眠，合盖锁屏可能不及时" }
        if ruleError { return "电源规则未生效，请重新授权" }
        if !powerRulesActive && defaults.object(forKey: recoveryKey) != nil { return "需要恢复上次的休眠设置" }
        if displaySleepFailed && lidEnabled { return "立即熄屏请求失败，请反馈" }
        if !powerRulesActive && (autoOnPower || batteryKeepAwake) { return "电源规则待授权，请点击启用" }
        if powerRulesActive {
            return (onACPower ? "接电源" : "使用电池") + (lidEnabled ? " · 合盖继续运行" : " · 合盖可正常休眠")
        }
        var active: [String] = []
        if displayEnabled { active.append("锁屏亮屏") }
        if lockOnClose { active.append("合盖锁屏") }
        return active.isEmpty ? "所有功能均已关闭" : "已开启：" + active.joined(separator: "、")
    }

    private func updateSummary() {
        summaryItem?.title = summary
        let active = displayEnabled || lidEnabled || lockOnClose
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
        let needsRecovery = !powerRulesActive && defaults.object(forKey: recoveryKey) != nil
        menu.addItem(item("开启亮屏与电源规则", #selector(enableAll), enabled: !busy && !needsRecovery && !(displayEnabled && powerRulesActive)))
        menu.addItem(item("全部关闭，恢复正常休眠", #selector(disableAll), enabled: !busy && (displayEnabled || powerRulesActive || autoOnPower || batteryKeepAwake || lockOnClose || needsRecovery)))
        menu.addItem(.separator())
        menu.addItem(item("锁屏保持亮屏", #selector(toggleDisplay), checked: displayEnabled, enabled: !busy))
        menu.addItem(item("开盖锁屏后，锁屏界面持续亮着", nil, enabled: false))
        menu.addItem(item("接电源时合盖继续运行", #selector(toggleAutoPower), checked: autoOnPower, enabled: !busy && !needsRecovery))
        menu.addItem(item("默认开启，拔掉电源后使用电池规则", nil, enabled: false))
        menu.addItem(item("使用电池时合盖继续运行", #selector(toggleLid), checked: batteryKeepAwake, enabled: !busy && !needsRecovery))
        menu.addItem(item("默认关闭，仅控制使用电池时的行为", nil, enabled: false))
        if !powerRulesActive && !needsRecovery {
            menu.addItem(item("启用电源规则…", #selector(startPowerRules), enabled: !busy))
        }
        menu.addItem(item("合盖时锁定屏幕", #selector(toggleLockOnClose), checked: lockOnClose, enabled: !busy && lockFunction != nil))
        menu.addItem(item("独立生效，Mac 正常休眠时也锁屏", nil, enabled: false))
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
        autoOnPower = true
        if powerRulesActive { displayEnabled = true; applyPowerRule(); tick(); refreshMenu() }
        else { enableLid(alsoDisplay: true) }
    }

    @objc private func disableAll() {
        guard !busy else { return }
        displayEnabled = false
        autoOnPower = false
        batteryKeepAwake = false
        lockOnClose = false
        lidLockFailed = false
        releaseDisplay()
        refreshMenu()
        if defaults.object(forKey: recoveryKey) != nil { restoreSleep(quitAfter: false) }
    }

    @objc private func toggleLockOnClose() {
        lockOnClose.toggle()
        lidLockFailed = false
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
        let helperText = helperURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let currentRule = ruleValue
        let existingFile = ruleFile
        let existingLog = watchdogLog
        let existingPID = watchdogPID
        DispatchQueue.global(qos: .userInitiated).async {
            var succeeded = false
            var launchedPID: pid_t?
            var file = existingFile
            var logPath = existingLog
            var issue = "系统授权未完成，或启动请求没有成功。"
            do {
                if value == 1 {
                    guard let helperText else { throw NSError(domain: "恢复进程缺失", code: 1) }
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lidawake-rules-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    file = directory.appendingPathComponent("mode")
                    try Data(currentRule.utf8).write(to: file!, options: .atomic)
                    let birth = try self.run("/usr/bin/env", ["LC_ALL=C", "TZ=UTC", "/bin/ps", "-p", String(parent), "-o", "lstart="]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !birth.isEmpty else { throw NSError(domain: "主程序身份缺失", code: 1) }
                    let launch = "/bin/sh -c " + self.shellQuote(helperText) + " lidawake " + self.shellQuote(String(parent)) + " " + self.shellQuote(birth) + " " + self.shellQuote(file!.path)
                    let command = "trap '' HUP; log=$(/usr/bin/mktemp /private/tmp/lidawake-watchdog.XXXXXXXX) || exit 1; /bin/chmod 644 \"$log\"; " + launch + " </dev/null >\"$log\" 2>&1 & printf '%s\\n%s\\n' \"$!\" \"$log\""
                    let output = try self.administratorCommand(command)
                    let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    launchedPID = lines.first.flatMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
                    if lines.count > 1 { logPath = lines[1] }
                    issue = "恢复进程没有完成初始化。"
                    for _ in 0..<50 {
                        if let logPath, let log = try? String(contentsOfFile: logPath, encoding: .utf8), log.contains("电源规则已就绪") {
                            succeeded = launchedPID != nil
                            break
                        }
                        if let pid = launchedPID, kill(pid, 0) == -1 && errno == ESRCH { break }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    if !succeeded, let file { try? Data("stop".utf8).write(to: file, options: .atomic) }
                } else {
                    if let file { try Data("stop".utf8).write(to: file, options: .atomic) }
                    // 先等规则进程退出并恢复，避免恢复后又被自动规则重新开启。
                    if let existingPID, let logPath {
                        for _ in 0..<50 {
                            let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
                            if log.contains("原设置已恢复") || (kill(existingPID, 0) == -1 && errno == ESRCH) { break }
                            Thread.sleep(forTimeInterval: 0.1)
                        }
                        let finished = ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").contains("原设置已恢复") || (kill(existingPID, 0) == -1 && errno == ESRCH)
                        guard finished else { throw NSError(domain: "电源规则尚未停止", code: 1) }
                    }
                    if try self.sleepValue() != value { _ = try self.administratorCommand("/usr/bin/pmset -a disablesleep 0") }
                    succeeded = try self.sleepValue() == value
                }
            } catch {
                if error.localizedDescription.contains("-128") { issue = "管理员授权已取消。" }
            }
            if !succeeded, let logPath, logPath.hasPrefix("/private/tmp/lidawake-watchdog."),
               let log = try? String(contentsOfFile: logPath, encoding: .utf8),
               let detail = log.components(separatedBy: .newlines).first(where: { $0.hasPrefix("恢复检查：") }) { issue = detail }
            DispatchQueue.main.async {
                self.enableIssue = issue
                self.busy = false
                if value == 1 {
                    self.watchdogPID = launchedPID
                    self.ruleFile = file
                    self.watchdogLog = logPath
                }
                if value == 0 && succeeded {
                    self.watchdogPID = nil
                    self.powerRulesActive = false
                    self.ruleFile = nil
                    self.watchdogLog = nil
                    self.lastRuleStatus = ""
                }
                completion(succeeded)
                self.refreshMenu()
            }
        }
    }

    @objc private func toggleAutoPower() {
        guard !busy else { return }
        autoOnPower.toggle()
        if powerRulesActive || autoOnPower || batteryKeepAwake { applyPowerRule() }
        else { refreshMenu() }
    }

    @objc private func toggleLid() {
        guard !busy else { return }
        batteryKeepAwake.toggle()
        if powerRulesActive || autoOnPower || batteryKeepAwake { applyPowerRule() }
        else { refreshMenu() }
    }

    @objc private func startPowerRules() { enableLid(alsoDisplay: false) }

    private func enableLid(alsoDisplay: Bool) {
        guard !busy, !powerRulesActive else { return }
        guard lidClosed() == false, !lockOnClose || lockFunction != nil else {
            alert("暂时不能开启", "请先打开 Mac。如果开启了合盖锁屏，程序还需要能调用系统锁屏功能。")
            return
        }
        guard defaults.object(forKey: recoveryKey) == nil else { refreshMenu(); return }
        let original: Int
        do { original = try sleepValue() } catch { alert("无法读取休眠设置", "电源规则没有开启。"); return }
        guard original == 0 else {
            alert("系统已经禁止休眠", "请先恢复现有的禁止休眠设置，再启用本工具的自动规则。")
            return
        }
        let confirmation = NSAlert()
        confirmation.messageText = "启用接电源与电池规则？"
        confirmation.informativeText = "接电源时默认合盖继续运行；使用电池时由独立开关决定，默认允许正常休眠。\n\n本次授权会启动独立恢复进程，插拔电源后自动切换，不再反复询问密码。保持运行时也会阻止手动休眠。合盖是否锁屏仍由独立开关决定。\n\n全部关闭或退出时恢复原设置。程序异常退出时，恢复进程会尝试恢复。持续运行会耗电、发热，请保持通风。"
        confirmation.addButton(withTitle: "启用并授权")
        confirmation.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard confirmation.runModal() == .alertFirstButtonReturn else { refreshMenu(); return }
        defaults.set(original, forKey: recoveryKey)
        _ = defaults.synchronize()
        setSleep(1) { success in
            if success {
                self.powerRulesActive = true
                self.ruleError = false
                if alsoDisplay { self.displayEnabled = true }
                self.lastClosed = false
                self.lastStatusRead = .distantPast
                self.tick()
            } else {
                self.ruleError = true
                if self.watchdogPID == nil && (try? self.sleepValue()) == original { self.defaults.removeObject(forKey: self.recoveryKey) }
                self.alert("电源规则未开启", self.enableIssue + "\n\n如果菜单出现恢复入口，请先点击恢复。")
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
                self.ruleError = false
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

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if powerNotifier != 0 { IODeregisterForSystemPower(&powerNotifier) }
        if let port = powerPort { IONotificationPortDestroy(port) }
        if powerConnection != 0 { IOServiceClose(powerConnection) }
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
        alert("按电源来源控制合盖行为", "“接电源时合盖继续运行”默认开启，并记住选择。首次打开请完成一次系统授权，之后运行期间插拔电源会自动切换。\n\n“使用电池时合盖继续运行”默认关闭，由你手动决定。关闭这个开关不会影响接电源时继续运行。\n\n锁屏亮屏与合盖锁屏仍可独立控制。“全部关闭”会关闭所有规则，并记住接电源规则关闭的选择。\n\n退出软件会恢复原来的系统设置；下次打开会按保存的接电源规则重新请求本次运行的授权。软件不会自动开机启动，也不会唤醒已经休眠的 Mac。\n\n持续运行请保持通风。突然断电等情况下，下次打开时可能需要手动恢复设置。")
    }

    @objc private func showAbout() {
        alert("合盖不休眠 · 1.1.0", "用于控制锁屏亮屏与合盖运行的菜单栏工具。\n\n锁屏保持亮屏；合盖立即黑屏，Mac 继续运行。可单独选择合盖时是否主动锁屏。\n\n接电源规则默认开启，首次使用需要授权；使用电池时由独立开关决定。不会自动开机启动。已加入本次运行的独立恢复进程；异常退出后自动恢复，重新打开时也会检查原设置。")
    }

}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
