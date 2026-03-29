### 🚀 Xray-mini: 极致轻量部署脚本

xray-Tunnel-Pro 是一款自动化部署脚本。它通过 Systemd 守护进程解决了隧道频繁掉线的痛点，并支持最新的 VLESS + xHTTP 协议，实现极致的隐蔽性与稳定性。
### ✨ 核心特性

- 🛡️ 守护进程化：内置 cloudflared 与 Xray 双重 Systemd 守护，进程崩溃 5 秒内自动复活。

- 📡 协议前沿：支持 VLESS + xHTTP (兼容 CDN) 以及 VLESS + WS 隧道模式。

- 🌍 NAT 小鸡适配：针对共享 IP 环境优化了回环监听逻辑（127.0.0.1/0.0.0.0），支持 `API 模式（无需端口）`自动申请证书。

- 🧼 极致纯净卸载：支持“一键白纸化”，彻底清理 Service 文件、环境变量及 acme.sh 残留。


### 🛠️ 快速部署

**在你的 VPS (Root 权限) 上执行以下命令：**

```
bash <(curl -Ls https://raw.githubusercontent.com/caojiaxia/xray-mini/main/xray_manager.sh)
```

### cloudflare tunnel创建
| 选项        | 说明                                                                      |
| ----------- | --------------------------------------------------------------------      |
| Type |   HTTP                                                                           |
| URL  | localhost:8080 

**详细步骤：**

<img width="1409" alt="image" src="https://user-images.githubusercontent.com/92626977/218253461-c079cddd-3f4c-4278-a109-95229f1eb299.png">

<img width="1619" alt="image" src="https://user-images.githubusercontent.com/92626977/218253838-aa73b63d-1e8a-430e-b601-0b88730d03b0.png">

<img width="1155" alt="image" src="https://user-images.githubusercontent.com/92626977/218253971-60f11bbf-9de9-4082-9e46-12cd2aad79a1.png">


### ⚠️ 注意事项

**NAT小机如果先部署CF Tunnel，当使用API申请证书时隧道会短暂中断**

**在NAT环境中由于内存很小，脚本运行时服务器可能会断开，若发生请在VPS终端执行以下命令：**

- 1 创建一个 512MB 的交换文件 (512，这在 1G 小机上很合理)
dd if=/dev/zero of=/swapfile bs=1M count=512

- 2 设置正确的权限（安全起见，只允许 root 读写）
chmod 600 /swapfile

- 3 将文件格式化为交换分区空间
mkswap /swapfile

- 4 立即激活 Swap
swapon /swapfile

- 5 验证是否成功
free -h

- 6 Swap 信息写入系统配置，实现永久挂载
echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab

- 7 如果你启用了脚本中的`8. 清理系统日志与垃圾`这个选项，请务必执行
grep -q "/swapfile" /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

- NAT 环境：使用`VLESS+XHTTP+TLS`启用`cloudflare CDN`时，由于端口受限（443系端口可能全被占用），可以使用任意端口，然后登陆 [Cloudflare](https://dash.cloudflare.com/login)部署端口回源。

- NAT 环境：若使用临时隧道（Option 2），脚本会自动抓取trycloudflare.com域名。

- API 模式：申请证书前请确保`Cloudflare API Key`, `Email`及`域名`已准备就绪。

- 系统要求：推荐使用 Debian 11/12 或 Ubuntu 20.04+。

**📁 目录结构**

- /usr/local/etc/xray/：核心配置文件存放地

- /usr/local/bin/：Xray 与 cloudflared 二进制程序

- /tmp/cloudflared.log：隧道运行实时日志

**🤝 贡献与反馈**

如果你在使用过程中发现 Bug 或有更好的功能建议，欢迎提交 Issue 或 Pull Request。

---

Star it if you like! ⭐

---

