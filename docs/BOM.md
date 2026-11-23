# 采购清单

价格是作者购买时（2026 年 11 月）的参考，请以实际购买时为准。

## 必需硬件

| 部件 | 型号 / 要求 | 参考价 | 说明 |
|---|---|---|---|
| FPGA 开发板 | **ALINX AXAU15**（AMD Artix UltraScale+ XCAU15P-2FFVB676I，PCIe 金手指，FMC HPC） | 约 ¥4,600 | 本项目的位流、约束都按这块板写。用 PCIe Gen3 x4；板子可以直接由 PCIe 插槽供电。 |
| HDMI FMC 子卡 | **RK-FH1159**（HDMI 2.0 一入一出：TMDS181 接收、SN65DP159 发送、IDT 8T49N241 时钟） | 以卖家为准 | 实测型号。注意它和 ALINX 原版 FH1159 **引脚不同**，原版不能直接用。仓库里还有米联客 FMC_4K 的约束（`fpga/hdmi/mlk_fmc4k.xdc`），未经实机验证。 |
| JTAG 下载器 | Digilent JTAG-HS1 / HS2 或其他 Vivado 支持的 Xilinx 下载器 | 约 ¥400–600 | 只在第一次烧 QSPI、以后升级位流时用。 |
| HDMI 线 ×2 | HDMI 2.0（18 Gbps）及以上，PS5 → 采集卡；显卡 → 电视用 HDMI 2.1（48 Gbps） | — | 4K60 HDR 4:2:2 需要 5.94 Gbps/通道。 |

## 电脑

| 部件 | 要求 | 说明 |
|---|---|---|
| 主板 | 有一条空闲的 PCIe x4（或更宽）插槽 | 建议插芯片组的 x4 槽，别占用和显卡共享通道的 CPU 槽，否则显卡会降到 x8。 |
| 显卡 | NVIDIA RTX 40 / 50 系列，需带 HDMI 2.1 | VFG 需要光流硬件。作者用 RTX 5090：4K 4 倍补帧、质量 2，每批约 19 ms；较弱的卡请降低质量档。 |
| 系统 | Windows 11 x64 | 需要关闭 Secure Boot、开启测试签名模式（驱动是测试签名）。 |
| 内存 | 16 GB 以上 | 4K v210 每帧约 22 MB，驱动环形缓冲在内核内存里。 |

## 显示与声音

| 部件 | 要求 | 说明 |
|---|---|---|
| 电视 / 显示器 | 4K 120 Hz、HDR10、VRR（G-SYNC 兼容） | 作者用 LG G5。 |
| 功放（可选） | 支持 eARC 和 Dolby Atmos | 作者用 Yamaha RX-A4A；电视经 eARC 接功放。 |
| 主机 | PS5 / PS5 Pro | 需在系统设置里关闭 HDCP。 |

## 软件与授权

| 项目 | 说明 |
|---|---|
| AMD Vivado（作者用 2026.2） | XCAU15P 在免费版里可用。 |
| **AMD HDMI 1.4/2.0 RX/TX Subsystem 授权** | 付费 IP。评估授权可以编译，但硬件会定时停止；长期使用需向 AMD 购买。**这是整个项目最大的一笔开销，请先确认。** |
| AMD Vitis | 生成 MicroBlaze BSP（驱动库）。 |
| Visual Studio 2022 Build Tools + Windows WDK（NuGet 包 26100 即可） | 编译驱动和主机工具。 |
| Qt 6.8.3、NVIDIA Optical Flow SDK 5.x 等 | 编译 Veyra，按 Veyra 原项目的说明准备；Optical Flow SDK 需要 NVIDIA 开发者账号下载。 |

## 大致花费

不算电脑、电视和 HDMI 授权：开发板 + 子卡 + 下载器约 ¥6,000–8,000。HDMI IP 授权另计，按 AMD 报价。
