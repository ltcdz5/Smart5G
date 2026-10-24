#!/system/bin/sh
# 智能 5G/4G 静默切换守护
# 配置文件：/data/adb/smart5g.conf
# 日志：    /data/adb/smart5g.log

MODDIR=${0%/*}
CONF=/data/adb/smart5g.conf
LOG=/data/adb/smart5g.log
COOL=/data/adb/.smart5g_last
REASON=/data/adb/.smart5g_reason
STUCK=/data/adb/.smart5g_4g_since

log() { echo "[$(date '+%m-%d %H:%M:%S')] $1" >> "$LOG"; }

rotate() {
    [ -f "$1" ] || return 0
    local s; s=$(stat -c %s "$1" 2>/dev/null || echo 0)
    if [ "$s" -gt 65536 ]; then tail -n 40 "$1" > "$1.t" && mv -f "$1.t" "$1"; fi
}

is_charging() {
    # 以 status 为主要判据（各家充电驱动对电流正负号定义不一致，只看 current_now 会误判）
    case "$(cat /sys/class/power_supply/battery/status 2>/dev/null)" in
        *Charging*|*Full*) return 0 ;;
    esac
    local c
    c=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
    [ -n "$c" ] && [ "$c" -gt 0 ] && return 0
    return 1
}

# 以"NR 是否被允许"为唯一判据。
# 不能用 gsm.network.type：关掉 NR 后该属性会残留 "NR_SA"（GT5 Pro 实测），
# 据此判断会把 4G 状态误判成 5G，导致高温/弱信号分支永远不触发。
nr_allowed() {
    cmd phone get-allowed-network-types-for-users 2>/dev/null \
        | tr '|' '\n' | grep -qx "NR"
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

read_rsrp() {
    local v
    v=$(timeout 3 dumpsys telephony.registry 2>/dev/null | tr ',' '\n' \
        | awk '/mNr=CellSignalStrengthNr/{f=1} f&&/ssRsrp/{print; f=0}' \
        | grep -oE '\-?[0-9]+' | grep -v 2147483647 | sort -n | head -1)
    if [ -z "$v" ]; then
        v=$(timeout 3 dumpsys telephony.registry 2>/dev/null \
            | grep -oE 'ssRsrp = -?[0-9]+' | head -4 \
            | grep -oE '\-?[0-9]+' | grep -v 2147483647 | sort -n | head -1)
    fi
    echo "${v:-0}"
}

# 探测一次 5G：临时放开 NR，等 probe_window 秒后测 RSRP。
# 返回测到的 RSRP（0 表示仍然读不到）。调用方决定保持还是重新关闭。
probe_nr() {
    local pw="$1" r
    sh "$MODDIR/bin/netmode.sh" 5g >> "$LOG" 2>&1
    sleep "$pw"
    r=$(read_rsrp)
    echo "$r"
}

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 120 ]; do sleep 1; i=$((i+1)); done
sleep 3
[ -f "$CONF" ] || { log "no conf, exit"; exit 0; }
rotate "$LOG"

smart5g_loop() {
  local rsrp t b78 chg hi lo sth sgood aggr skipchg cd now last cur curm allowed
  local hot need can th interval band
  local cap lbth lben lowbat chg0 why reason temp_ok bat_ok since
  local first=1
  local failcnt=0
  local tcrit pint pwin forced_tick=0

  load_conf
  interval=${CONF_interval:-120}
  log "smart5g started, interval=${interval}s"

  while true; do
    [ "$first" = "1" ] && first=0 || sleep "$interval"

    RR=$(( ${RR:-0} + 1 ))
    [ $((RR % 10)) -eq 0 ] && load_conf
    # 强制模式下不判定，但要留心跳日志，避免用户误以为守护挂了
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
    t=${1:-0}; cap=${2:-0}; chg0=${3:-0}
    [ "$t" = "0" ] && continue
    t=$((t/10))

    # 当前网络档位：查"NR 是否被允许"，而不是"modem 注册在哪种 RAT"
    cur=$(getprop gsm.network.type)
    if cmd phone get-allowed-network-types-for-users >/dev/null 2>&1; then
      if nr_allowed; then curm=5g; else curm=4g; fi
    else
      # 兜底：cmd 不可用时退回属性判断（含 NR 才视为 5G）
      case "$cur" in
        *NR*) curm=5g ;;
        *)    curm=4g ;;
      esac
    fi

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
    pint=${CONF_probe_interval:-600}
    pwin=${CONF_probe_window:-20}

    chg=0; is_charging && chg=1

    # 充电时电池温度天然偏高（快充 42℃ 属正常），不能当"手机烫"。
    # 只有超过 temp_critical 才在充电中也按高温回落。
    hot=0
    if [ "$t" -ge "$hi" ]; then
      if [ "$chg" = "1" ] && [ "$t" -lt "$tcrit" ]; then
        hot=0
      else
        hot=1
      fi
    fi

    lowbat=0
    if [ "$lben" = "1" ] && [ -n "$cap" ] && [ "$cap" -le "$lbth" ]; then
      [ "$chg" = "1" ] || lowbat=1
    fi

    need=0; can=0; rsrp=0
    now=$(date +%s)
    reason=$(cat "$REASON" 2>/dev/null || echo "")

    if [ "$curm" = "5g" ]; then
      if [ "$hot" = "1" ]; then
        need=1; why="hot"
      elif [ "$lowbat" = "1" ]; then
        need=1; why="lowbat"
      elif [ "$sth" != "0" ]; then
        rsrp=$(read_rsrp)
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
      if [ -z "$cap" ]; then
        bat_ok=1
      elif [ "$lben" != "1" ]; then
        bat_ok=1
      elif [ "$cap" -gt "$((lbth + 3))" ]; then
        bat_ok=1
      fi

      if [ "$temp_ok" = "1" ] && [ "$bat_ok" = "1" ]; then
        rsrp=$(read_rsrp)
        if [ "$rsrp" -ne 0 ] && [ "$rsrp" -gt "$sgood" ]; then
          can=1
          rm -f "$STUCK"
        elif [ "$rsrp" -eq 0 ]; then
          # NR 被关闭时 modem 不再上报 NR 测量值，只能靠定时探测。
          since=$(cat "$STUCK" 2>/dev/null || echo 0)
          if [ "$since" = "0" ] || [ -z "$since" ]; then
            echo "$now" > "$STUCK"
            log "4G 下读不到 NR 信号，${pint} 秒后探测一次"
          elif [ $((now - since)) -gt "$pint" ]; then
            rm -f "$STUCK"
            log "开始探测 5G（临时放开 NR ${pwin} 秒）"
            rsrp=$(probe_nr "$pwin")
            if [ "$rsrp" -ne 0 ] && [ "$rsrp" -gt "$sgood" ]; then
              can=1
              log "探测成功：rsrp=${rsrp}dBm（优于${sgood}），保持 5G"
            else
              sh "$MODDIR/bin/netmode.sh" 4g >> "$LOG" 2>&1
              echo "$now" > "$STUCK"
              log "探测失败：rsrp=${rsrp}，重新回落 4G"
            fi
          fi
        fi
      fi
    fi

    [ "$need" = "0" ] && [ "$can" = "0" ] && continue

    last=$(cat "$COOL" 2>/dev/null || echo 0)
    [ $((now - last)) -lt "$cd" ] && continue

    if [ "$need" = "1" ]; then
      if [ "$skipchg" = "1" ] && [ "$chg" = "1" ] && [ "$hot" = "0" ]; then
        continue
      fi
      case "${why:-unknown}" in
        lowbat) log "切4G[低电量]: cap=${cap}%(阈值${lbth}%) temp=${t}C" ;;
        hot)    log "切4G[高温]: temp=${t}C(阈值${hi}) chg=${chg} rsrp=${rsrp}" ;;
        weak)   log "切4G[弱信号]: rsrp=${rsrp}dBm(阈值${th}) temp=${t}C" ;;
        *)      log "切4G[未知]: temp=${t}C cap=${cap}%" ;;
      esac
      if sh "$MODDIR/bin/netmode.sh" 4g >> "$LOG" 2>&1; then
        echo "$now" > "$COOL"
        echo "${why:-unknown}" > "$REASON"
        failcnt=0
      else
        log "  ↑ 切换失败，60 秒后重试"
        echo $((now - cd + 60)) > "$COOL"
        failcnt=$((failcnt+1))
        [ $failcnt -ge 3 ] && log "!! 连续 ${failcnt} 次切换失败，请检查 cmd phone 可用性"
      fi
    else
      log "切5G: temp=${t}C cap=${cap}%(已过$((lbth+3))%) rsrp=${rsrp}(优于${sgood})"
      if sh "$MODDIR/bin/netmode.sh" 5g >> "$LOG" 2>&1; then
        echo "$now" > "$COOL"
        rm -f "$REASON" "$STUCK"
        failcnt=0
      else
        log "  ↑ 切换失败，60 秒后重试"
        echo $((now - cd + 60)) > "$COOL"
        failcnt=$((failcnt+1))
        [ $failcnt -ge 3 ] && log "!! 连续 ${failcnt} 次切换失败，请检查 cmd phone 可用性"
      fi
    fi
  done
}

NM=$(sed -n 's/^netmode=//p' "$CONF" 2>/dev/null | head -1)
case "$NM" in
  4g)  sh "$MODDIR/bin/netmode.sh" 4g >> "$LOG" 2>&1 ;;
  5g)  sh "$MODDIR/bin/netmode.sh" 5g >> "$LOG" 2>&1 ;;
esac

# ---------- 单实例保护 ----------
# pkill 发 SIGTERM 在本机杀不掉（实测退出码 0 但进程仍在），所以用锁目录兜底，
# 避免反复保存配置后堆出多个守护互相打架。
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

smart5g_loop &
LOOP_PID=$!
log "smart5g watcher started (pid $$, loop $LOOP_PID)"
wait $LOOP_PID
