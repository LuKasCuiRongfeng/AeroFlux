# AeroFlux Changelog

## v1.1.0

2026-04-12

架构重写版本：

1. 将安装器重构为新的 AeroFlux control plane
2. 重做变量命名、目录布局与运行状态模型
3. 改为独立服务账号托管主进程
4. 增加 systemd 配置校验与运行时硬化
5. 重写性能调优脚本，支持 apply/status/remove
6. 重写 README 与项目描述，统一为新的 AeroFlux 叙事

## v1.0.0

2026-04-12

首发版本：

1. 发布 AeroFlux 项目主线
2. 提供 VPS 一键安装器 `install.sh`
3. 集成 VLESS REALITY 与 Hysteria 2 双协议
4. 支持无域名部署
5. 安装完成后生成 v2rayN 可导入链接
6. 提供 systemd 托管与基础 BBR、UDP 调优能力
