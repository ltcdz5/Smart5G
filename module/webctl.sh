#!/system/bin/sh
# WebUI 控制脚本（按数据卡）
MODDIR=/data/adb/modules/smart5g
CONF=/data/adb/smart5g.conf
LOG=/data/adb/smart5g.log

DEFAULTS="netmode=auto interval=120 temp_high=40 temp_low=36 temp_critical=45 \
 sig_thres=-100 sig_good=-90 lowbat=20 lowbat_enable=1 n78_aggr=1 \
 skip_charging=0 cooldown=300 probe_interval=300 probe_window=20"

ensure_conf() {
    [ -f "$CONF" ] || : > "$CONF" 2>/dev/null
    local kv k
    for kv in $DEFAULTS; do
        k=${kv%%=*}
        grep -q "^$k=" "$CONF" 2>/dev/null || echo "$kv" >> "$CONF"
    done
    chmod 644 "$CONF" 2>/dev/null
}

getconf() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -1; }

json_escape() {
    sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g' \
      | awk 'BEGIN{ORS=""} {if(NR>1) printf "\\n"; printf "%s", $0}'
}

sh "$MODDIR/bin/netmode.sh" status >/dev/null 2>&1

data_slot() {
    local sub slot
    sub=$(settings get global multi_sim_data_call 2>/dev/null)
    case "$sub" in ''|-1|*[!0-9]*) echo 0; return ;; esac
    slot=$(dumpsys isub 2>/dev/null | awk -v want="$sub" '
        /SubscriptionInfoInternal/ {
            id=""; sl="";
            if (match($0, /id=[0-9]+/)) { t=substr($0, RSTART, RLENGTH); sub(/id=/, "", t); id=t }
            if (match($0, /simSlotIndex=[0-9]+/)) { t=substr($0, RSTART, RLENGTH); sub(/.*=/, "", t); sl=t }
            if (id == want && sl != "") { print sl; exit }
        }')
    echo "${slot:-0}"
}

slot_type() {
    local v
    v=$(getprop gsm.network.type 2>/dev/null)
    [ -z "$v" ] && { echo ""; return; }
    echo "$v" | cut -d, -f$(($1 + 1))
}

slot_nr_allowed() {
    cmd phone get-allowed-network-types-for-users -s "$1" 2>/dev/null \
        | tr '|' '\n' | grep -qx "NR"
}

slot_sim_name() {
    dumpsys isub 2>/dev/null | awk -v want="$1" '
        /SubscriptionInfoInternal/ {
            sl=""; nm="";
            if (match($0, /simSlotIndex=[0-9]+/)) { t=substr($0, RSTART, RLENGTH); sub(/.*=/, "", t); sl=t }
            if (match($0, /displayName=[^ ]+/)) { t=substr($0, RSTART, RLENGTH); sub(/displayName=/, "", t); nm=t }
            if (sl == want && nm != "") { print nm; exit }
        }'
}

ensure_conf

case "$1" in
  json)
    DS=$(data_slot)
    dtype=$(slot_type "$DS")
    [ -z "$dtype" ] && dtype="unknown"
    if slot_nr_allowed "$DS"; then nr=1; else nr=0; fi
    all=$(getprop gsm.network.type 2>/dev/null)
    temp=$(awk '{printf "%d", $1/10}' /sys/class/power_supply/battery/temp 2>/dev/null)
    cap=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
    chg=0
    case "$(cat /sys/class/power_supply/battery/status 2>/dev/null)" in
      *Charging*|*Full*) chg=1 ;;
    esac
    logtxt=$(tail -12 "$LOG" 2>/dev/null | json_escape)
    printf '{\n'
    printf '  "network": "%s",\n' "$dtype"
    printf '  "all_slots": "%s",\n' "$all"
    printf '  "data_slot": "%s",\n' "$DS"
    printf '  "data_sim": "%s",\n' "$(slot_sim_name "$DS")"
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
          case "$v" in auto|4g|5g) ;; *) continue ;; esac
          ;;
        interval|temp_high|temp_low|temp_critical|sig_thres|sig_good|lowbat|cooldown|probe_interval|probe_window|n78_aggr|lowbat_enable|skip_charging)
          case "$v" in *[!0-9-]*) continue ;; esac
          [ -z "$v" ] && continue
          ;;
        *) continue ;;
      esac
      if grep -q "^$k=" "$CONF" 2>/dev/null; then
        sed -i "s|^$k=.*|$k=$v|" "$CONF"
      else
        echo "$k=$v" >> "$CONF"
      fi
    done
    LOCK=/data/adb/.smart5g.lock
    OLDPID=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$OLDPID" ] && [ -d "/proc/$OLDPID" ]; then
      for c in $(pgrep -P "$OLDPID" 2>/dev/null); do kill -9 "$c" 2>/dev/null; done
      kill -9 "$OLDPID" 2>/dev/null
    fi
    for p in $(pgrep -f "modules/smart5g/service[.]sh" 2>/dev/null); do
      [ "$p" = "$$" ] && continue
      kill -9 "$p" 2>/dev/null
    done
    sleep 1
    rm -rf "$LOCK"
    NMNOW=$(sed -n 's/^netmode=//p' "$CONF" 2>/dev/null | head -1)
    if [ "$NMNOW" = "auto" ]; then
      rm -f /data/adb/.smart5g_reason /data/adb/.smart5g_4g_since /data/adb/.smart5g_backoff
      sh "$MODDIR/bin/netmode.sh" 5g >> "$LOG" 2>&1
    else
      sh "$MODDIR/bin/netmode.sh" "$NMNOW" >> "$LOG" 2>&1
    fi
    setsid sh "$MODDIR/service.sh" >/dev/null 2>&1 &
    echo "saved"
    ;;
  4g|5g|refresh)
    sh "$MODDIR/bin/netmode.sh" "$1"
    ;;
  status)
    sh "$MODDIR/bin/netmode.sh" status
    ;;
  *)
    echo "usage: webctl.sh json|save k=v...|4g|5g|refresh|status"
    ;;
esac