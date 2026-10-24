#!/system/bin/sh
# 正常开机：post-fs-data 阶段在系统启动完成前执行，这里直接退出，不影响原有流程。
# 越狱(late-load)：KSU 的 late-load 不重放 post-fs-data 阶段，而是直接跑 service 阶段
#   （见 KernelSU 源码 userspace/ksud/src/late_load.rs 第 12 步），所以本模块的守护
#   由 service.sh 自动拉起，无需依赖此脚本。
# 本脚本仅作为兜底：某些越狱工具只调用 `ksud post-fs-data` 而不走 late-load 流程，
#   此时系统已启动完成，就顺手把守护拉起来。
[ "$(getprop sys.boot_completed)" = "1" ] || exit 0
setsid sh "${0%/*}/service.sh" >/dev/null 2>&1 &
