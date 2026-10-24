#!/system/bin/sh
# 5G/4G 静默切换（按数据卡操作）
#
# 用法:
#   netmode.sh get | status
#   netmode.sh 4g|5g [-s SLOT]
#   netmode.sh refresh [-s SLOT]     重新注册 5G（两级兜底）
#
# 背景：用掩码把 NR 关掉再放开后，modem 有时不会自己重新注册 NR，
#       表现为"掩码已允许 NR，但数据卡一直停在 LTE"。此时需要轻推一次。

MASK_5G="111111111111111111111"
MASK_4G="101111111111111111111"

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

on_nr() {
    case "$(slot_type "$1")" in *NR*) return 0 ;; *) return 1 ;; esac
}

slot_nr_allowed() {
    cmd phone get-allowed-network-types-for-users -s "$1" 2>/dev/null \
        | tr '|' '\n' | grep -qx "NR"
}

apply_mask() {
    cmd phone set-allowed-network-types-for-users -s "$1" "$2" >/dev/null 2>&1
}

wait_nr() {
    local s="$1" n="$2" i
    i=0
    while [ $i -lt "$n" ]; do
        on_nr "$s" && return 0
        sleep 3
        i=$((i + 1))
    done
    on_nr "$s" && return 0
    return 1
}

ACTION="$1"
[ -z "$ACTION" ] && ACTION=status
shift 2>/dev/null

SLOT=""
ALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SLOT="$2"; shift 2 ;;
        all) ALL=1; shift ;;
        *) shift ;;
    esac
done

case "$ACTION" in
    get)
        S="${SLOT:-$(data_slot)}"
        slot_type "$S" | cut -d, -f1
        exit 0
        ;;
    status)
        DS=$(data_slot)
        echo "数据卡 = slot$DS（$(slot_type "$DS")）"
        for s in 0 1 2; do
            t=$(slot_type "$s")
            [ -z "$t" ] && continue
            if slot_nr_allowed "$s"; then a="NR允许"; else a="NR关闭"; fi
            mark=""; [ "$s" = "$DS" ] && mark=" ←数据卡"
            echo "  slot$s: $t  $a$mark"
        done
        exit 0
        ;;
    refresh)
        DS="${SLOT:-$(data_slot)}"
        if on_nr "$DS"; then echo "already-nr"; exit 0; fi
        # 一级：只关/开移动数据（轻，不影响 WiFi）
        svc data disable 2>/dev/null
        sleep 3
        svc data enable 2>/dev/null
        if wait_nr "$DS" 6; then echo "refresh-ok-data"; exit 0; fi
        # 二级：飞行模式（重），完事后恢复 WiFi
        W=$(settings get global wifi_on 2>/dev/null)
        cmd connectivity airplane-mode enable 2>/dev/null
        sleep 4
        cmd connectivity airplane-mode disable 2>/dev/null
        if [ "$W" = "1" ]; then sleep 3; svc wifi enable 2>/dev/null; fi
        if wait_nr "$DS" 10; then echo "refresh-ok-airplane"; exit 0; fi
        echo "refresh-fail"
        exit 5
        ;;
    4g|5g|4g-all|5g-all) ;;
    *)
        echo "usage: netmode.sh get|status|refresh|4g|5g|4g-all|5g-all [-s SLOT]"
        exit 1
        ;;
esac

case "$ACTION" in
    *-all) MODE=${ACTION%-all}; ALL=1 ;;
    *)     MODE="$ACTION" ;;
esac
if [ "$MODE" = "4g" ]; then MASK="$MASK_4G"; WANT_ON=0; else MASK="$MASK_5G"; WANT_ON=1; fi

if [ "$ALL" = "1" ]; then TARGETS="0 1 2"
elif [ -n "$SLOT" ]; then TARGETS="$SLOT"
else TARGETS=$(data_slot); fi

changed=0
for s in $TARGETS; do
    t=$(slot_type "$s")
    [ -z "$t" ] && continue
    if slot_nr_allowed "$s"; then cur=1; else cur=0; fi
    [ "$cur" = "$WANT_ON" ] && continue
    apply_mask "$s" "$MASK" && changed=1
done

if [ "$changed" = "0" ]; then
    echo "already-${MODE}"
    exit 0
fi

for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    ok=1
    for s in $TARGETS; do
        t=$(slot_type "$s")
        [ -z "$t" ] && continue
        if slot_nr_allowed "$s"; then cur=1; else cur=0; fi
        [ "$cur" = "$WANT_ON" ] || ok=0
    done
    [ "$ok" = "1" ] && { echo "${MODE}-ok"; exit 0; }
done
echo "ERR:timeout_${MODE}"
exit 5
