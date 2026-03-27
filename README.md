### 🚀 Xray-Tunnel-Pro: 极致全能部署脚本

Xray-Tunnel-Pro 是一款专为 NAT VPS 及普通服务器设计的自动化部署脚本。它通过 Systemd 守护进程解决了隧道频繁掉线的痛点，并支持最新的 VLESS + xHTTP 协议，实现极致的隐蔽性与稳定性。
### ✨ 核心特性

   - 🛡️ 守护进程化：内置 cloudflared 与 Xray 双重 Systemd 守护，进程崩溃 5 秒内自动复活。

   - 📡 协议前沿：支持 VLESS + xHTTP (兼容 CDN) 以及 VLESS + WS 隧道模式。

   - 🌍 NAT 小鸡适配：针对共享 IP 环境优化了回环监听逻辑（127.0.0.1/0.0.0.0），支持 API 模式自动申请证书。

   - 🧼 极致纯净卸载：支持“一键白纸化”，彻底清理 Service 文件、环境变量及 acme.sh 残留。


### 🛠️ 快速部署

在你的 VPS (Root 权限) 上执行以下命令：

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


