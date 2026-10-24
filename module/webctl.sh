#!/system/bin/sh
# WebUI 控制脚本（JSON 安全转义版）
MODDIR=/data/adb/modules/smart5g
CONF=/data/adb/smart5g.conf
LOG=/data/adb/smart5g.log

getconf() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -1; }

# 把多行日志转成一个合法的 JSON 字符串内容：
# 反斜杠 -> \\ ，双引号 -> \" ，换行 -> 字面量 \n
json_escape() {
    sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g' \
      | awk 'BEGIN{ORS=""} {if(NR>1) printf "\\n"; printf "%s", $0}'
}

# NR 是否被允许（掩码判据）。这是唯一可信的"当前是不是 5G"来源，
# 不能用 gsm.network.type：关掉 NR 后该属性会残留 NR_SA，实测会误判。
nr_allowed() {
    cmd phone get-allowed-network-types-for-users 2>/dev/null \
        | tr '|' '\n' | grep -qx "NR"
}

case "$1" in
  json)
    net=$(getprop gsm.network.type 2>/dev/null)
    [ -z "$net" ] && net="unknown"
    if cmd phone get-allowed-network-types-for-users >/dev/null 2>&1; then
      if nr_allowed; then nr=1; else nr=0; fi
    else
      # 兜底：cmd 不可用时按属性里是否含 NR 判断
      case "$net" in *NR*) nr=1 ;; *) nr=0 ;; esac
    fi
    temp=$(awk '{printf "%d", $1/10}' /sys/class/power_supply/battery/temp 2>/dev/null)
    cap=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    chg=0
    case "$(cat /sys/class/power_supply/battery/status 2>/dev/null)" in
      *Charging*|*Full*) chg=1 ;;
    esac
    logtxt=$(tail -12 "$LOG" 2>/dev/null | json_escape)
    printf '{\n'
    printf '  "network": "%s",\n' "$net"
    printf '  "nr_allowed": "%s",\n' "$nr"
    printf '  "charging": "%s",\n' "$chg"
    printf '  "temp": "%s",\n' "$temp"
    printf '  "cap": "%s",\n' "$cap"
    printf '  "netmode": "%s",\n' "$(getconf netmode)"
    printf '  "interval": "%s",\n' "$(getconf interval)"
    printf '  "temp_high": "%s",\n' "$(getconf temp_high)"
    printf '  "temp_low": "%s",\n' "$(getconf temp_low)"
    printf '  "temp_critical": "%s",\n' "$(getconf temp_critical)"
    printf '  "sig_thres": "%s",\n' "$(getconf sig_thres)"
    printf '  "sig_good": "%s",\n' "$(getconf sig_good)"
    printf '  "lowbat": "%s",\n' "$(getconf lowbat)"
    printf '  "cooldown": "%s",\n' "$(getconf cooldown)"
    printf '  "probe_interval": "%s",\n' "$(getconf probe_interval)"
    printf '  "probe_window": "%s",\n' "$(getconf probe_window)"
    printf '  "n78_aggr": "%s",\n' "$(getconf n78_aggr)"
    printf '  "lowbat_enable": "%s",\n' "$(getconf lowbat_enable)"
    printf '  "skip_charging": "%s",\n' "$(getconf skip_charging)"
    printf '  "log": "%s"\n' "$logtxt"
    printf '}\n'
    ;;
  save)
    shift
    for kv in "$@"; do
      k=${kv%%=*}
      v=${kv#*=}
      case "$k" in
        netmode)
          # 枚举值（auto / 4g / 5g），不能走纯数字校验
          case "$v" in
            auto|4g|5g) ;;
            *) continue ;;
          esac
          ;;
        interval|temp_high|temp_low|temp_critical|sig_thres|sig_good|lowbat|cooldown|probe_interval|probe_window|n78_aggr|lowbat_enable|skip_charging)
          case "$v" in
            *[!0-9-]*) continue ;;
          esac
          [ -z "$v" ] && continue
          ;;
        *)
          continue
          ;;
      esac
      if grep -q "^$k=" "$CONF" 2>/dev/null; then
        sed -i "s|^$k=.*|$k=$v|" "$CONF"
      else
        echo "$k=$v" >> "$CONF"
      fi
    done
    # 按 PID 精确停守护。
    # 不能用 pkill -f '...service.sh'：实测会连带杀掉调用链上的进程（webctl 被自己打死，
    # 导致 netmode 没下发、守护没重启）。这里用锁文件里的 pid + 它的子进程（循环子壳）。
    LOCK=/data/adb/.smart5g.lock
    OLDPID=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$OLDPID" ] && [ -d "/proc/$OLDPID" ]; then
      for c in $(pgrep -P "$OLDPID" 2>/dev/null); do kill -9 "$c" 2>/dev/null; done
      kill -9 "$OLDPID" 2>/dev/null
    fi
    # 兜底：清掉可能残留的同路径进程（按绝对路径精确匹配，跳过自身）
    for p in $(pgrep -f "modules/smart5g/service[.]sh" 2>/dev/null); do
      [ "$p" = "$$" ] && continue
      kill -9 "$p" 2>/dev/null
    done
    sleep 1
    rm -rf "$LOCK"
    # 切回自动时清掉残留状态：上次"被迫回落 4G"的理由/冷却/卡住计时都不该继续生效，
    # 否则会卡在 4G 里等温度降到 temp_low 或等探测窗口。
    NMNOW=$(sed -n 's/^netmode=//p' "$CONF" 2>/dev/null | head -1)
    if [ "$NMNOW" = "auto" ]; then
      rm -f /data/adb/.smart5g_reason /data/adb/.smart5g_4g_since /data/adb/.smart5g_last
      # 手动回到自动 = 立即恢复 5G 能力，之后由守护按阈值重新判断
      sh "$MODDIR/bin/netmode.sh" 5g >> "$LOG" 2>&1
    else
      # 强制 4G / 强制 5G：立即生效，不等守护重启
      sh "$MODDIR/bin/netmode.sh" "$NMNOW" >> "$LOG" 2>&1
    fi
    setsid sh "$MODDIR/service.sh" >/dev/null 2>&1 &
    echo "saved"
    ;;
  4g|5g)
    sh "$MODDIR/bin/netmode.sh" "$1"
    ;;
  status)
    sh "$MODDIR/bin/netmode.sh" status
    ;;
  *)
    echo "usage: webctl.sh json|save k=v...|4g|5g|status"
    ;;
esac
