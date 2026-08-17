# 闪狐云 Lite TUN 模式开发研究文档

> 本文档记录了在 NixOS 上为闪狐云 Lite(FlashFoxLite 3.0.6)实现 TUN 模式的全部尝试、
> 诊断数据、根因分析、失败方案与成功方案。保留所有原始信息,供未来再次开发 TUN 模式
> 时参考,避免从零开始。
>
> 时间:2026-08-04
> 环境:NixOS unstable(nixos-unstable),hostname mynixos,VMware 虚拟机 NAT 网络
> 桌面:niri(Wayland),网卡 ens33(192.168.80.131/24,网关 192.168.80.2)
> 用户:orion(uid 1000),sudo 可用(需密码)

---

## 1. 闪狐应用架构

### 1.1 应用构成

闪狐云 Lite 是一个 Flutter 写的闭源机场代理客户端,基于 mihomo(Clash.Meta)内核。
本质上和 FlClash 同源(FlClash 项目 fork)。两个进程:

- **GUI 进程**(FlashFoxLite,25KB):Flutter 应用,普通用户运行,负责界面/托盘/配置
- **Core 进程**(FlashFoxLiteCore,35MB,静态 Go ELF):mihomo 内核,GUI 通过 fork+exec 启动

GUI 和 Core 通过 **Unix socket** 通信:`/tmp/FlashFoxLiteSocket_XXXX.sock`(XXXX 随机)
Core 监听 **混合代理端口 127.0.0.1:7892**(HTTP/SOCKS5 合一),处理流量分流/代理。

### 1.2 用户数据目录

所有运行时数据在 `~/.local/share/ffclient.app/`:

```
~/.local/share/ffclient.app/
├── config.yaml              # mihomo 运行配置(57KB,二进制加密,非 base64)
├── profiles/
│   └── 999999.yaml          # 订阅 profile(47KB,同样加密)
├── shared_preferences.json   # Flutter GUI 偏好(明文 JSON,含 patchClashConfig)
├── database.sqlite           # 连接/流量记录
├── cache.db
├── ASN.mmdb                  # GeoIP 数据(10MB)
├── GEOIP.dat / GEOIP.metadb / GEOSITE.dat  # GeoIP/GeoSite 数据
├── FlashFoxLite.lock         # 单实例锁
└── (无 logs 目录,日志只进 journalctl)
```

**关键发现**:config.yaml 和 profiles/999999.yaml 都是**加密的二进制**(不是 base64 编码,
试过 `base64 -d` 解出来是乱码)。无法直接读取 mihomo 运行时配置。只有
shared_preferences.json 是明文,里面有一个 `patchClashConfig` 字段揭示了关键配置。

### 1.3 shared_preferences.json 关键字段

完整结构(JSON,主要字段):

```json
{
  "flutter.config": {
    "currentProfileId": 999999,
    "overrideDns": false,                // 是否覆盖 DNS(重启后从 false 变 false)
    "appSettingProps": {
      "locale": null,
      "dashboardWidgets": ["outboundMode","trafficUsage","systemProxyButton","tunButton","landingProxyButton"],
      "onlyStatisticsProxy": false,
      "autoLaunch": false, "silentLaunch": false, "autoRun": false,
      "openLogs": false, "closeConnections": true,
      "testUrl": "http://cp.cloudflare.com/generate_204",
      "autoCheckUpdate": false, "minimizeOnExit": true,
      "developerMode": false, "restoreStrategy": "compatible",
      "showTrayTitle": false
    },
    "networkProps": {
      "systemProxy": true,               // 开启时闪狐尝试 gsettings 设置系统代理
      "enableProxyGuard": false,
      "proxyGuardDuration": 30,
      "bypassDomain": [
        "*zhihu.com","*zhimg.com","*jd.com","100ime-iat-api.xfyun.cn",
        "*360buyimg.com","localhost","*.local","127.*","10.*",
        "172.16.*","172.17.*","172.18.*","172.19.*","172.2*","172.30.*","172.31.*","192.168.*"
      ],
      "routeMode": "config",             // 路由模式:跟随配置
      "autoSetSystemDns": true,           // 开 TUN 时自动改系统 DNS
      "appendSystemDns": true            // 追加系统 DNS(重启后从 false 变 true)
    },
    "vpnProps": {
      "enable": true,                     // TUN 开关(GUI 状态记录)
      "systemProxy": true,
      "ipv6": true,
      "allowBypass": true,
      "dnsHijacking": true,              // DNS 劫持开关
      "accessControlProps": {
        "enable": false,
        "mode": "rejectSelected",
        "acceptList": [], "rejectList": [],
        "sort": "none",
        "isFilterSystemApp": true,
        "isFilterNonInternetApp": true
      }
    },
    "patchClashConfig": {                // ← 明文!闪狐注入 mihomo 的配置
      "mixed-port": 7892,
      "socks-port": 0,
      "port": 0,
      "redir-port": 0,
      "tproxy-port": 0,
      "mode": "rule",                    // 规则模式(非全局/直连)
      "tun": {
        "enable": true,
        "auto-route": false,             // ← 关键!mihomo 不自动配路由
        "dns-hijack": ["any:53"]
      },
      "dns": {
        "enable": true,
        "listen": "0.0.0.0:1053",         // mihomo DNS 服务器监听端口(实际没监听!)
        "enhanced-mode": "fake-ip",
        "fake-ip-range": "198.18.0.1/16",
        "fake-ip-filter": ["*.lan", ...],
        "geosite:cn": "https://doh.pub/dns-query"
      },
      "nameserver": [
        "https://doh.pub/dns-query",
        "https://dns.alidns.com/dns-query"
      ],
      "proxy-server-nameserver": ["https://doh.pub/dns-query"]
    }
  }
}
```

**最重要的 5 个配置点**:
1. `tun.auto-route: false` — mihomo 不自动配路由,需要闪狐自己配(在 NixOS 上配不完整)
2. `tun.dns-hijack: ["any:53"]` — 劫持所有 53 端口流量
3. `dns.listen: "0.0.0.0:1053"` — 但 1053 实际从未监听(见诊断)
4. `dns.enhanced-mode: "fake-ip"` — fake-ip 模式
5. `dns.fake-ip-range: "198.18.0.1/16"` — fake-ip 段是 /16

---

## 2. deb 包结构(打包基础)

### 2.1 deb 内容

```
FlashFoxLite-3.0.6-linux-amd64.deb (51MB)
└── usr/share/
    ├── FlashFoxLite/
    │   ├── FlashFoxLite          # GUI 启动器(25KB 动态 ELF,找 lib/)
    │   ├── FlashFoxLiteCore      # mihomo 内核(35MB 静态 Go ELF)
    │   ├── lib/                  # Flutter 插件 .so
    │   │   ├── libapp.so
    │   │   ├── libdartjni.so              # ← 需要 libjvm.so(JDK)
    │   │   ├── libdynamic_color_plugin.so
    │   │   ├── libfile_selector_linux_plugin.so
    │   │   ├── libflutter_js_plugin.so
    │   │   ├── libflutter_linux_gtk.so     # ← 需要 libepoxy + fontconfig
    │   │   ├── libscreen_retriever_linux_plugin.so
    │   │   ├── libsqlite3_flutter_libs_plugin.so
    │   │   ├── libtray_manager_plugin.so  # ← 需要 ayatana-appindicator 三件套
    │   │   ├── liburl_launcher_linux_plugin.so
    │   │   └── libwindow_manager_plugin.so
    │   ├── data/                 # Flutter assets, icudtl.dat
    │   └── ...
    ├── applications/
    │   └── FlashFoxLite.desktop  # Name=闪狐云_Lite, Icon=FlashFoxLite, Exec=FlashFoxLite %U
    │                            # Categories=Network; Keywords=FlClash;Clash;ClashMeta;Proxy
    └── icons/hicolor/{128x128,256x256}/apps/FlashFoxLite.png
```

### 2.2 打包依赖分析(autoPatchelf 发现)

| .so 文件 | 隐藏依赖 | 解决方式 |
|---|---|---|
| libdartjni.so | libjvm.so | `addAutoPatchelfSearchPath ${jdk}/lib/openjdk/lib/server` |
| libtray_manager_plugin.so | libayatana-appindicator, libayatana-indicator, ayatana-ido, libdbusmenu | buildInputs 加这 4 个包 |
| libflutter_linux_gtk.so | libepoxy, fontconfig, gtk3 | buildInputs 加 |
| 其他 | gtk3, glib | buildInputs |

**运行时外部命令依赖**(wrapProgram 加到 PATH):
- `gsettings`(glib.bin)— 设置系统代理,缺失不会崩但代理失效
- `xdg-user-dir`(xdg-user-dirs)— path_provider 查询用户目录,**缺失会启动崩溃**
  ```Cannot cast Null to FutureOr<Directory>```
- `dpkg-deb`(dpkg)— nativeBuildInputs,构建时用

### 2.3 Flutter 引擎的特殊路径查找

FlashFoxLite(GUI 启动器)按 **`/proc/self/exe` 所在目录**相对查找 lib/、data/、icudtl.dat。
因此整个 bundle 必须放在一个目录(我们用 `$out/share/FlashFoxLite/`),bin 里只放符号链接:

```nix
ln -s $out/share/FlashFoxLite/FlashFoxLite $out/bin/flashfox-lite
```

desktop 文件 Exec 改成 `flashfox-lite`(通过 substituteInPlace)。

---

## 3. TUN 提权机制与 NixOS 约束

### 3.1 闪狐原生提权方式(Arch/Ubuntu 上)

闪狐开 TUN 或更新节点时,GUI(普通用户)执行:
```bash
sudo sh -c 'chown root:root <core路径> && chmod +sx <core路径>'
```
企图给 FlashFoxLiteCore 加 setuid 位,让它以 root 运行。
然后 GUI fork core,core 检测自己是 setuid root → euid=0 → 以 root 配置路由/iptables/resolv.conf。

journalctl 证据:
```
sudo[14096]: orion : PWD=/home/orion ; USER=root ;
  COMMAND=/run/current-system/sw/bin/sh -c 'chown root:root
  '/nix/store/0243v140vgyj4vymxq8mjf72l0rkdszd-flashfox-lite-3.0.6/share/FlashFoxLite/FlashFoxLiteCore'
  && chmod +sx '...FlashFoxLiteCore''
```

### 3.2 NixOS 的根本约束

- `/nix/store` 是 **只读**(ro)+ **nosuid** 挂载(btrfs subvol)
- `chmod +s` 在只读文件系统上 **必然失败**(EPERM)
- 即使 chmod 成功,nosuid 挂载也会让 setuid 位运行时**不生效**
- 所以闪狐的 setuid 提权方式**在 NixOS 上根本不可行**

### 3.3 方案 1(失败):ambient capabilities + 假 sudo 命令

**思路**:用 `security.wrappers` 给 core 文件设 file capabilities(cap_net_admin 等),
让 core 即使不是 root 也能创建 TUN 接口。同时用假 chown/chmod 欺骗 GUI。

**NixOS 配置**:
```nix
security.wrappers.flashfox-core = {
  owner = "root"; group = "root";
  capabilities = "cap_net_admin,cap_net_raw,cap_net_bind_service=+ep";
  source = "${pkgs.flashfox-lite}/share/FlashFoxLite/FlashFoxLiteCore.bin";
};
# package.nix 里把 core 改名 .bin,FlashFoxLiteCore 变成 symlink → /run/wrappers/bin/flashfox-core
# fake sudo tools 拦截 chown/chmod FlashFoxLiteCore 路径,返回 0
```

假 sudo 工具:
```nix
fake-tools = pkgs.symlinkJoin { ... };
security.sudo.extraConfig = ''
  Defaults secure_path = ${fake-tools}/bin:/run/current-system/sw/bin:...
'';
```

**结果**:TUN 接口创建成功(有 cap_net_admin),但:
- core 没有 root 权限 → 无法写 /etc/resolv.conf
- 无法添加 iptables REDIRECT 规则
- DNS 劫持靠 TUN 内处理(部分工作,返回 fake-ip)
- 但 `auto-route: false` 下路由没配完整 → **全断网(国内也断)**

**死循环现象**:core 出站 socket 源地址绑定 TUN 地址 198.18.0.1 → 命中闪狐自己的规则
`from 198.18.0.0/30 iif lo lookup 2022` → 又进 TUN → 无限循环。

### 3.4 方案 2(成功但 TUN 仍不可用):setuid root wrapper

**思路**:用 `security.wrappers` 让 core **真正以 root 运行**(setuid=true)。

```nix
security.wrappers.flashfox-core = {
  owner = "root"; group = "root";
  setuid = true;  # 注意:setuid 和 capabilities 互斥,不能同时设
  source = "${pkgs.flashfox-lite}/share/FlashFoxLite/FlashFoxLiteCore.bin";
};
```

package.nix:
```nix
mv $out/share/FlashFoxLite/FlashFoxLiteCore $out/share/FlashFoxLite/FlashFoxLiteCore.bin
ln -s /run/wrappers/bin/flashfox-core $out/share/FlashFoxLite/FlashFoxLiteCore
```

GUI 通过 /proc/self/exe 同目录 fork `FlashFoxLiteCore`(symlink)→ 实际 exec 到
`/run/wrappers/bin/flashfox-core`(setuid root)→ core 以 **euid=0** 运行。

**验证 core 是真 root**:
```
# ps
root  14106  FlashFoxLiteCore.bin /tmp/FlashFoxLiteSocket_7607.sock

# /proc/14106/status
Uid: 1000  0  0  0      # real=orion, effective=root, saved=root
Gid: 100  100  100  100
CapPrm: 000001ffffffffff
CapEff: 000001ffffffffff  # root 全 caps
NoNewPrivs: 0
```

ls -la /run/wrappers/bin/flashfox-core:
```
-r-s--x--x 1 root root 70712  ...  flashfox-core   # ← setuid 位 ✓
```

**结果**:core 真 root 运行,但 **TUN 仍然全断网**(见第 5-7 节)。问题转移到了路由/规则层面。

---

## 4. TUN 接口分析

### 4.1 接口名 bug(关键发现)

**实际接口名**(ip addr / hexdump 确认):
```
11: __________Lite: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 9000
    inet 198.18.0.1/30 brd 198.18.0.3 scope global __________Lite
```

hexdump 字节级:
```
5f 5f 5f 5f 5f 5f 5f 5f 5f 5f 4c 69 74 65   |__________Lite|
```
= **10 个下划线(0x5f) + "Lite"** = 14 字节 ASCII

**闪狐 ip rule 里引用的接口名**(ip rule):
```
9001: from all iif 闪狐云_Lite [detached] goto 9010
```
= 中文字符 **"闪狐云_Lite"** = 3 汉字(闪狐云,各 3 字节 UTF-8 = 9B) + "_Lite"(5B) = 14 字节

**根因**:mihomo 创建 TUN 接口时用名字"闪狐云_Lite"(中文 UTF-8),但内核 TUN 驱动把
**非 ASCII 字节逐字节替换为下划线** → 实际接口名变成 `__________Lite`(10 个下划线)。
而闪狐添加 ip rule 时仍用中文名"闪狐云_Lite" → 规则引用的接口名与实际接口名不匹配 →
**[detached](接口不存在)** → 该规则永久失效。

这条 `goto 9010` 规则的作用是让 TUN 出来的流量跳到 main 表(从 ens33 出去)。
它失效后 → TUN 出流量匹配 9002 `not from all iif lo lookup 2022` → 又进 TUN → **死循环**。

### 4.2 ip rule 完整内容(闪狐加的)

```
0:      from all lookup local
9000:   from all to 198.18.0.0/30 lookup 2022
9001:   not from all dport 53 lookup main suppress_prefixlength 0
9001:   from all iif 闪狐云_Lite [detached] goto 9010     ← 失效的规则!
9002:   not from all iif lo lookup 2022
9002:   from 0.0.0.0 iif lo lookup 2022
9002:   from 198.18.0.0/30 iif lo lookup 2022
9010:   from all nop
32766:  from all lookup main
32767:  from all lookup default
```

**规则分析**:
- `9000`: to 198.18.0.0/30 → 查表 2022(但只覆盖 /30,fake-ip /16 不在内!)
- `9001` 第一条: dport 53 → 查 main + suppress_prefixlength 0
  (suppress_prefixlength 0 = 如果 main 命中默认路由 prefixlen≤0 则忽略此规则,继续匹配)
- `9001` 第二条: iif 闪狐云_Lite → goto 9010(**detached,失效**)
- `9002` 第一条: iif≠lo → 查 2022(所有外部进来的流量进 TUN)
- `9002` 第二条: from 0.0.0.0 iif lo → 查 2022(未绑定源的本机 socket → TUN)
- `9002` 第三条: from 198.18.0.0/30 iif lo → 查 2022(TUN 地址源的流量 → TUN,**死循环元凶**)

### 4.3 路由表

**main 表**:
```
default via 192.168.80.2 dev ens33 proto dhcp src 192.168.80.131 metric 100
192.168.80.0/24 dev ens33 proto kernel scope link src 192.168.80.131 metric 100
198.18.0.0/30 dev __________Lite proto kernel scope link src 198.18.0.1
```
注意:只有 198.18.0.0/30(接口地址自动生成),**没有 198.18.0.0/16 → TUN 的路由**!

**table 2022**(mihomo 自建表):
```
default via 198.18.0.2 dev __________Lite
```
所有查 2022 的流量 → default → TUN。

### 4.4 IPv6

```
ip -6 rule:
0: from all lookup local
32766: from all lookup main
32767: from all lookup default

ip -6 route show table 2022:
Error: ipv6: FIB table does not exist.    ← IPv6 没有 TUN 路由表
```

---

## 5. 诊断数据全集

### 5.1 diag1 — TUN 开启后的基础状态(11:16)

```
=== ip addr ===
9: __________Lite: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 9000
   inet 198.18.0.1/30 brd 198.18.0.3 scope global __________Lite

=== ip route ===
default via 192.168.80.2 dev ens33 proto dhcp src 192.168.80.131 metric 100
192.168.80.0/24 dev ens33 proto kernel scope link src 192.168.80.131 metric 100
198.18.0.0/30 dev __________Lite proto kernel scope link src 198.18.0.1

=== ip rule ===
(见 4.2)

=== /etc/resolv.conf ===
# Generated by resolvconf
search localdomain
nameserver 192.168.80.2
options edns0
# 注意:resolv.conf 没被闪狐改!autoSetSystemDns 没生效?

=== 监听端口 53/1053/7892/9090 ===
udp  UNCONN 0  0  127.0.0.1:7892  0.0.0.0:*    # 代理端口在听
tcp  LISTEN 0  4096  127.0.0.1:7892  0.0.0.0:*
# 1053 没监听!9090 没监听(API 没开)

=== iptables nat ===
(nat 表全空,无任何 REDIRECT 规则)

=== ping 1.1.1.1 ===
100% packet loss

=== ping 110.242.68.66(百度真实 IP) ===
100% packet loss

=== getent hosts www.baidu.com ===
198.18.0.4  www.baidu.com     # ← fake-ip 生效!(diag1 时)

=== curl -x 127.0.0.1:7892 google ===
200    # 代理链路正常

=== curl 直连 baidu ===
000    # 全断
```

### 5.2 diag2 — core 身份确认(11:32)

```
=== ip route show table 2022 ===
default via 198.18.0.2 dev __________Lite

=== core 进程身份 ===
pid=14106
Uid:  1000  0  0  0           # euid=0,真 root!
Gid:  100  100  100  100
CapPrm: 000001ffffffffff
CapEff: 000001ffffffffff      # 全 caps
NoNewPrivs: 0

=== ls -la /run/wrappers/bin/flashfox-core ===
-r-s--x--x 1 root root 70712  flashfox-core   # setuid ✓

=== ip route get 198.18.0.4 ===
198.18.0.4 via 198.18.0.2 dev __________Lite table 2022 src 198.18.0.1 uid 0

=== ip route get 1.1.1.1 ===
1.1.1.1 via 198.18.0.2 dev __________Lite table 2022 src 198.18.0.1 uid 0

=== ping 198.18.0.4(fake-ip) ===
0% packet loss, 0.264ms   # core 本地响应 ICMP ✓

=== iptables nat(sudo) ===
Chain PREROUTING: 空
Chain INPUT: 空
Chain OUTPUT: 空
Chain POSTROUTING: 空      # 完全空,无 DNS REDIRECT 规则!
```

### 5.3 diag3 — 接口名字节级确认(11:42)

```
=== hexdump 接口名 ===
__________Lite => 5f 5f 5f 5f 5f 5f 5f 5f 5f 5f 4c 69 74 65
                  (10 个 0x5f + Lite = 14 字节 ASCII)

=== 计数(间隔 3 秒)===
ens33:        RX 44435478  TX 29457523
__________Lite: RX 259  TX 254
--- 3 秒后 ---
ens33:        RX 44543853(+108375)  TX 29535742(+78219)
__________Lite: RX 810(+551)  TX 800(+546)
# Lite 接口流量缓慢增长(死循环特征),ens33 也有流量(其他流量)
```

### 5.4 diag4 — 补救规则测试 1(11:52)

加规则:`ip rule add iif __________Lite lookup main pref 8900`

```
=== ip rule ===
8900: from all iif __________Lite lookup main    # 新增

=== 测网 ===
baidu 直连: 000
google 代理: 200    # ← 代理通!
google 直连: 000
ping 1.1.1.1: 100% loss
```

结论:8900 让 google 代理恢复 200,但直连仍断(因为 fake-ip 路由缺失)。

### 5.5 diag5 — 补 fake-ip /16 路由(12:00)

```bash
ip route add 198.18.0.0/16 dev __________Lite
```

```
=== ip route get 198.18.0.4 ===
198.18.0.4 dev __________Lite src 198.18.0.1 uid 0  # ← 现在走 TUN 了!

=== 测网 ===
baidu 直连: 000     # 还是断
taobao 直连: 000
google 代理: 200
google 直连: 000
ping 1.1.1.1: 100% loss
```

结论:fake-ip 路由补上了,但直连仍断。流量进 TUN 后 core 没转发(死循环)。

### 5.6 diag6 — 补 fwmark 规则(尝试,12:08)

```bash
ip rule add fwmark 0x2022 lookup main pref 2022
```

```
=== 测网 ===
baidu 直连: 000     # 无变化
taobao 直连: 000
=== 计数 ===
__________Lite: RX +1185  TX +1143  (curl 6秒)
ens33: TX +130  (几乎不动!)
```

结论:**ens33 TX 几乎不动 = core 没把流量转发出去**。fwmark 规则无效(core 不打 0x2022 标记)。
Lite 接口 RX/TX 各 +400 = 流量在 TUN 内循环。

### 5.7 diag7 — 补 8999 死循环拦截(成功,12:15)

```bash
ip rule add from 198.18.0.0/30 iif lo lookup main pref 8999
```

```
=== 计数(前) ===
ens33: TX 86080    __________Lite: TX 87641
=== 计数(后) ===
ens33: TX 86223(+143)    __________Lite: TX 87641(不变!)

=== 测网 ===
baidu 直连: 200    # ← 终于通!
taobao 直连: 200
google 代理: 200
google 直连: 000   # 直连仍断(没有域名信息无法分流)
```

**8999 规则的作用**:拦截 `from 198.18.0.0/30 iif lo`(core 出站,源 198.18.0.1)
→ 直接查 main → ens33 出去 → 不再死循环。

**但 google 直连 000**:因为 DNS 此时返回真实 IP(9001 规则让 DNS 走 main → 真实 DNS
→ 真实 IP → 进 TUN 无域名 → 兜底直连 → 被墙)。

### 5.8 diag8 — DNS 劫持恢复(8998 规则,测试)

```bash
ip rule add dport 53 lookup 2022 pref 8998
```

```
=== 向真实 DNS 192.168.80.2 发 DNS ===
www.google.com has address 198.18.0.4    # ← fake-ip 生效!

=== 系统解析 ===
www.google.com has address 198.18.0.4   # ← 系统 DNS 劫持恢复

=== 测网 ===
baidu 直连: 000    # DNS 恢复 fake-ip,反而直连全断!
taobao 直连: 000
google 代理: 200
```

**矛盾结论**:DNS 劫持恢复(返回 fake-ip),但 fake-ip 流量进 TUN 后 core **不转发**!
ens33 TX 几乎不动。这和 diag7 时(那时 DNS 返回真实 IP)不同——diag7 时 baidu 通是因为
真实 IP 流量进 TUN → core 按 IP 规则 DIRECT → ens33 → 通。

### 5.9 diag9 — fake-ip 入站死循环确认(终极诊断)

```
=== 计数(前) ===
ens33: TX 64249    __________Lite: TX 2167
=== curl baidu 3 秒(走 fake-ip 路径) ===
(超时 000)
=== 计数(后) ===
ens33: TX 64250(+1)    __________Lite: TX 2557(+390)
# ens33 纹丝不动,Lite +390 → fake-ip 包进 TUN 循环,core 没转发!

=== ping 198.18.0.4(ICMP) ===
0% packet loss, 0.448ms    # core 对 fake-ip 段 ICMP 有响应
# 但 TCP 不行!
```

### 5.10 DNS 劫持机制对比

```
向 198.18.0.2(TUN 网关)发 DNS:
www.google.com has address 198.18.0.4     # ← fake-ip ✓ mihomo DNS 引擎工作!

向真实 DNS 192.168.80.2 发 DNS(无 8998 规则时):
www.google.com has address 142.251.151.119  # ← 真实 IP,没被劫持

向真实 DNS 192.168.80.2 发 DNS(有 8998 规则时):
www.google.com has address 198.18.0.4     # ← fake-ip,被劫持了!

全新域名 test-qq12345.com 向 198.18.0.2:
has address 198.18.0.5                     # ← 不存在的域名也返回 fake-ip ✓
```

**DNS 劫持两种机制**:
1. TUN 内处理:发往 198.18.0.2(TUN 网关):53 的包 → mihomo 读 TUN → 处理 → 返回 fake-ip ✓
2. iptables REDIRECT(本机 53):**闪狐没有添加 iptables 规则** → 本机 DNS 默认走真实 DNS
3. 策略路由劫持(8998):`dport 53 lookup 2022` → DNS 包进 TUN → mihomo 处理 → fake-ip ✓

### 5.11 系统代理 gsettings 问题

```
$ gsettings get org.gnome.system.proxy mode
没有安装架构                    # ← schema 不存在!

# NixOS 默认不安装 org.gnome.system.proxy 的 GSettings schema
# 闪狐 set systemProxy 调用 gsettings → 静默失败 → 浏览器不走代理

# 装上 gsettings-desktop-schemas 后:
$ gsettings get org.gnome.system.proxy mode
'manual'                       # ← 生效!
```

### 5.12 nscd 缓存干扰

```
$ strace -f -e trace=network getent ahostsv4 www.google.com
connect(4, {sa_family=AF_UNIX, sun_path="/var/run/nscd/socket"}, 110) = 0
sendto(4, "\2\0\0\0\17\0\0\0www.google.com\0", 27, ...)
# getent 走 nscd(NSS 缓存守护),返回缓存结果,不走真实 DNS!
# NixOS 运行 nsncd 1.5.2(systemd-nscd 替代)
# 这会让 getent 结果不反映真实 DNS 行为,需要用 host/dig 直接发 DNS
```

---

## 6. 所有尝试的方案及结果汇总

### 6.1 方案对照表

| # | 方案 | 解决了什么 | 失败原因 |
|---|---|---|---|
| 1 | ambient caps + 假 sudo | 接口创建 | core 非 root,无法改 resolv/iptables,死循环 |
| 2 | setuid root wrapper | core 真 root,接口创建 | 路由/规则不完整,死循环 |
| 3 | 假 chown/chmod sudo | 欺骗 GUI 提权 | core 非 root(方案1)或已 root(方案2) |
| 4 | ip rule 8900(iif __________Lite → main) | TUN 出流量直查 main | 不够,还有死循环 |
| 5 | ip route 198.18.0.0/16 → TUN | fake-ip 段路由 | 不够,流量进 TUN 后死循环 |
| 6 | ip rule 8999(from 198.18/30 → main) | **拦截死循环!** 真实 IP 流量恢复 | 域名靠真实 DNS,国外域名无 fake-ip |
| 7 | ip rule fwmark 0x2022 → main | 无效 | **core 不打 fwmark 标记** |
| 8 | ip rule 8998(dport 53 → 2022) | DNS 劫持恢复,返回 fake-ip | fake-ip 入站流量 core 不转发(见 6.3) |
| 9 | systemd 轮询 daemon | 防闪狐 flush 规则 | 有效,但只维护规则,不解决 core 转发 |
| 10 | gsettings-desktop-schemas | 系统代理生效 | **成功!** 但不算 TUN(算系统代理方案) |

### 6.2 fake-ip 入站死循环(未解决的核心 bug)

**现象总结**:
1. DNS 劫持可以工作(TUN 网关 198.18.0.2 或 8998 规则)`→ 返回 fake-ip 198.18.x.x`
2. fake-ip 流量(198.18.0.x)进 TUN(有 /16 路由)
3. core 收到 fake-ip 包 → 应反查域名 → 规则分流 → 出站
4. **但 ens33 TX 不动 = core 没有出站 = core 没处理 fake-ip 包**

**Arch 上正常说明**:Arch 上闪狐能用 → fake-ip 入站能工作 → NixOS 环境差异导致降级。

### 6.3 Arch vs NixOS 差异(关键!)

| 项 | Arch(正常) | NixOS(异常) |
|---|---|---|
| core 提权 | 真 setuid(chmod +s 成功) | fake chmod 返回 0,**文件无 suid 位**(store ro) |
| mihomo DNS 监听 1053 | 应监听 | **没监听**(ss 无 1053) |
| iptables REDIRECT 规则 | 应有 | **空表**(sudo iptables -t nat -L 全空) |
| iptables 后端 | iptables-legacy 或 nft | iptables-nft(nf_tables 后端) |
| /proc/net/ip_tables_names | 有 | **不存在**(legacy 表未加载) |
| nscd | 通常无 | **nsncd 1.5.2 运行**(NSS 缓存,干扰 getent) |
| GSettings schema | 有 | **缺**(gsettings-desktop-schemas 没装) |
| /etc/resolv.conf 管理 | systemd-resolved? | resolvconf → 192.168.80.2 |

**推测闪狐降级机制**:
- 闪狐 `chmod +sx core` 后**可能 stat 检查 suid 位**
- Arch:suid 位存在 → 认为提权成功 → 完整 TUN 功能(DNS 监听 + iptables REDIRECT + fake-ip 入站)
- NixOS:suid 位不存在(store ro,chmod 失败被假) → 闪狐判定提权失败 → **降级运行**
  → 不启动 DNS 监听(1053)、不加 iptables、fake-ip 入站不转发
- 但 TUN 接口创建、策略路由、DNS 劫持(TUN 内)仍工作(因为 core 实际是 root via wrapper)

**这个推测无法验证**(闭源),但符合所有观察:
- 1053 不监听 = DNS 服务器没启动
- iptables 空 = DNS REDIRECT 规则没加
- fake-ip 入站不转发 = fake-ip 引擎降级
- 接口创建、策略路由 = 基础功能仍有

---

## 7. 闪狐 flush 规则问题与 systemd 轮询 daemon

### 7.1 现象

闪狐每次开 TUN 会:
1. 创建 TUN 接口(udev add 事件)
2. **flush 现有规则 + 重新添加自己的规则**
3. 设置路由

我们用 udev 在接口出现时补规则 → 步骤 2 的 flush 会清掉我们补的规则。
导致第一次 rebuild + 重启后 udev 方案失效(规则被闪狐 flush 清掉)。

### 7.2 解决:systemd 轮询 daemon

```nix
tun-fix = pkgs.writeShellScript "flashfox-tun-fix" ''
  while true; do
    if /run/current-system/sw/bin/ip link show __________Lite >/dev/null 2>&1; then
      /run/current-system/sw/bin/ip route add 198.18.0.0/16 dev __________Lite 2>/dev/null || true
      /run/current-system/sw/bin/ip rule add from 198.18.0.0/30 iif lo lookup main pref 8999 2>/dev/null || true
      /run/current-system/sw/bin/ip rule add iif __________Lite lookup main pref 8900 2>/dev/null || true
    fi
    sleep 1
  done
'';
systemd.services.flashfox-tun-fix = {
  wantedBy = [ "multi-user.target" ];
  serviceConfig = { ExecStart = tun-fix; Restart = "on-failure"; };
};
```

每秒幂等补三条规则(重复 add 失败被 `|| true` 忽略),闪狐 flush 后 <1 秒自动补回。

---

## 8. 系统代理方案(当前可行方案)

### 8.1 根因

NixOS 默认不安装 `org.gnome.system.proxy` 的 GSettings schema
(在 `gsettings-desktop-schemas` 包里)。闪狐 `systemProxy: true` 调用

```bash
gsettings set org.gnome.system.proxy mode 'manual'
gsettings set org.gnome.system.proxy.http host '127.0.0.1'
gsettings set org.gnome.system.proxy.http port 7892
```

→ 报"没有安装架构"静默失败 → Chrome 读不到系统代理 → 不走 7892。

### 8.2 修复

模块里加:
```nix
environment.systemPackages = [ pkgs.gsettings-desktop-schemas ];
```

装上 schema 后:
```
$ gsettings get org.gnome.system.proxy mode
'manual'                                        # ✓
```

闪狐开代理时设置系统代理 → Chrome 走 127.0.0.1:7892 → 翻墙。

### 8.3 验证

```
curl -x http://127.0.0.1:7892 https://www.google.com   → 200
curl -x http://127.0.0.1:7892 https://www.youtube.com  → 200
curl https://www.baidu.com                              → 200
```

系统代理方案下:
- 浏览器走 7892(域名交给 mihomo,可按域名分流)→ 全站翻墙
- 命令行工具可设 http_proxy/https_proxy 环境变量
- 不需要 TUN,不需要 root,不需要 setuid

---

## 9. 当前 TUN 模式的确切状态

### 9.1 什么能用

- ✅ TUN 接口创建(setuid wrapper 让 core 真 root)
- ✅ 代理端口 7892 工作(本地代理)
- ✅ 国内直连(真实 IP → TUN → mihomo DIRECT → ens33 → 通)
- ✅ 系统代理方案(gsettings schema 装)
- ✅ 路由/规则修复(8900/8999//16 + systemd daemon)

### 9.2 什么不能用

- ❌ **fake-ip 入站数据路径**:DNS 返回 fake-ip → 流量进 TUN → core 不转发 → 国外域名不通
- ❌ mihomo DNS 服务器(1053 没监听)
- ❌ iptables REDIRECT(闪狐没加规则)
- ❌ TUN 全局接管翻墙(浏览器走 TUN 时国外不通)

### 9.3 实际效果

TUN 开着时:
- 国内网站:真实 IP → TUN → DIRECT → 通 ✓
- 国外网站(浏览器直连):真实 IP → TUN → 兜底直连 → 被墙 ✗
- 国外网站(系统代理 7892):代理 → mihomo 按域名分流 → 通 ✓(不经过 TUN)

**结论**:TUN 对翻墙零贡献,翻墙实际靠系统代理 7892。TUN 开着只让国内流量绕一圈 TUN 直连。

---

## 10. 下次开发 TUN 的建议路径

### 10.1 验证 Arch vs NixOS 的环境差异

在 Arch 上跑闪狐 + TUN 正常时,抓取对比数据:
```bash
ip rule                          # 对比规则
ip route show table 2022         # 对比路由表
iptables -t nat -L -n -v        # 看 REDIRECT 规则
ss -tlnp | grep -E '1053|7892'   # 看 1053 是否监听
ls -l <core 路径>                 # 看 suid 位是否真的有
ls -l /proc/$(pgrep FlashFoxLiteCore)/fd | head  # core 打开的 fd
cat /proc/$(pgrep FlashFoxLiteCore)/status | grep -E 'Uid|Cap'
```

重点验证:
1. **1053 是否监听**(Arch 上应监听,NixOS 上不监听)
2. **iptables 规则**(Arch 上应有 REDIRECT 53→1053)
3. **core 文件 suid 位**(Arch 上应有 s 位,NixOS 上没有)

### 10.2 验证闪狐的 stat suid 检测假说

如果闪狐通过 stat 检查 core 文件 suid 位来判断提权成功,那么:
1. 在 NixOS 上检测 chmod +sx 后 stat 的 st_mode & S_ISUID 位是否设置
2. 如果 chmod 在 ro 文件系统上不设位 → 假 sudo 不够,需要让 stat 检测成功
3. 可能需要 **fake stat** 命令(类似 fake chown/chmod),拦截 FlashFoxLiteCore 路径的 stat
   调用,伪造 suid 位返回

### 10.3 替代提权方案

闪狐的 setuid 方式在 NixOS 不可行。替代:
1. **systemd service 以 root 跑 core**(像 clash-verge-service 那样)
   - 问题:core 由 GUI fork,需要 socket 通信,GUI 创建 socket 后传给 core
   - 可能让 core 作为 daemon 服务,GUI 通过 TCP/unix socket 连接(需要改造)
   - 闪狐闭源,无法改造

2. **让闪狐认为 setuid 成功**(stat 欺骗)
   - 假 sudo 里加 fake stat 命令,对 FlashFoxLiteCore 路径返回伪造的 suid 位
   - 然后 core 实际通过 setuid wrapper 以 root 运行
   - 闪狐判定提权成功 → 完整功能

3. **不用闪狐提权,系统层面接管 TUN 路由 + DNS**:
   - 用 networkd 或自定义脚本在 TUN 接口出现时配置完整路由 + DNS REDIRECT
   - 需要补齐:fake-ip /16 路由、iptables REDIRECT 53→1053(但 1053 没监听!)、
     出站死循环拦截
   - 问题:即使路由/规则完整,core 的 fake-ip 入站仍不转发(可能需要 core 完整功能)

### 10.4 最可能的突破方向

**验证 stat 检测假说后,加 fake stat 命令**:
- 在假 sudo 工具里加 stat 拦截,对 FlashFoxLiteCore 路径返回带 S_ISUID 位的 stat 结果
- 闪狐 GUI 检测到 suid 位 → 认为提权成功 → 启动完整 TUN 功能
- core 实际通过 setuid wrapper 以 root 运行
- 1053 监听 + iptables REDIRECT + fake-ip 入站转发 全部恢复

这是最有希望的路径,但需要:
1. 确认闪狐用的是 stat 还是别的方式检测(可能直接 geteuid()==0 也可能 stat 文件)
2. 如果是 stat,需要 fake stat(但 GUI 是 Flutter/Dart,可能通过 dart:io 的 File.stat)
3. 如果是 geteuid,core 实际 euid=0(wrapper),应该已经满足

### 10.5 另一个方向:patchClashConfig 改 auto-route: true

如果能让 `patchClashConfig.tun.auto-route = true`,mihomo 自己配完整路由(包括 fwmark 规则)
可能解决问题。但 patchClashConfig 在 shared_preferences.json 里,闪狐 GUI 可能会覆盖修改。

尝试:
1. 退出闪狐 → 改 shared_preferences.json 的 auto-route → 启动闪狐 → 开 TUN
2. 如果 GUI 不覆盖,mihomo 自己配路由 → 可能完整
3. 如果 GUI 覆盖,需要找 GUI 里的设置项或 hook

### 10.6 改用 clash-verge 的 TUN 机制

clash-verge 在 NixOS 上 TUN 正常(用 systemd root service)。如果闪狐不行,
直接用 clash-verge + 闪狐的订阅链接。但用户想用闪狐。

---

## 11. 完整的失败 NixOS 模块(TUN 模式,参考)

这是我们最终放弃的 TUN 模块完整内容(作为参考,不要启用):

```nix
# modules/nixos/programs/flashfox-lite.nix (TUN 版本,已废弃)
{
  lib, pkgs, ...
}:
let
  # 假 sudo 工具
  fake-tools = pkgs.symlinkJoin {
    name = "flashfox-fake-sudo-tools";
    paths = [
      (pkgs.writeShellScriptBin "chown" ''
        case "$*" in *FlashFoxLiteCore*) exit 0 ;; esac
        exec ${pkgs.coreutils}/bin/chown "$@"
      '')
      (pkgs.writeShellScriptBin "chmod" ''
        case "$*" in *FlashFoxLiteCore*) exit 0 ;; esac
        exec ${pkgs.coreutils}/bin/chmod "$@"
      '')
    ];
  };

  # 轮询补规则 daemon
  tun-fix = pkgs.writeShellScript "flashfox-tun-fix" ''
    while true; do
      if /run/current-system/sw/bin/ip link show __________Lite >/dev/null 2>&1; then
        /run/current-system/sw/bin/ip route add 198.18.0.0/16 dev __________Lite 2>/dev/null || true
        /run/current-system/sw/bin/ip rule add from 198.18.0.0/30 iif lo lookup main pref 8999 2>/dev/null || true
        /run/current-system/sw/bin/ip rule add iif __________Lite lookup main pref 8900 2>/dev/null || true
      fi
      sleep 1
    done
  '';
in {
  boot.kernelModules = [ "tun" ];

  security.sudo.extraConfig = ''
    Defaults secure_path = ${fake-tools}/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/usr/sbin
  '';

  security.wrappers.flashfox-core = {
    owner = "root"; group = "root";
    setuid = true;
    source = "${pkgs.flashfox-lite}/share/FlashFoxLite/FlashFoxLiteCore.bin";
  };

  systemd.services.flashfox-tun-fix = {
    description = "闪狐 TUN 缺失路由/规则自动补丁";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { ExecStart = tun-fix; Restart = "on-failure"; };
  };

  networking.firewall.checkReversePath = lib.mkDefault "loose";
}
```

对应的 package.nix 改动(TUN 版本):
```nix
installPhase = ''
  ...
  mv $out/share/FlashFoxLite/FlashFoxLiteCore $out/share/FlashFoxLite/FlashFoxLiteCore.bin
  ln -s /run/wrappers/bin/flashfox-core $out/share/FlashFoxLite/FlashFoxLiteCore
  ...
'';
```

---

## 12. 关键命令速查(下次诊断用)

```bash
# 查看 core 进程身份(确认是否 root)
grep -E '^(Uid|Gid|CapEff|CapPrm|NoNewPrivs)' /proc/$(pgrep -f FlashFoxLiteCore.bin)/status

# 完整路由规则
ip rule; ip route; ip route show table 2022; ip -6 rule; ip -6 route show table 2022

# 接口名字节级
hexdump -C <<< "$(ls /sys/class/net/ | grep Lite)"

# 端口监听
ss -tulnp | grep -E '53|1053|7892|9090'

# iptables(nf_tables 后端)
sudo iptables -t nat -L -n -v
sudo iptables -t mangle -L -n -v

# 死循环证据(看 ens33 TX 是否增长,TUN RX/TX 是否暴涨)
grep -E 'ens33|Lite' /proc/net/dev; sleep 3; grep -E 'ens33|Lite' /proc/net/dev

# DNS 劫持测试
host -t A www.google.com 198.18.0.2    # TUN 网关(应返回 fake-ip)
host -t A www.google.com 192.168.80.2  # 系统 DNS(看是否被劫持)
getent ahostsv4 www.google.com          # 系统 NSS(注意 nscd 缓存!)

# 系统代理
gsettings get org.gnome.system.proxy mode   # 应 'manual'
nix shell nixpkgs#gsettings-desktop-schemas nixpkgs#glib -c gsettings get org.gnome.system.proxy mode

# nscd 干扰确认
ps aux | grep nscd | grep -v grep

# 闪狐 sudo 提权命令(journalctl)
journalctl -t sudo --since "30 min ago" | grep FlashFoxLiteCore

# 配置文件
cat ~/.local/share/ffclient.app/shared_preferences.json | tr ',' '\n' | grep -E 'dns|tun|fake|auto-route'
ls -la ~/.local/share/ffclient.app/config.yaml  # 加密,看不了内容只能看时间戳

# 临时手动补规则(测试用)
sudo ip rule add iif __________Lite lookup main pref 8900
sudo ip rule add from 198.18.0.0/30 iif lo lookup main pref 8999
sudo ip route add 198.18.0.0/16 dev __________Lite
sudo ip rule add dport 53 lookup 2022 pref 8998       # DNS 劫持(会让 fake-ip 生效但转发坏)
sudo ip rule add fwmark 0x2022 lookup main pref 2022  # 无效(core 不打标)
```

---

## 13. 闪狐 vs clash-verge 架构对比

| 项 | clash-verge | 闪狐 |
|---|---|---|
| 提权 | systemd root service(clash-verge-service) | setuid core(chmod +s) |
| NixOS 可行性 | ✅ systemd service 天然支持 | ❌ store nosuid 不可行 |
| TUN auto-route | mihomo 自己配(完整) | auto-route:false,自配不完整 |
| fake-ip 入站 | 正常 | **不转发**(NixOS 降级) |
| DNS 劫持 | iptables REDIRECT | TUN 内处理(部分) |
| fwmark 出站绕过 | mihomo 打标 + fwmark 规则 | **不打标** |

clash-verge 在 NixOS 上 TUN 正常,因为:
1. mihomo 以 root systemd service 运行(完整权限)
2. mihomo 自己配 auto-route(完整路由 + fwmark 规则)
3. 不依赖 setuid 文件位

---

## 14. 总结

### 14.1 已解决

1. **打包**:deb → NixOS 包(autoPatchelfHook + wrapProgram)
2. **运行时依赖**:glib.bin(gsettings)、xdg-user-dirs
3. **系统代理**:gsettings-desktop-schemas(Chrome 走 7892)
4. **TUN 接口创建**:setuid wrapper 让 core 真 root
5. **TUN 死循环**:8999 拦截 + 8900 出流量直查 + /16 路由
6. **闪狐 flush**:systemd 轮询 daemon

### 14.2 未解决

1. **fake-ip 入站数据路径**:core 收到 fake-ip 包不转发(1053 不监听 + iptables 空)
2. **闪狐降级机制**:可能 stat 检查 suid 位失败导致降级(推测,闭源无法确认)
3. **mihomo DNS 服务器**:配置 listen 0.0.0.0:1053 但没监听
4. **iptables REDIRECT**:闪狐没添加 DNS 劫持的 iptables 规则

### 14.3 当前可用方案

**系统代理**(非 TUN):
- 装 gsettings-desktop-schemas
- 闪狐开"系统代理"(GUI 默认开)
- 浏览器走 127.0.0.1:7892 → 全站翻墙
- 已封装在 flashfox-lite-flake 的 nixosModules.default

### 14.4 TUN 下次尝试的最优先路径

1. **在 Arch 上抓对比数据**(1053/iptables/suid 位)确认降级机制
2. **尝试 fake stat 命令**(假 sudo 工具加 stat 拦截,伪造 suid 位)
3. 如果 stat 假说成立 → core 完整功能 → TUN 全接管
4. 如果 stat 假说不成立 → 考虑 systemd service 跑 core 或 patchClashConfig auto-route:true

---

## 附录 A:闪狐已知行为时间线

```
11:16 diag1: TUN 第一次开, fake-ip 生效(getent→198.18.0.4), 全断(路由缺失)
11:32 diag2: core 真 root(Uid 1000/0/0/0), 1053 不监听, iptables 空
11:42 diag3: 接口名 10 个下划线(hexdump 确认), ip rule 中文名 detached
11:52 diag4: 加 8900 规则, google 代理 200(代理链路正常), 直连仍断
12:00 diag5: 加 /16 路由, fake-ip 能进 TUN, 但 baidu 仍 000
12:08 diag6: 加 fwmark 0x2022, 无效, ens33 TX 不动(core 不转发)
12:15 diag7: 加 8999 拦截死循环, baidu/taobao 200, google 代理 200, google 直连 000
12:30+:     重启系统后 fake-ip 失效(getent 返回真实 IP), DNS 劫持消失
12:50+ diag8: 加 8998 恢复 DNS 劫持, fake-ip 生效, 但 baidu 又 000(core 不转发)
13:00+ diag9: 确认 fake-ip 入站死循环(ens33 TX 不动, Lite RX/TX 增长)
13:10+      : 发现 gsettings schema 缺失, 装上后系统代理可用
13:30+      : 决定放弃 TUN, 用系统代理方案, 迁移到独立 flake
```

## 附录 B:文件路径索引

```
~/mynixos/pkgs/flashfox-lite/package.nix          # 打包(已迁移到独立 flake)
~/mynixos/pkgs/flashfox-lite/FlashFoxLite-...deb  # vendor deb(已迁移)
~/mynixos/modules/nixos/programs/flashfox-lite.nix# TUN 模块(已废弃,可删)
~/mynixos/modules/hm/programs/packages.nix        # home.packages
~/mynixos/flake.nix                               # inputs + modules

~/flashfox-lite-flake/                            # 独立 flake 仓库(最终版)
├── flake.nix
├── package.nix
├── vendor/FlashFoxLite-...deb
├── README.md
└── TUN-RESEARCH.md                                # 本文档

~/.local/share/ffclient.app/                      # 闪狐运行时数据
├── config.yaml              # 加密
├── profiles/999999.yaml     # 订阅(加密)
└── shared_preferences.json  # 明文配置

/tmp/opencode/tun-diag*.txt                        # 诊断脚本输出(临时)
/tmp/opencode/tun-diag*.sh                        # 诊断脚本(临时)
```

---

**前文结束。TUN 已于 2026-08-18 彻底解决,最终根因与方案见第 15 节(以第 15 节为准)。**
---

## 15. 最终解决方案(2026-08-18,TUN 全功能验证通过)

> 本节是对上文各假设的最终裁决与修正。阅读前文时请以本节为准。

### 15.1 三个真凶(及对前文的修正)

1. **接口名 bug 的凶手是闪狐自己,不是内核**
   前文 §4.1 认为"内核 TUN 驱动把非 ASCII 字节替换为下划线"。实测证明错误:
   在 6.18 内核上直接 TUNSETIFF 请求 `闪狐云_Lite`,内核原样创建中文名
   (tuntest.py)。替换发生在闪狐创建 TUN 设备的那一侧(它对设备名做了 ASCII 化,
   但加 ip rule 时又用原始中文名)→ `iif 闪狐云_Lite [detached]` → 出站防环
   规则失效 → 全断网。**修复:把 patchClashConfig.tun.device 改为 "Meta"**
   (ASCII,两侧一致,规则正常挂载)。本文档 §7 的 systemd 轮询 daemon、§12 的
   8900/8999 手补规则全部不再需要。

2. **"fake-ip 入站不转发 / 降级运行" 假说不成立,真凶是 NixOS 防火墙**
   前文 §6.2/6.3 推测闪狐因 stat 检测 suid 位失败而"降级运行"。抓包 + sing-tun
   v0.4.17 源码确认:TCP 进入 TUN 后,mihomo 的 tun2socks 桥接把 SYN 改写成发往
   **本机 198.18.0.1:<随机端口>**(它自己的 TCP forwarder 监听)并从 TUN 接口送回
   本机;NixOS 防火墙默认丢弃非信任接口的入站包 → 握手永远失败 → 所有 TCP 全断
   (Arch 无防火墙所以闪狐原生可用)。**修复:`networking.firewall.trustedInterfaces = [ "Meta" ]`**。
   1053 不监听、iptables 空表同样是防火墙/监听方向的观察假象,非降级。

3. **每次开 TUN 弹密码框:闪狐对 corePath 做 lstat 检查**
   前文 §10.2/10.4 的 stat 检测假说方向正确。实测(execve trace)闪狐不执行 stat
   命令,检查在进程内完成,且对符号链接本身做 lstat → 链接永远过不了
   (uid=用户、无 suid 位)。普通发行版 chmod +sx 后 core 是 root:root+rws 的真实
   文件 → 检查通过 → 永不再弹框。NixOS 上需要让 corePath 呈现同样的形态,
   但存在三重限制:Nix 构建沙箱不能 chown(报 EINVAL)、不能设 suid 位(报 EPERM),
   store 又是 nosuid 挂载。**修复(三层)**:
   - core 原路径放 0755 跳板脚本(真实文件,挂载点 + 兜底);
   - `flashfox-core-mount.service` 把 `/run/wrappers/bin/flashfox-core`
     (root:root+suid 的真 wrapper)`mount --bind` 到 corePath → lstat/stat 直接
     看到 wrapper 本体 → 检查通过 → **完全不弹密码框**;
   - 包内给 GUI 注入假 sudo:吞掉针对 FlashFoxLiteCore 的 chown/chmod 命令
     (只读 store 上必然失败且是 no-op),其余 sudo 原样放行。
   注意:当前 nixpkgs 中 wrapper 由 `suid-sgid-wrappers.service` 创建(不再是
   名为 wrappers 的 activationScript),挂载服务需排在其后。

### 15.2 最终 NixOS 模块结构(flake.nix 的 nixosModules.default + enableTun)

```
enableTun = true 时:
  package                        = callPackage ./package.nix { tunSupport = true; }
                                  # 包内:core → .bin + 跳板脚本 + 假 sudo;
                                  # GUI 每次启动前自动把 tun.device 幂等改为 "Meta"
  boot.kernelModules             = [ "tun" ]
  security.wrappers.flashfox-core = setuid root;source = ...Core.bin;
                                   permissions = "u+rwx,g+x,o+x"  # stat 输出含 rws
  systemd.services.flashfox-core-mount  # bind-mount wrapper → corePath(免密码框)
  networking.firewall.trustedInterfaces = [ "Meta" ]   # tun2socks 桥接不被丢弃
  networking.firewall.checkReversePath  = "loose"      # 防非对称回包被 rp_filter 丢

零手动步骤:rebuild 后首次启动闪狐即自动完成 device=Meta 修正,
与 clash-verge 的 serviceMode/tunMode 一样开箱即用。
```

### 15.3 验证结果(2026-08-18)

- 开 TUN 不再弹任何密码框;反复开关正常
- TUN 下国内直连(baidu 200)、国外走节点(google 200)全部正常
- fake-ip DNS 劫持正常(google.com 解析为 198.18.0.x)
- 系统代理模式与 TUN 模式互不干扰,均可独立使用
- 对比参照:clash-verge 在本机同环境用 systemd root service(service mode)实现,
  闪狐闭源无法改造 GUI 的 fork 协议,故本方案用 wrapper + bind-mount 达成等价效果

### 15.4 遗留观察(不影响使用,记录备查)

- 开 TUN 时 mihomo 的 dns.listen(1053)不监听、无 iptables REDIRECT:
  经抓包确认其 DNS 劫持走 TUN 内 `dns-hijack: any:53` 路径,工作正常,
  1053/iptables 并非必需。
- TUN 接口计数器方向:AF_PACKET 在 tun 设备上只能看到 mihomo 写回主机的方向,
  判断"SYN 是否进 TUN"需看 /proc/net/dev 的 TX 增量。

---

