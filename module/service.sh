#!/bin/sh
# 智能 5G/4G 静默切换守护（按数据卡操作）
# 配置：/data/adb/smart5g.conf   日志：/data/adb/smart5g.log

MODDIR=${0%/*}
CONF=/data/adb/smart5g.conf
LOG=/data/adb/smart5g.log
COOL=/data/adb/.smart5g_last
REASON=/data/adb/.smart5g_reason
STUCK=/data/adb/.smart5g_4g_since
BACKOFF=/data/adb/.smart5g_backoff
COVERLOG=/data/adb/.smart5g_cover_log

log() { echo "[$(date '+%m-%d %H:%M:%S')] $1" >> "$LOG"; }

rotate() {
    [ -f "$1" ] || return 0
    local s; s=$(stat -c %s "$1" 2>/dev/null || echo 0)
    if [ "$s" -gt 65536 ]; then tail -n 40 "$1" > "$1.t" && mv -f "$1.t" "$1"; fi
}

is_charging() {
    case "$(cat /sys/class/power_supply/battery/status 2>/dev/null)" in
        *Charging*|*Full*) return 0 ;;
    esac
    local c
    c=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
    [ -n "$c" ] && [ "$c" -gt 0 ] && return 0
    return 1
}

# ---------- 数据卡相关 ----------
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

# 按卡读取 NR 的 ssRsrp。dumpsys 里每个 phone 一个 mServiceState 块，
# 块内的 mSignalStrength 行才带本卡的 ssRsrp；不能全局取最小值，否则两卡混算。
read_rsrp_slot() {
    local want=$(($1 + 1)) v
    v=$(timeout 3 dumpsys telephony.registry 2>/dev/null | awk -v want="$want" '
        /mServiceState=\{/ { phone++ }
        /mSignalStrength=/ && /CellSignalStrengthNr/ && phone == want {
            if (match($0, /ssRsrp = -?[0-9]+/)) {
                v = substr($0, RSTART + 9, RLENGTH - 9)
                if (v != "2147483647") print v
            }
        }' | head -1)
    echo "${v:-0}"
}

load_conf() {
    CONF_netmode=""; CONF_temp_high=""; CONF_temp_low=""; CONF_sig_thres=""
    CONF_sig_good=""; CONF_n78_aggr=""; CONF_skip_charging=""; CONF_cooldown=""
    CONF_lowbat=""; CONF_lowbat_enable=""; CONF_interval=""
    CONF_temp_critical=""; CONF_probe_interval=""; CONF_probe_window=""
    [ -f "$CONF" ] || return 0
    while IFS='=' read -r k v; do
        case "$k" in
            netmode)         CONF_netmode="$v" ;;
            temp_high)       CONF_temp_high="$v" ;;
            temp_low)        CONF_temp_low="$v" ;;
            sig_thres)       CONF_sig_thres="$v" ;;
            sig_good)        CONF_sig_good="$v" ;;
            n78_aggr)        CONF_n78_aggr="$v" ;;
            skip_charging)   CONF_skip_charging="$v" ;;
            cooldown)        CONF_cooldown="$v" ;;
            lowbat)          CONF_lowbat="$v" ;;
            lowbat_enable)   CONF_lowbat_enable="$v" ;;
            interval)        CONF_interval="$v" ;;
            temp_critical)   CONF_temp_critical="$v" ;;
            probe_interval)  CONF_probe_interval="$v" ;;
            probe_window)    CONF_probe_window="$v" ;;
        esac
    done < "$CONF"
}

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 120 ]; do sleep 1; i=$((i+1)); done
sleep 3
[ -f "$CONF" ] || { log "no conf, exit"; exit 0; }
rotate "$LOG"

loop() {
  local rsrp t cap chg hi lo sth sgood aggr skipchg cd now last
  local need can th interval lbth lben why reason temp_ok bat_ok
  local first=1 failcnt=0 forced_tick=0 n
  local tcrit pint pwin bko nb since
  local DS dtype allowed on_nr band

  load_conf
  interval=${CONF_interval:-120}
  DS=$(data_slot)
  log "smart5g started, interval=${interval}s, 数据卡=slot${DS}"

  while true; do
    [ "$first" = "1" ] && first=0 || sleep "$interval"
    n=$(( ${n:-0} + 1 ))
    [ $((n % 10)) -eq 0 ] && { load_conf; DS=$(data_slot); }

    if [ "${CONF_netmode:-auto}" != "auto" ]; then
      forced_tick=$((forced_tick+1))
      [ $((forced_tick % 10)) -eq 1 ] && log "强制模式 ${CONF_netmode}，守护跳过判定（心跳）"
      continue
    fi
    forced_tick=0

    bvals=$(awk '{print $1}' \
        /sys/class/power_supply/battery/temp \
        /sys/class/power_supply/battery/capacity \
        /sys/class/power_supply/battery/current_now 2>/dev/null | tr '\n' ' ')
    set -- $bvals
    t=${1:-0}; cap=${2:-0}
    [ "$t" = "0" ] && continue
    t=$((t/10))

    hi=${CONF_temp_high:-40}
    lo=${CONF_temp_low:-36}
    sth=${CONF_sig_thres:--100}
    sgood=${CONF_sig_good:--90}
    aggr=${CONF_n78_aggr:-1}
    skipchg=${CONF_skip_charging:-0}
    cd=${CONF_cooldown:-300}
    lbth=${CONF_lowbat:-20}
    lben=${CONF_lowbat_enable:-1}
    tcrit=${CONF_temp_critical:-45}
    pint=${CONF_probe_interval:-300}
    pwin=${CONF_probe_window:-20}

    dtype=$(slot_type "$DS")
    if slot_nr_allowed "$DS"; then allowed=1; else allowed=0; fi
    case "$dtype" in *NR*) on_nr=1 ;; *) on_nr=0 ;; esac

    chg=0; is_charging && chg=1

    hot=0
    if [ "$t" -ge "$hi" ]; then
      if [ "$chg" = "1" ] && [ "$t" -lt "$tcrit" ]; then hot=0; else hot=1; fi
    fi

    lowbat=0
    if [ "$lben" = "1" ] && [ -n "$cap" ] && [ "$cap" -le "$lbth" ]; then
      [ "$chg" = "1" ] || lowbat=1
    fi

    need=0; can=0; rsrp=0
    now=$(date +%s)
    reason=$(cat "$REASON" 2>/dev/null || echo "")

    if [ "$on_nr" = "1" ]; then
      # 数据卡确实注册在 5G 上，才按阈值判断要不要回落
      if [ "$hot" = "1" ]; then
        need=1; why="hot"
      elif [ "$lowbat" = "1" ]; then
        need=1; why="lowbat"
      elif [ "$sth" != "0" ]; then
        rsrp=$(read_rsrp_slot "$DS")
        th=$sth
        if [ "$aggr" = "1" ]; then
          band=$(timeout 3 dumpsys telephony.registry 2>/dev/null | grep -m1 -oE 'mBands = \[[0-9, ]*78[,0-9 ]*\]')
          [ -n "$band" ] && th=$((sth + 5))
        fi
        if [ "$rsrp" -ne 0 ] && [ "$rsrp" -lt "$th" ]; then
          need=1; why="weak"
        fi
      fi
    else
      temp_ok=0
      case "$reason" in
        hot) [ "$t" -le "$lo" ] && temp_ok=1 ;;
        *)   [ "$t" -lt "$hi" ] && temp_ok=1 ;;
      esac
      bat_ok=0
      if [ -z "$cap" ]; then bat_ok=1
      elif [ "$lben" != "1" ]; then bat_ok=1
      elif [ "$cap" -gt "$((lbth + 3))" ]; then bat_ok=1
      fi

      if [ "$allowed" = "1" ]; then
        # NR 已允许，但数据卡停在 LTE。
        # 实测：用掩码把 NR 关掉再放开后，modem 有时不会自己重新注册 NR，
        # 会一直卡在 LTE（掩码与 type 不一致）。按退避间隔做一次重新注册。
        if [ "$temp_ok" = "1" ] && [ "$bat_ok" = "1" ]; then
          if [ -n "$reason" ]; then rm -f "$REASON"; reason=""; fi
          since=$(cat "$STUCK" 2>/dev/null || echo 0)
          bko=$(cat "$BACKOFF" 2>/dev/null || echo "$pint")
          [ -n "$bko" ] || bko="$pint"
          if [ "$since" = "0" ] || [ -z "$since" ]; then
            echo "$now" > "$STUCK"
          elif [ $((now - since)) -ge "$bko" ]; then
            echo "$now" > "$STUCK"
            log "数据卡(slot${DS})在 4G 但 NR 已允许，尝试重新注册（间隔${bko}s）"
            res=$(sh "$MODDIR/bin/netmode.sh" refresh 2>&1 | tail -1)
            dtype=$(slot_type "$DS")
            case "$dtype" in *NR*) on_nr=1 ;; *) on_nr=0 ;; esac
            if [ "$on_nr" = "1" ]; then
              can=1; rm -f "$BACKOFF" "$STUCK"
              log "重新注册成功（${res}），数据卡已回到 5G"
            else
              nb=$((bko * 2)); [ "$nb" -gt 3600 ] && nb=3600
              echo "$nb" > "$BACKOFF"
              log "重新注册未成功（${res}），下次尝试在 ${nb} 秒后"
            fi
          fi
        fi
      else
        # 我们自己（或用户手动）把 NR 关了，条件恢复就放回去
        if [ "$temp_ok" = "1" ] && [ "$bat_ok" = "1" ]; then
          if [ "$reason" = "weak" ]; then
            since=$(cat "$STUCK" 2>/dev/null || echo 0)
            bko=$(cat "$BACKOFF" 2>/dev/null || echo "$pint")
            [ -n "$bko" ] || bko="$pint"
            if [ "$since" = "0" ] || [ -z "$since" ]; then
              echo "$now" > "$STUCK"
              log "因弱信号回落，${bko} 秒后探测一次"
            elif [ $((now - since)) -ge "$bko" ]; then
              rm -f "$STUCK"
              log "开始探测 5G（临时放开 NR ${pwin} 秒）"
              sh "$MODDIR/bin/netmode.sh" 5g -s "$DS" >> "$LOG" 2>&1
              sleep "$pwin"
              rsrp=$(read_rsrp_slot "$DS")
              dtype=$(slot_type "$DS")
              case "$dtype" in *NR*) on_nr=1 ;; *) on_nr=0 ;; esac
              if [ "$on_nr" = "1" ] && [ "$rsrp" -ne 0 ] && [ "$rsrp" -ge "$sgood" ]; then
                can=1
                rm -f "$BACKOFF"
                log "探测成功：rsrp=${rsrp}dBm，保持 5G"
              else
                sh "$MODDIR/bin/netmode.sh" 4g -s "$DS" >> "$LOG" 2>&1
                echo "$now" > "$STUCK"
                nb=$((bko * 2)); [ "$nb" -gt 3600 ] && nb=3600
                echo "$nb" > "$BACKOFF"
                log "探测失败：rsrp=${rsrp} type=${dtype}，回落 4G；下次探测在 ${nb} 秒后"
              fi
            fi
          else
            can=1
            rm -f "$STUCK" "$BACKOFF"
            log "温度/电量已恢复（旧原因=${reason:-无}），切回 5G"
          fi
        fi
      fi
    fi

    [ "$need" = "0" ] && [ "$can" = "0" ] && continue

    last=$(cat "$COOL" 2>/dev/null || echo 0)
    [ $((now - last)) -lt "$cd" ] && continue

    if [ "$need" = "1" ]; then
      if [ "$skipchg" = "1" ] && [ "$chg" = "1" ] && [ "$hot" = "0" ]; then continue; fi
      case "${why:-unknown}" in
        lowbat) log "切4G[低电量]: cap=${cap}%(阈值${lbth}%) temp=${t}C slot${DS}" ;;
        hot)    log "切4G[高温]: temp=${t}C(阈值${hi}) chg=${chg} slot${DS}" ;;
        weak)   log "切4G[弱信号]: rsrp=${rsrp}dBm(阈值${th}) temp=${t}C slot${DS}" ;;
        *)      log "切4G[未知]: temp=${t}C cap=${cap}% slot${DS}" ;;
      esac
      if sh "$MODDIR/bin/netmode.sh" 4g -s "$DS" >> "$LOG" 2>&1; then
        echo "$now" > "$COOL"; echo "${why:-unknown}" > "$REASON"; failcnt=0
      else
        log "  ↑ 切换失败，60 秒后重试"
        echo $((now - cd + 60)) > "$COOL"
        failcnt=$((failcnt+1))
        [ $failcnt -ge 3 ] && log "!! 连续 ${failcnt} 次切换失败，请检查 cmd phone 可用性"
      fi
    else
      log "切5G: temp=${t}C cap=${cap}% rsrp=${rsrp} slot${DS}"
      if sh "$MODDIR/bin/netmode.sh" 5g -s "$DS" >> "$LOG" 2>&1; then
        echo "$now" > "$COOL"; rm -f "$REASON" "$STUCK" "$BACKOFF"; failcnt=0
        # 放开 NR 不等于已注册，验证一次；没注册就推一把
        dtype=$(slot_type "$DS")
        case "$dtype" in
          *NR*) ;;
          *)
            res=$(sh "$MODDIR/bin/netmode.sh" refresh 2>&1 | tail -1)
            log "放开 NR 后数据卡未注册，重新注册：${res}"
            ;;
        esac
      else
        log "  ↑ 切换失败，60 秒后重试"
        echo $((now - cd + 60)) > "$COOL"
        failcnt=$((failcnt+1))
        [ $failcnt -ge 3 ] && log "!! 连续 ${failcnt} 次切换失败，请检查 cmd phone 可用性"
      fi
    fi
  done
}

# 单实例保护
LOCKDIR=/data/adb/.smart5g.lock
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    OLD=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -n "$OLD" ] && [ -d "/proc/$OLD" ]; then
        log "已有实例在运行 (pid $OLD)，本次启动退出"
        exit 0
    fi
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT INT TERM

NM=$(sed -n 's/^netmode=//p' "$CONF" 2>/dev/null | head -1)
case "$NM" in
  4g) sh "$MODDIR/bin/netmode.sh" 4g >> "$LOG" 2>&1 ;;
  5g) sh "$MODDIR/bin/netmode.sh" 5g >> "$LOG" 2>&1 ;;
esac

loop &
LOOP_PID=$!
log "smart5g watcher started (pid $$, loop $LOOP_PID)"
wait $LOOP_PID
