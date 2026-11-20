# iOS on iPadOS：全硬件模拟攻击计划 v0.1

日期：2026-11-20  
目标设备：iPad10（iPad13,19 / J272AP / A14 / t8101*），iPadOS 27.0 beta 2，未越狱，分发证书侧载  
宿主形态：iPad App 进程内引擎（复用 RyBox/LiveContainer 模型），JIT 已实测可用

> `*` 实际 soc name 以 IPSW 内 `DeviceTree`/`arm-io compatible` 为准，不要凭记忆写死。



---

## 0. 结论先行：原来的"真空"其实不用填

之前把 ②「XNU 用户态化」列为真空，是把问题定义错了。三个一手证据说明**不该改 XNU**：

| 证据        | 硬结论                                                                                                                          |
| --------- | ---------------------------------------------------------------------------------------------------------------------------- |
| darwin-vm | 直接把真 kernelcache + 改过的 ADT + ramdisk + trustcache 喂给 `-M darwin`，跳过 iBoot，**A14/t8101 + iOS 27 已进 root shell**。没有移植 XNU 到用户态 |
| Henge     | 在 iOS App 里用 **arm64→arm64 JIT + 软件 MMU** 代替 EL2，整套 `core/` 开源，guest 是完整 macOS。引擎与 guest OS 无关                               |
| UniXNU    | 在非 Apple ARM64 上跑完整 iOS 桌面，**AMFI 与 AppleImage4 一行没改**：自己签 trust cache、自己指定 chip ID、自己写设备树身份，再让苹果的代码验一遍真的                    |

⇒ 正确路线：**不改 XNU、不拆签名，在用户态模拟一套够用的硬件 + 伪造一份设备树，让真 kernelcache 自己启动**。  
这正是用户说的"一点点模拟一个完整硬件"，而且已有三条开源路径证明可行。

---

## 1. 总体架构

```
iPad App（沙盒内）
├─ SwiftUI 外壳 / JIT 授权（复用 RyBox）
├─ engine/       ← Henge core/ 原样移植：translate / mmu / exception / dispatch / sysreg
├─ machine/      ← 我们写：最小 Apple 机器模型（MMIO 设备 + 中断注入）
├─ adt/          ← darwin-vm dt_fixup.py 移植 + UniXNU ADT 编码器
└─ assets/       ← PC 上从 IPSW 预生成：bootkc / dtree / trustcache / ramdisk.dmg
       ↑
   PC/Mac 静态准备（只做一次，运行态完全不依赖电脑）
```

**关键适配点**：iOS 宿主和 iOS guest 都是 16 KiB 页，Henge 的 "guest RAM 直接映射宿主页" 优化天然成立；  
UniXNU 最头疼的 16KiB→4KiB 内核补丁我们完全不需要。

---

## 2. 阶段 0 最小硬件集（目标：串口有输出 → root shell）

| 部件              | 来源                                                                                                 | 说明                                                                                                                       |
| --------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| CPU + MMU + 异常  | Henge `core/translate.c`(98KB)、`mmu.c`(65KB)、`exception.c`、`sysreg.c`、`dispatch.c`                 | OS 无关，直接搬                                                                                                                |
| 中断控制器           | Henge `devices/gicv3.c` 或 qemu-sptm 的 AIC                                                          | ⚠️ 二手文章说 darwin-vm 把 AIC 换成 GIC，**但源码相反**：`SUPPORTED_DRIVERS` 保留 `aic`，并给 `aic,2/aic,3` 加 `aic-iack-offset=0x1000`。以源码为准 |
| timer / RTC     | Henge `devices/timer.c`、`pl031.c`                                                                  | 设备树里用 `no-rtc` + 占位 rtc 节点可跳过 30 秒等待                                                                                     |
| UART            | Henge `devices/pl011.c`                                                                            | darwin-vm 的 `copy_uart()` 技巧：在 uart0 后追加 4 个 tunnel UART，宿主接 Unix socket，guest 用 socat 做 TCP 隧道                          |
| arm-io 总线 + ADT | darwin-vm `dt_fixup.py`                                                                            | 见下节                                                                                                                      |
| NVRAM proxy     | `chosen/nvram-proxy-data`                                                                          | CHRP bank 格式；darwin-vm 自带 `nvram.bin`                                                                                    |
| 安全启动            | `InvalidateHmac.config=1` + `sio-hmac1-disable-mask=全1` + `defaults/vmm-present=1` + 外部 trustcache | **CLI 阶段不需要 SEP**；SEP/keychain 留到 GUI                                                                                    |
| 根文件系统           | ramdisk.dmg（darwin-vm 已 patch 成直接进 shell）                                                          | 后续再换 virtio-blk                                                                                                          |
| GPU / WiFi / 蓝牙 | 不做                                                                                                 | 阶段 0 明确不模拟                                                                                                               |

### dt_fixup.py 的"四两拨千斤"清单（源码已拉到本地 ref/）

1. `del_compat()`：递归删掉所有节点的 `compatible`，白名单只有 `AppleARM`、`aic`、`arm-io`、`uart-1,samsung`  
   → IOKit 驱动匹配不到就不绑定，内核不再等不存在的硬件。
2. `fixup_sptm()`：把 `chosen/memory-map` 里 TXM/SPTM/BootKC/TrustCache/RAMDisk 等十几个区域全写成  
   `(0xffffffffffffffff, 0xffffffffffffffff)`（iBoot 的"未初始化"约定），`slide=0`，删 `arm-io/sgx` 跳过 IOMMU。
3. 身份伪装：`firmware-version = "qemu-sptm"`、`cpu0.state = "running"`、`random-seed` 填 'A'、  
   `kernel-ctrr-to-be-enabled = 0`、NVRAM 属性四件套、`defaults/serial-device` 指向 uart0 phandle。
4. 内存布局：按 `soc-generation` 决定 `dram-base`（H14 以前 `0x800000000`，之后 `0x10000000000`），  
   `dram-size = 0x200000000`。**A14 的 soc-generation 实测值必须先从真机 DeviceTree 读出来**，别套用。
5. 各种 panic 绕坑：`vmm-present=1`（AMFI "No PMGR?"）、`no-rtrc` 占位节点、`secure-root-prefix` 删除、  
   AMCC lock-regs 全套伪造、`dockchannel-uart` 删除。
6. ADT 格式（UniXNU 文档确认）：`u32 n_props, u32 n_children`；每个属性 `char name[32] + u32 len + value(4 字节对齐)`；  
   全小端；每个节点自带 `name` 属性。darwin-vm 的 Python 编解码器可直接复用。

---

## 3. 阶段路线与判定标准

借用 UniXNU 的纪律：**一次只动一个变量、先量再改、不注册假服务、固件侧与内核侧分开记账**。

| 阶段 | 内容                                                                         | 判定标准（必须通过才进下一阶段）                                                   | 状态  |
| -- | -------------------------------------------------------------------------- | ------------------------------------------------------------------ | --- |
| P0 | PC 侧备齐 A14/iOS 27b2 资产：kernelcache、DeviceTree、ramdisk、trustcache、nvram.bin | 四个文件都从 ipsz 解出且哈希固定；ADT 能被我们的编解码器 round-trip                       | 未开始 |
| P1 | iPad App 里跑起 Henge 引擎：JIT 区域、16KB 页、简单 MMIO 设备读写自测                         | 翻译块能执行 guest 指令，TLB hit/miss 计数正确，MMIO 读写触发预期回调                    | 未开始 |
| P2 | 喂 kernelcache + 伪 ADT，追到第一条串口输出                                            | 内核打印版本与 boot-args；无 `No PMGR?` / provider panic                    | 未开始 |
| P3 | 平台专家匹配 + 内存/中断初始化通过                                                        | ADT 根节点匹配；`/cpus` `/arm-io` `/defaults` `/options` + NVRAM proxy 齐 | 未开始 |
| P4 | 挂 ramdisk，起 launchd，进 root shell                                           | `bash-3.2# whoami` → root（darwin-vm 已证明可达）                         | 未开始 |
| P5 | 显示：先接 framebuffer / IOMobileFramebuffer，再谈 PVG                             | 帧缓冲尺寸/stride 正确，屏幕有画面（UniXNU 阶段 1 判定）                              | 未开始 |
| P6 | 触控 HID：模拟 IOHID 触摸设备                                                       | iOS 识别为触摸屏，产出 IOHID 事件                                             | 未开始 |
| P7 | 存储持久化 + PVG/Metal 完整 GUI                                                   | 不再依赖 ramdisk；SpringBoard 桌面可见                                      | 未开始 |

**P5 之前的两个硬坑（已知，提前记账）**：

- iOS guest 的 Metal 用户态插件在 PCC 固件里（`AppleParavirtGPUMetalIOGPUFamily.bundle` +  
  `libAppleParavirtCompilerPluginIOGPUFamily.dylib`），量产 iPhone IPSW 没有。
- iOS 27 把 `IOMobileFramebufferSwap*` 从 `_kern_Swap*` 切到 `_virt_Swap*`，帧不进内核 userclient → 黑屏；  
  需要按 IOConnect port（连接对象 +0x14）分发的补丁。

---

## 4. 现成轮子与本地参考

| 轮子                 | 用途                                                                                 | 本地文件 / 链接                                                                                  |
| ------------------ | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| darwin-vm          | 资产准备 + ADT 骗内核 + root shell 基线                                                     | `ref/darwinvm_*.sh`、`ref/darwinvm_dt_fixup.py`；<https://github.com/jprx/darwin-vm>         |
| Henge              | JIT 引擎 + MMU + 设备模型 + Metal 重放                                                     | `ref/henge_architecture.md`、`ref/henge_vmapple.c`；<https://github.com/Leviidev/Henge>      |
| UniXNU             | ADT 必需节点、bring-up 顺序、GPU/显示施工法                                                     | <https://unixnu.com/zh/porting/device-tree> 、/bring-up ；<https://github.com/UniXNU/UniXNU> |
| UniXNU-nio ROADMAP | 逐阶段施工与诚实判定范例                                                                       | 已抓取要点，见本文件第 3 节                                                                            |
| vphone-cli         | iOS 27 显示补丁、PVG 插件来源                                                               | <https://github.com/Lakr233/vphone-cli>                                                    |
| QEMU vmapple       | 设备内存映射参考（GIC 0x10000000 / UART 0x20010000 / BDIF 0x30000000 / APV GFX 0x30200000…） | <https://github.com/qemu/qemu/tree/master/hw/vmapple>                                      |

---

## 5. 第一刀具体做什么（P0 + P1 并行）

1. **读真机 DeviceTree**：从 27b2 IPSW 取 `DeviceTree.J272AP`（或对应板名），解析 `arm-io.compatible` /  
   `soc-generation` / `chosen.dram-*` / `aic` 节点，确认 A14 走哪条内存布局分支。
2. **把 `dt_fixup.py` 变成可测的 C/Python 工具**：先在 PC 上用它处理真 ADT，写 round-trip + 字段断言测试  
   （复用 RyBox 的 `tools/build_verify_test.sh` freestanding C 台思路：进程退出码 = bitmask 断言）。
3. **建最小资产包**：kernelcache / dtree / trustcache / ramdisk / nvram 五件套，固定 SHA-256，随 App 侧载。
4. **Henge 引擎最小化**：只取 `core/` + `devices/{gicv3,pl011,timer,pl031}.c` + `host/jit_region.c`，  
   先在 iPad App 里跑指令自测，不接 XNU。
5. **全程离线优先**：设备桥不可达时继续做静态分析，不阻塞。

---

## 6. 风险与红线

- Henge / darwin-vm 均为 GPL-2.0：仅用于本机研究，不做商业分发。
- Henge 目前只在 iPhone 17 Pro 实机验证；iPad 支持是新的，A14 内存（iPad10 4GB）可能不够 4–8GB guest RAM，  
  阶段 0 目标小内存 root shell 更现实。
- 不走 App Store：JIT 需要调试器附加，GPL 也不兼容。
- 真机投放逐次确认；不碰宿主系统分区，所有资产只在 App 沙盒内。
- 不注册假的 WiFi/BT/显示服务，做不到就如实标"未达成"。
