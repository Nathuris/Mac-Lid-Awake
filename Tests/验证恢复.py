from pathlib import Path
import subprocess, tempfile, time, shlex, os
root=Path(tempfile.mkdtemp(prefix="lidawake-launch-check-",dir="/private/tmp"))
state=root/"state";state.write_text("0")
fake=root/"pmset"
fake.write_text('#!/bin/sh\nif [ "$1" = "-g" ]; then printf "SleepDisabled %s\\n" "$(cat '+str(state)+')"; else printf "%s" "$3" > '+str(state)+'; fi\n')
fake.chmod(0o700)
helper=(Path(__file__).resolve().parents[1] / "Resources" / "恢复守护.sh").read_text()
helper="\n".join(":" if line.startswith('[ "$(/usr/bin/id -u)"') else line for line in helper.splitlines()).replace("/usr/bin/pmset",str(fake))
parent=subprocess.Popen(["/bin/sleep","20"])
try:
 birth=subprocess.check_output(["/usr/bin/env","LC_ALL=C","TZ=UTC","/bin/ps","-p",str(parent.pid),"-o","lstart="],text=True).strip()
 launch="/bin/sh -c "+shlex.quote(helper)+" lidawake "+shlex.quote(str(parent.pid))+" "+shlex.quote(birth)
 command="""trap '' HUP; log=$(/usr/bin/mktemp /private/tmp/lidawake-watchdog.XXXXXXXX) || exit 1; /bin/chmod 644 "$log"; """+launch+""" </dev/null >"$log" 2>&1 & printf '%s\\n%s\\n' "$!" "$log"""+'"'
 escaped=command.replace("\\","\\\\").replace('"','\\"')
 # 验证真实 AppleScript 启动链路，但省略管理员授权并使用模拟设置。
 output=subprocess.check_output(["/usr/bin/osascript","-e",'do shell script "'+escaped+'"'],text=True)
 lines=output.splitlines();assert len(lines)==2 and int(lines[0])>0
 for _ in range(60):
  if state.read_text()=="1":break
  time.sleep(.05)
 else:raise AssertionError(Path(lines[1]).read_text())
 print("经 AppleScript 启动后台恢复进程：通过")
 parent.terminate();parent.wait()
 for _ in range(60):
  if state.read_text()=="0":break
  time.sleep(.05)
 else:raise AssertionError("主程序结束后没有恢复")
 print("主程序结束后恢复：通过；未修改真实休眠设置")
finally:
 if parent.poll() is None:parent.terminate();parent.wait()
