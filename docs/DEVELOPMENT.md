# 开发说明：寄存器、数据格式、测试命令

| 目录 | 内容 |
|---|---|
| `common/` | FPGA、驱动、应用共用的寄存器与 IOCTL 契约 |
| `fpga/rtl`、`fpga/tb` | 采集核心 RTL 与仿真（`build/sim.bat`） |
| `fpga/build` | `build.tcl` 从零建工程，`rebuild.tcl` 增量，`program.tcl` JTAG 下载 |
| `fpga/hdmi` | HDMI 接收：块设计 `bd.tcl`、两种 FMC 卡的引脚约束、EDID 生成器、MicroBlaze 固件 `fw/` |
| `driver/` | Windows KMDF 驱动（10EE:A15C） |
| `host/` | C++ 接收库 `xcap.*` 和 `xcap_test` |
| `veyra/` | Veyra 的编译脚本；Veyra 侧的采集源在 [Veyra fork 的 xcap 分支](https://github.com/isaac-cheng-if/Veyra-NRVideo/tree/xcap) |
| `tools/deploy_driver.sh` | 编译 + 签名 + 拷到测试机 |
| `tools/load_fpga.sh` | 下载位流 + 热重启测试机 |

## 数据格式
每帧 = 4 KB 帧头 + 像素 + 4 KB 帧尾，长度恒定。像素为 v210（4:2:2 10-bit，4K 每行 10240 字节，60 Hz 共 1.328 GB/s）或 BGRX8（1.991 GB/s）。
帧尾带最后一个像素的时间戳、每 lane 的 CRC-32C、是否与上一帧完全相同。视频侧溢出、断流时 FPGA 补齐并标记坏帧，不会让主机环形缓冲错位。

## 驱动
循环描述符 + 内核环形缓冲（2 MB 连续块），只读映射给采集程序；片级进度由 DMA 引擎写回内存，另有事件通知。
异常退出时由驱动停止 DMA 并回收；若引擎停不下来，内存隔离到设备移除为止。寄存器读不到魔数后不再访问硬件。

## 测试命令（测试机 C:\xcap）
`xcap_test info`、`xcap_test run 秒 v210|bgrx 片行数 自旋us 帧率 音频字每秒`（96000 = 立体声，768000 = 8 声道）、`xcap_test edid pcm|atmos`、`xcap_test hdmi`、`xcap_test cycle 次数`、`xcap_test kill`
`veyra\veyra_xcap_probe.exe 秒`：走 Veyra 自己的采集源。
`xcap_test grab 秒 [帧文件] [音频文件] [bgrx]`：真实 HDMI 信号源（PS5）检查：序号/CRC/丢帧、HDR 元数据、各声道电平，存一帧和音频；`tools/frame_to_png.py 帧文件 out.png` 转成图片查看（PQ 粗略映射到 SDR）。
PS5 必须关闭 HDCP（设置 → 系统 → HDMI），否则约每 1.8 秒断一次。

## HDMI 版位流
`fpga/build/build_hdmi.tcl <rk_fh1159|mlk_fmc4k>` 生成；同一个位流里既有 HDMI 接收也有测试图案。HDMI RX IP 用评估许可证，硬件上会超时停止，重新下载位流即可恢复。
固件：`fpga/hdmi/fw/build.ps1`（在 vivado-win 上用 Vivado 自带的 mb-gcc 编译；驱动源码取自卖家 KU5P 例程的 BSP，未放进本仓库）。
`xcap_test hdmi` 显示固件状态和当前信号。Veyra 设备列表里有 “XCAP HDMI 采集卡” 和 “XCAP 测试图案 4K60” 两项。

## Veyra
基于上游 Veyra 2.2.1（main `bc59d45`）。5090 主机 `C:\dev\veyra-xcap-221\Veyra_XCAP.cmd` 一键启动（`--xcap hdmi,120,2 --fullscreen`：等 PS5 信号、VFG 高质量、目标 120 fps、全屏，数据目录独立）。`veyra/build_full.bat` 编完整界面（源码 `C:\dev\veyra221`，构建 `C:\dev\veyra221-full`），`veyra/deploy.cmd` 以上一版部署目录为底换上新程序、QML、着色器并用 windeployqt 补齐 Qt 模块，`veyra/build_probe.bat` 只编采集部分。

## 音频与 HDR（hw 00030100、驱动 1.2.0.0、接口 00020000）
音频走第二个 C2H 通道：2048 字节定长包（头 'XCAU'、序号、时间戳，最多 508 个字），满包或约 0.8 ms 发一次，与视频互不阻塞。
HDMI 固件有两份内置 EDID（PCM / Atmos，HOST_CTRL bit4）；hw 00030100 起主机可写入自己的 EDID（寄存器 0x800，HOST_CTRL bit5 + 编号），`host/xcap_edid.*` 按电视的 EDID 合成。HDR10 静态元数据写进每帧头。Veyra 侧：7.1 PCM、IEC 61937 直通、解码回落、音频时间轴跟随 FPGA 时钟。
完整教程见 [TUTORIAL.md](TUTORIAL.md)；作者自己的部署记录见 [deploy-notes.md](deploy-notes.md)。
`fpga/build/reimpl_hdmi.tcl`：只重跑布线（改约束后用）。

## 没有卡时的整链测试
设环境变量 `XCAP_SIM=<控制文件>`，`host/xcap_sim.cpp` 就模拟一张卡：4K60 v210、30 fps 重复帧、HDR 元数据、音频（PCM 或 spdif 位流文件）。控制文件内容随时可改：
`lock=1 hdr=1 rate=59940 repeat=2 step=12 audio=2 carrier=a.eac3.raw crate=192000`。
回放真实片段：`clip=<文件>`（`xcap_test record 帧数 音频秒数 片段 音频` 在有信号的卡上录，v210 + 帧头 HDR 元数据）、`pcm=<文件>`（录下的音频字，原样回放，配 `audio=8`）。5090 上 `C:\dev\veyra-xcap\clip\` 有一段 PS5 登录界面（48 帧 + 20 秒 5.1 PCM，`ps5_audio_q.raw` 为 -30 dB 版）。
XCAP 的 PCM 以 32 位容器、24 位有效交给 Veyra（不再截成 16 位）。
## 其他脚本
`tools/reload_fpga.sh` 不重启重新下载位流；`tools/win/` 是 5090 主机本地用的版本；`fpga/build/update_fw.tcl` 只换固件；`fpga/build/qspi.tcl` 备份/烧录 QSPI（只运行过备份）。

## HDMI 环出（hw 00030300、固件 00050000）
HDMI OUT 默认原样重复 HDMI IN：画面、HDR/AVI/音频信息帧、音频（含 HBR 全景声）都不经过电脑，延迟只有 FIFO 里的几十到几百个像素。时钟芯片锁定在接收端的 TMDS 时钟上（RX_REFCLK_OUT → 8T49N241 CLK0）。
`xcap_test loopout on|off|force`（force：不接显示设备也开，用于抓链路数据），`xcap_test hdmi` 最后一行是 HDMI OUT 状态。测试图案（`xcap_test loop`）优先于环出。
硬件：`fpga/rtl/xcap_ptlink.sv`（视频弹性 FIFO，满则丢一帧、不反压采集；音频 FIFO），`bd.tcl` 里 v_tpg 开直通输入。BRAM 已用 91%。

## 刻意不放进仓库的文件
- FPGA 位流（`.bit`）与 QSPI 镜像：其中含 AMD HDMI 1.4/2.0 RX/TX Subsystem 等需授权的 IP，请用自己的授权按 `fpga/build/build_hdmi.tcl` 生成。
- 从个人显示设备读出的 EDID（含设备序列号）、采集样本、日志。
- 驱动签名证书与私钥（`driver/sign.bat` 只读取本机路径下的文件）。
- MicroBlaze BSP 驱动源码（来自卖家例程，未获再分发许可）。
