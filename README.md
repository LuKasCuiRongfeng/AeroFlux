# AeroFlux

AeroFlux 是一个面向自建 VPS 的首发项目，目标很单纯：

- 用最强的主流技术组合做出高性能自建节点
- 安装后直接生成 v2rayN 可导入链接
- 在没有域名的前提下也能稳定落地

当前技术栈：

- sing-box 作为核心运行时
- VLESS REALITY 作为稳定主线
- Hysteria 2 作为高速主线
- systemd 负责服务托管
- BBR 与 UDP buffer tuning 负责链路调优

## 设计目标

- 极简部署
- 极致速度
- 低维护成本
- 面向 v2rayN 的直接使用体验

## 当前能力

安装完成后自动生成两条链接：

1. VLESS REALITY
2. Hysteria 2

推荐用法：

- 日常使用优先 REALITY
- 大流量、测速、流媒体优先 Hysteria 2
- 在 v2rayN 中同时保留两条线路，按实时表现切换

## 无域名方案

AeroFlux 默认按无域名场景工作：

- REALITY 直接使用外部握手站点，不要求你持有域名
- Hysteria 2 默认使用自签证书
- Hysteria 2 分享链接自动带 `insecure=1`

这套组合的意义是：

- REALITY 保证可用性与兼容性
- Hysteria 2 负责把 UDP 和 QUIC 的速度优势吃满

## 安装

在 VPS 上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LuKasCuiRongfeng/AeroFlux/main/install.sh)
```

如果你想先看代码再安装，也可以手动克隆后执行：

```bash
git clone https://github.com/LuKasCuiRongfeng/AeroFlux.git
cd AeroFlux
chmod +x install.sh
sudo ./install.sh
```

安装过程会询问：

- REALITY 握手站点，默认 `www.cloudflare.com`
- REALITY TCP 端口，默认优先 `443`
- Hysteria 2 UDP 端口，默认优先 `443`
- Hysteria 2 上下行带宽上限，默认 `1000/1000 Mbps`
- 是否应用 BBR 与 UDP 调优

## 文件布局

安装完成后会生成：

- `/etc/aeroflux/config.json`
- `/etc/aeroflux/install.env`
- `/etc/aeroflux/share-links.txt`
- `/etc/aeroflux/cert.pem`
- `/etc/aeroflux/key.pem`

## 管理命令

```bash
sudo ./install.sh
sudo ./install.sh install
sudo ./install.sh show-links
sudo ./install.sh update
sudo ./install.sh status
sudo ./install.sh uninstall
```

如果通过仓库脚本安装，会额外生成快捷命令：

```bash
afx
```

## v2rayN 使用

安装完成后，脚本会直接打印两条链接，并保存到：

```bash
/etc/aeroflux/share-links.txt
```

在 v2rayN 里：

1. 复制链接
2. 从剪贴板导入
3. 分别测速
4. 保留两条线路，按实时表现切换

## 性能建议

协议只是上限的一部分，真实速度还取决于机房、线路、运营商 QoS 和系统参数。

建议：

- 优先 Ubuntu 22.04 或 24.04
- 放行 REALITY 的 TCP 端口与 Hysteria 2 的 UDP 端口
- 保持系统尽量干净，不混跑无关服务
- 优先选择跨境链路表现更好的机房
- 安装时开启 BBR 与 UDP 调优

## 路线

AeroFlux 后续只围绕四件事演进：

- 更新 sing-box 内核
- 优化 REALITY 与 Hysteria 2 的默认配置
- 提升 v2rayN 导入体验
- 持续打磨 VPS 侧调优与运维体验
