---
name: 问题反馈
about: 模块没生效、切换异常、WebUI 打不开等
title: '[Bug] '
labels: bug
assignees: ''
---

## 设备信息

- 机型：
- 系统版本（ColorOS / realme UI）：
- Android 版本：
- KernelSU 版本（`ksud --version` 的输出）：

## 问题描述

<!-- 发生了什么？什么时候开始的？ -->

## 复现步骤

1.
2.
3.

## 日志

请贴出下面这条命令的输出（最后 30 行）：

```sh
su -c "tail -30 /data/adb/smart5g.log"
```

```
（把日志贴在这里）
```

## 配置

请贴出你的配置（如果改过）：

```sh
su -c "cat /data/adb/smart5g.conf"
```

```
（把配置贴在这里）
```

## 自检结果

请回答以下问题：

- [ ] 模块在 KernelSU 管理器里显示为「已启用」
- [ ] 重启过手机
- [ ] 系统支持 `cmd phone` 命令（在终端执行 `su -c "cmd phone help"` 有输出）
- [ ] WebUI 能打开（如果问题是 WebUI）

## 补充

<!-- 任何其他可能有帮助的信息 -->
