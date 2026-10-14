#!/bin/sh
# 只在用户授权的本次运行中执行，不注册开机服务。
set -u
[ "$(/usr/bin/id -u)" = 0 ] || { echo "恢复检查：未获得管理员权限" >&2; exit 1; }
[ "$#" = 2 ] || exit 1
parent="$1"
birth="$2"
case "$parent" in ''|*[!0-9]*) exit 1 ;; esac
[ "$parent" -gt 1 ] || exit 1
parent_alive() {
    kill -0 "$parent" 2>/dev/null || return 1
    current=$(/usr/bin/env LC_ALL=C TZ=UTC /bin/ps -p "$parent" -o lstart= 2>/dev/null | /usr/bin/sed 's/^ *//;s/ *$//')
    [ "$current" = "$birth" ]
}
sleep_value() {
    /usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" { print $2; exit }'
}
parent_alive || { echo "恢复检查：主程序身份核对失败" >&2; exit 1; }
# 只接管原本允许休眠的状态，绝不撤销别人已有的设置。
[ "$(sleep_value)" = 0 ] || { echo "恢复检查：系统休眠状态已变化" >&2; exit 1; }
restore() {
    # 恢复失败时继续尝试，避免带着禁止休眠设置退出。
    while ! /usr/bin/pmset -a disablesleep 0; do /bin/sleep 1; done
}
trap restore EXIT
trap 'exit 0' TERM INT HUP
/usr/bin/pmset -a disablesleep 1 || { echo "恢复检查：系统没有接受禁止休眠设置" >&2; exit 1; }
while parent_alive; do
    # 主程序正常关闭功能后，恢复进程自行结束。
    [ "$(sleep_value)" = 1 ] || exit 0
    /bin/sleep 0.5
done
exit 0
