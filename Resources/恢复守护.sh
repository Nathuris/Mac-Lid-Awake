#!/bin/sh
# 本次运行中监测电源与固定规则，只接受四种模式或停止指令，不执行控制文件中的代码。
set -u
[ "$(/usr/bin/id -u)" = 0 ] || { echo "恢复检查：未获得管理员权限" >&2; exit 1; }
[ "$#" = 3 ] || exit 1
parent="$1"
birth="$2"
control="$3"
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
[ "$(sleep_value)" = 0 ] || { echo "恢复检查：系统休眠状态已变化" >&2; exit 1; }
restore() {
    while ! /usr/bin/pmset -a disablesleep 0; do /bin/sleep 1; done
    echo "原设置已恢复"
}
trap restore EXIT
trap 'exit 0' TERM INT HUP
last_state=""
ready=0
while parent_alive; do
    mode=$(/bin/cat "$control" 2>/dev/null) || { echo "恢复检查：无法读取电源规则" >&2; exit 1; }
    case "$mode" in
        stop) exit 0 ;;
        00|01|10|11) ;;
        *) echo "恢复检查：电源规则无效" >&2; exit 1 ;;
    esac
    power=$(/usr/bin/env LC_ALL=C /usr/bin/pmset -g batt 2>/dev/null) || power=""
    # 电源来源不明时按允许休眠处理，避免意外持续消耗电池。
    target=0
    case "$power" in
        *"Now drawing from 'AC Power'"*) target=$(printf '%s' "$mode" | /usr/bin/cut -c 1) ;;
        *"Now drawing from 'Battery Power'"*) target=$(printf '%s' "$mode" | /usr/bin/cut -c 2) ;;
    esac
    if [ "$(sleep_value)" != "$target" ]; then
        /usr/bin/pmset -a disablesleep "$target" || { echo "恢复检查：系统没有接受电源规则" >&2; exit 1; }
    fi
    if [ "$last_state" != "$target" ]; then
        echo "状态：$target"
        last_state="$target"
    fi
    if [ "$ready" = 0 ]; then echo "电源规则已就绪"; ready=1; fi
    /bin/sleep 0.25
done
exit 0
