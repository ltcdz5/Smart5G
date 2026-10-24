#!/system/bin/sh
# 正常开机会走 KSU 的 service 阶段，这里不动。
# 越狱/late-load 模式下系统已启动完成，service 阶段不会再来，
# 此时若被 ksud post-fs-data 触发，就直接把守护拉起来。
[ "$(getprop sys.boot_completed)" = "1" ] || exit 0
setsid sh "${0%/*}/service.sh" >/dev/null 2>&1 &
