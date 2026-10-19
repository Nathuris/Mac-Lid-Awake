from pathlib import Path
import subprocess
import tempfile

# 提取实际事件处理代码，用模拟锁屏及休眠操作验证顺序，不触碰真实屏幕。
source = (Path(__file__).resolve().parents[1] / "Sources/main.swift").read_text()
power = source[source.index("    private func handlePowerMessage("):source.index("    private func tick()")]
power = power.replace("private func", "func")
close = source[source.index("        let justClosed = closed"):source.index("        guard displayEnabled && locked")]
constants = source[source.index("private enum PowerMessage"):source.index("// 接电源规则默认开启")]
prefix = '''import Foundation
var events: [String] = []
func IOAllowPowerChange(_ connection: Int, _ argument: Int) { events.append("允许休眠") }
final class Harness {
    var lockOnClose = false
    var lidEnabled = false
    var lastClosed = false
    var lidLockRequested = false
    var lidLockFailed = false
    var powerConnection = 1
    var closed = false
    var lockResult: Int32 = 0
    var lockFunction: (() -> Int32)? { { events.append("请求锁屏"); return self.lockResult } }
    func lidClosed() -> Bool? { closed }
    func releaseDisplay() { events.append("释放亮屏请求") }
    func restoreSleep(quitAfter: Bool, lockFailure: Bool) { events.append("恢复休眠") }
    func turnDisplayOffAfterLock() { events.append("请求熄屏") }
    func tick() { events.append("检查状态") }
'''
tests = '''
for keepAwake in [false, true] {
    for lock in [false, true] {
        let app = Harness()
        app.lidEnabled = keepAwake
        app.lockOnClose = lock
        app.closed = true
        events = []
        app.pollClose()
        assert(events.contains("请求锁屏") == lock)
        assert(events.contains("请求熄屏") == keepAwake)
    }
}
let app = Harness()
app.lockOnClose = true
app.closed = true
events = []
app.handlePowerMessage(PowerMessage.willSleep, argument: nil)
assert(events == ["释放亮屏请求", "请求锁屏", "允许休眠"])
events = []
app.handlePowerMessage(PowerMessage.willSleep, argument: nil)
assert(!events.contains("请求锁屏"))
assert(events.last == "允许休眠")
app.closed = false
app.lidLockRequested = false
events = []
app.handlePowerMessage(PowerMessage.willSleep, argument: nil)
assert(!events.contains("请求锁屏"))
app.closed = true
app.lockResult = -1
events = []
app.handlePowerMessage(PowerMessage.willSleep, argument: nil)
assert(app.lidLockFailed && events.last == "允许休眠")
events = []
app.handlePowerMessage(PowerMessage.canSleep, argument: nil)
assert(events == ["允许休眠"])
print("开关四种组合、休眠前锁屏顺序、重复通知和锁屏失败处理：通过")
'''
folder = Path(tempfile.mkdtemp(prefix="lidawake-lock-check-", dir="/private/tmp"))
testfile = folder / "main.swift"
testfile.write_text(constants + prefix + power + "\nfunc pollClose() {\n" + close + "\n}\n}\n" + tests)
subprocess.run(["xcrun", "swift", "-module-cache-path", str(folder / "缓存"), str(testfile)], check=True)
