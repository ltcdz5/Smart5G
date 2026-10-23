#!/system/bin/sh
# WebUI 控制脚本（JSON 安全转义版）
MODDIR=/data/adb/modules/smart5g
CONF=/data/adb/smart5g.conf
LOG=/data/adb/smart5g.log

getconf() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -1; }

# 把多行日志转成一个合法的 JSON 字符串内容：
# 反斜杠 -> \  ，双引号 -> \"  ，换行 -> 字面量 \n
json_escape() {
    sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g' \
      | awk 'BEGIN{ORS=""} {if(NR>1) printf "\\n"; printf "%s", $0}'
}

case "$1" in
  json)
    net=$(getprop gsm.network.type | cut -d, -f1)
    temp=$(awk '{printf "%d", $1/10}' /sys/class/power_supply/battery/temp 2>/dev/null)
    cap=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    logtxt=$(tail -12 "$LOG" 2>/dev/null | json_escape)
    printf '{\n'
    printf '  "network": "%s",\n' "$net"
    printf '  "temp": "%s",\n' "$temp"
    printf '  "cap": "%s",\n' "$cap"
    printf '  "netmode": "%s",\n' "$(getconf netmode)"
    printf '  "interval": "%s",\n' "$(getconf interval)"
    printf '  "temp_high": "%s",\n' "$(getconf temp_high)"
    printf '  "temp_low": "%s",\n' "$(getconf temp_low)"
    printf '  "sig_thres": "%s",\n' "$(getconf sig_thres)"
    printf '  "sig_good": "%s",\n' "$(getconf sig_good)"
    printf '  "lowbat": "%s",\n' "$(getconf lowbat)"
    printf '  "cooldown": "%s",\n' "$(getconf cooldown)"
    printf '  "lowbat_enable": "%s",\n' "$(getconf lowbat_enable)"
    printf '  "log": "%s"\n' "$logtxt"
    printf '}\n'
    ;;
  save)
    shift
    for kv in "$@"; do
      k=${kv%%=*}
      v=${kv#*=}
      case "$k" in
        netmode|interval|temp_high|temp_low|sig_thres|sig_good|lowbat|cooldown|lowbat_enable)
          case "$v" in
            *[!0-9-]*) continue ;;
          esac
          [ -z "$v" ] && continue
          if grep -q "^$k=" "$CONF" 2>/dev/null; then
            sed -i "s|^$k=.*|$k=$v|" "$CONF"
          else
            echo "$k=$v" >> "$CONF"
          fi
          ;;
      esac
    done
    pkill -f 'smart5g/service.sh' 2>/dev/null
    sleep 1
    setsid sh "$MODDIR/service.sh" >/dev/null 2>&1 &
    echo "saved"
    ;;
  4g|5g)
    sh "$MODDIR/bin/netmode.sh" "$1"
    ;;
  *)
    echo "usage: webctl.sh json|save k=v...|4g|5g"
    ;;
esac
