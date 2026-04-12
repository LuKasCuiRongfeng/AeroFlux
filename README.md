# AeroFlux

AeroFlux 是一个围绕高性能自建链路重新设计的 VPS 项目，不是“多功能大杂烩脚本”的删减版，而是一套更专注的双入口部署平面：

- 以 VLESS REALITY 作为稳态入口
- 以 Hysteria 2 作为吞吐入口
- 以 sing-box 作为最小核心
- 以 systemd 硬化与性能档案作为运行底座

它的目标不是“协议越多越强”，而是把真正有价值的两条链路打磨到更高完成度。

## 新架构

这一版 AeroFlux 的实现重点是：

- 独立的目录布局：配置、状态、核心、控制平面分离
- 独立服务账号：不再默认以 root 常驻运行主进程
- systemd 硬化：启动前校验配置，限制能力边界
- release 资产拉取：直接从 sing-box 官方 release 获取最新内核
- 运行信息持久化：通过 `runtime.env` 记录节点元数据
- 独立性能档案：将 BBR 和 UDP 调优从安装逻辑中拆出

当前目录布局：

- `/etc/aeroflux` 保存配置与分享链接
- `/var/lib/aeroflux` 保存运行时状态
- `/usr/local/lib/aeroflux` 保存核心与控制平面
- `/usr/local/bin/afx` 提供日常管理入口

## 技术栈

- sing-box 作为转发核心
- VLESS REALITY 作为主稳态协议
- Hysteria 2 作为主高速协议
- 自签 TLS 作为无域名场景的 Hysteria 2 落地方案
- systemd sandbox 作为服务托管层
- BBR + UDP profile 作为基础性能增强层

## 安装

在 VPS 上直接执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LuKasCuiRongfeng/AeroFlux/main/install.sh)
```

如果你想先审阅代码再安装：

```bash
git clone https://github.com/LuKasCuiRongfeng/AeroFlux.git
cd AeroFlux
chmod +x install.sh
sudo ./install.sh
```

安装过程会询问：

- 节点标签
- REALITY 握手站点
- REALITY TCP 端口
- Hysteria 2 UDP 端口
- Hysteria 2 模式：`BBR 自适应` 或 `Brutal 锁带宽`
- 如果选择 `Brutal`，再继续填写服务端与客户端的上下行带宽
- 是否立即应用性能档案

## 管理方式

安装完成后，可以继续用仓库脚本管理，也可以直接使用控制命令：

```bash
sudo ./install.sh deploy
sudo ./install.sh links
sudo ./install.sh refresh
sudo ./install.sh status
sudo ./install.sh tune
sudo ./install.sh uninstall
```

或者：

```bash
sudo afx
sudo afx links
sudo afx refresh
sudo afx status
sudo afx tune
sudo afx uninstall
```

性能档案支持独立操作：

```bash
sudo afx tune apply
sudo afx tune status
sudo afx tune remove
```

## 输出结果

安装完成后会生成：

- `/etc/aeroflux/node.json`
- `/etc/aeroflux/runtime.env`
- `/etc/aeroflux/share-links.txt`
- `/etc/aeroflux/hy2-v2rayn-manual.txt`
- `/etc/aeroflux/hy2-client-singbox.json`
- `/etc/aeroflux/hy2-client-hysteria.yaml`
- `/etc/aeroflux/tls.crt`
- `/etc/aeroflux/tls.key`

脚本会直接打印两条 v2rayN 可导入链接：

1. REALITY 稳态链路
2. Hysteria 2 高吞吐链路

如果选择的是 `Brutal` 模式，Hysteria 2 链接会附带客户端带宽参数，但部分 v2rayN 版本不会把 Up/Down Mbps 自动写入节点编辑页。
如果导入后发现 Hysteria 最大流量为空，请直接按 `/etc/aeroflux/hy2-v2rayn-manual.txt` 手工填写，或者改用 `/etc/aeroflux/hy2-client-singbox.json` 作为客户端配置参考。
如果选择的是 `BBR 自适应` 模式，请把 v2rayN 的 Hysteria 最大流量 `Up/Dw` 留空。这一模式依赖 BBR 根据实时 RTT、丢包和带宽估计自行收敛，更适合链路上限不稳定或难以准确估计的场景。
如果你在 v2rayN 里测速始终跑不满，请优先检查 Hysteria 2 的核心类型。v2rayN 默认往往仍是 `Xray`，而 Hysteria 2 的表现很可能取决于你是否切到了 `sing-box` 或 `hysteria2` 原生核心。AeroFlux 现在会额外生成 `/etc/aeroflux/hy2-client-hysteria.yaml`，用于做原生 Hysteria2 客户端 A/B 对比，帮助排除“桌面客户端核心路径本身就是瓶颈”的情况。
如果你只是做节点测速、全局代理或单节点直连测试，v2rayN 参数设置里的流量探测类型通常不需要额外勾 `quic`。这个选项主要影响 Tun 分流时对 QUIC 目标的识别，不会直接提高 Hysteria 2 吞吐，反而会给客户端路径再增加一个变量。
如果同机对照已经证明最终 `hy2` 配置差异很小，但吞吐仍明显偏低，那么更应该怀疑 `systemd` 运行限制、`UFW/iptables` 路径和过度激进的 `sysctl` 调优，而不是继续盯着 `hy2` 链接参数本身。

推荐使用策略：

- 日常主用 REALITY
- 压测、测速、大流量优先 Hysteria 2
- 两条链路同时保留，按实时网络表现切换

## 无域名策略

AeroFlux 默认按无域名部署设计：

- REALITY 使用外部握手站点，不要求你持有域名
- Hysteria 2 使用自签 TLS 材料
- 生成的 Hysteria 2 链接自动附带 `insecure=1`
- Hysteria 2 服务端默认保持极简入站，不额外挂额外 H3 反代行为，避免无关变量影响吞吐测试

这套设计的核心不是“伪装更多”，而是：

- 用 REALITY 负责兼容性和可用性
- 用 Hysteria 2 负责把 QUIC/UDP 的吞吐能力吃满

## 运行建议

- 优先 Ubuntu 22.04 或 24.04
- 只在干净 VPS 上部署，不混跑重服务
- 明确放行 REALITY 对应 TCP 端口与 Hysteria 2 对应 UDP 端口
- 优先选择跨境链路质量更高的机房
- 在内核支持的前提下开启性能档案
- 如果目标是做高吞吐场景测试，优先先用 `BBR 自适应` 模式测试
- 只有在线路特征很清楚时，再切到 `Brutal 锁带宽`，并让服务端与客户端带宽值贴近真实链路，虚高会影响吞吐稳定性
- 如果 v2rayN 里 Hysteria 2 仍然偏慢，先把该协议的核心切到 `sing-box` 或 `hysteria2` 原生核心再测，不要直接用默认 `Xray` 路径下结论
- 如果同机对照后仍明显慢，优先测试关闭主机防火墙或改用云防火墙放行，并避免套用过重的 `sysctl` 魔改参数

## 路线

AeroFlux 后续的迭代方向只围绕下面几件事：

- 提升 REALITY 默认参数的稳态表现
- 提升 Hysteria 2 在高带宽场景下的吞吐效率
- 继续强化控制平面、配置校验和系统硬化
- 优化 v2rayN 与桌面客户端导入体验

## License

This project is released under the MIT License. See `LICENSE` for details.
