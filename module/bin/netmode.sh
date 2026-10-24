#!/system/bin/sh
# 5G/4G 静默切换
# 原理: cmd phone set-allowed-network-types-for-users -s <slot> <21位二进制>
#       最后一位 = bit0，bit19 = NR
#       关 NR 即回落 4G，全程静默无弹窗
#
# 用法: netmode.sh get | status | 4g | 5g
# 退出码: 0=成功 5=切换失败/超时

MASK_5G="111111111111111111111"   # 21 位全开（含 NR）
MASK_4G="101111111111111111111"   # bit19=0，关闭 NR

# 以"NR 是否被允许"为唯一判据。
# 不能用 gsm.network.type：关掉 NR 后该属性会残留 "NR_SA"（实测 GT5 Pro，
# 关 NR 后仍显示 LTE,NR_SA 数秒甚至更久），据此判断会误判为"已是 5G"而跳过下发，
# 导致强制 4G 换了网络却不生效、或切回 5G 时掩码永不恢复。
nr_allowed() {
    cmd phone get-allowed-network-types-for-users 2>/dev/null \
        | tr '|' '\n' | grep -qx "NR"
}

apply_mask() {
    local m="$1" ok=0 s
    for s in 0 1; do
        if cmd phone set-allowed-network-types-for-users -s $s "$m" >/dev/null 2>&1; then
            ok=1
        fi
    done
    [ "$ok" = "1" ]
}

ACTION="$1"
case "$ACTION" in
    get)
        getprop gsm.network.type | cut -d, -f1
        exit 0
        ;;
    status)
        if nr_allowed; then echo "5g (NR allowed)"; else echo "4g (NR blocked)"; fi
        echo "type=$(getprop gsm.network.type)"
        exit 0
        ;;
    4g|5g) ;;
    *)
        echo "usage: netmode.sh get|status|4g|5g"
        exit 1
        ;;
esac

if [ "$ACTION" = "4g" ]; then
    nr_allowed || { echo "already-4g"; exit 0; }
    apply_mask "$MASK_4G" || { echo "ERR:apply_failed"; exit 5; }
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        nr_allowed || { echo "4g-ok"; exit 0; }
    done
    echo "ERR:timeout_4g"
    exit 5
else
    nr_allowed && { echo "already-5g"; exit 0; }
    apply_mask "$MASK_5G" || { echo "ERR:apply_failed"; exit 5; }
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        nr_allowed && { echo "5g-ok"; exit 0; }
    done
    echo "ERR:timeout_5g"
    exit 5
fi
