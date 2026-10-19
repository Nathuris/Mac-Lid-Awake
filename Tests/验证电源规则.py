from pathlib import Path
import os
import shlex
import subprocess
import sys
import tempfile
import time

# 整条启动链路使用临时文件模拟电源与休眠设置，不执行真实 pmset。
administrator = "--administrator" in sys.argv
script = (Path(__file__).resolve().parents[1] / "Resources/恢复守护.sh").read_text()
if not administrator:
    script = "\n".join(":" if line.startswith('[ "$(/usr/bin/id -u)"') else line for line in script.splitlines())


class Session:
    def __init__(self, mode="10", power="AC Power", original="0"):
        self.directory = Path(tempfile.mkdtemp(prefix="lidawake-power-check-", dir="/private/tmp"))
        self.state = self.directory / "state"
        self.power = self.directory / "power"
        self.mode = self.directory / "mode"
        self.state.write_text(original)
        self.power.write_text(power)
        self.mode.write_text(mode)
        fake = self.directory / "pmset"
        fake.write_text(
            '#!/bin/sh\ncase "$*" in\n'
            + "\"-g batt\") printf \"Now drawing from '%s'\\n\" \"$(cat "
            + shlex.quote(str(self.power)) + ')" ;;\n'
            + '"-g") printf "SleepDisabled %s\\n" "$(cat '
            + shlex.quote(str(self.state)) + ')" ;;\n'
            + '"-a disablesleep 0"|"-a disablesleep 1") printf "%s" "$3" > '
            + shlex.quote(str(self.state)) + ' ;;\n*) exit 1 ;;\nesac\n'
        )
        fake.chmod(0o700)
        self.parent = subprocess.Popen(["/bin/sleep", "180"])
        birth = subprocess.check_output(["/usr/bin/env", "LC_ALL=C", "TZ=UTC", "/bin/ps", "-p", str(self.parent.pid), "-o", "lstart="], text=True).strip()
        body = script.replace("/usr/bin/pmset", str(fake))
        launch = "/bin/sh -c " + shlex.quote(body) + " lidawake " + shlex.quote(str(self.parent.pid)) + " " + shlex.quote(birth) + " " + shlex.quote(str(self.mode))
        command = 'trap \'\' HUP; log=$(/usr/bin/mktemp /private/tmp/lidawake-watchdog.XXXXXXXX) || exit 1; /bin/chmod 644 "$log"; ' + launch + ' </dev/null >"$log" 2>&1 & printf \'%s\\n%s\\n\' "$!" "$log"'
        escaped = command.replace("\\", "\\\\").replace('"', '\\"')
        apple = 'do shell script "' + escaped + '"' + (" with administrator privileges" if administrator else "")
        try:
            output = subprocess.check_output(["/usr/bin/osascript", "-e", apple], text=True)
            lines = output.splitlines()
            assert len(lines) == 2 and int(lines[0]) > 0, output
            self.log = Path(lines[1])
        except BaseException:
            self.parent.terminate()
            self.parent.wait()
            raise

    def write(self, file, text):
        staging = file.with_name(file.name + "-staging")
        staging.write_text(text)
        os.replace(staging, file)

    def wait(self, predicate):
        for _ in range(100):
            if predicate():
                return
            time.sleep(0.05)
        raise AssertionError(self.log.read_text())

    def state_is(self, value):
        self.wait(lambda: self.state.read_text() == value)

    def ready(self):
        self.wait(lambda: "电源规则已就绪" in self.log.read_text())

    def restored(self):
        self.wait(lambda: "原设置已恢复" in self.log.read_text())
        assert self.state.read_text() == "0"

    def close(self):
        self.write(self.mode, "stop")
        if self.parent.poll() is None:
            self.parent.terminate()
            self.parent.wait()


def run():
    app = Session()
    try:
        app.ready(); app.state_is("1")
        app.write(app.power, "Battery Power"); app.state_is("0")
        app.write(app.power, "AC Power"); app.state_is("1")
        app.write(app.mode, "11")
        app.write(app.power, "Battery Power"); app.state_is("1")
        time.sleep(0.4)
        app.write(app.mode, "10"); app.state_is("0")
        app.write(app.mode, "00")
        app.write(app.power, "AC Power"); app.state_is("0")
        time.sleep(0.4)
        app.write(app.mode, "01"); app.write(app.power, "Battery Power"); app.state_is("1")
        app.write(app.power, "AC Power"); app.state_is("0")
        app.write(app.mode, "11"); app.state_is("1")
        app.write(app.power, "Unknown"); app.state_is("0")
        app.write(app.mode, "stop"); app.restored()
        print("插拔电源、四种开关组合、未知电源和停止后恢复：通过")
    finally:
        app.close()
    app = Session(power="Battery Power")
    try:
        app.ready(); app.state_is("0")
        app.write(app.power, "AC Power"); app.state_is("1")
        app.parent.terminate(); app.parent.wait(); app.restored()
        print("电池状态下初始化、主程序异常结束后恢复：通过")
    finally:
        app.close()
    app = Session(original="1")
    try:
        app.wait(lambda: "系统休眠状态已变化" in app.log.read_text())
        assert app.state.read_text() == "1"
        print("已有禁止休眠设置时拒绝接管：通过")
    finally:
        app.close()
    app = Session()
    try:
        app.ready(); app.state_is("1")
        app.write(app.mode, "无效规则"); app.restored()
        print("无效控制指令时恢复：通过")
    finally:
        app.close()
    print(("管理员权限" if administrator else "普通权限") + "启动链路检查通过，没有修改真实电源设置。")


if __name__ == "__main__":
    run()
