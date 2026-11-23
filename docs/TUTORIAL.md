# 教程：从零到在 PC 上补帧玩 PS5

整个流程分六步：组装硬件 → 编译固件和位流 → 烧进板上 QSPI → 准备 Windows 并装驱动 → 检查采集 → 编译并启动 Veyra。第一次做大约需要一到两天，主要时间花在准备工具链和 HDMI IP 授权上。

> 脚本里的路径固定为 `C:\dev\...`（工作目录 `C:\dev\xcap`、Visual Studio 在 `C:\dev\VS`、WDK 在 `C:\dev\wdk`、Vivado 在 `C:\AMDDesignTools\2026.2`）。用别的路径时，请改各脚本开头的变量。

---

## 1. 组装硬件

1. **断电。** 电脑关机并拔掉电源。
2. **AXAU15 跳线 J8 必须断开。** 断开时 FMC 的 VADJ 是 1.8 V，短接是 1.2 V；子卡按 1.8 V 设计。
3. **把 RK-FH1159 插到 AXAU15 的 FMC 座**，确认对齐、压紧。
4. **把 AXAU15 插进 PCIe 槽。** 建议用芯片组的 x4 槽，别占用和显卡共享通道的 CPU 槽，否则显卡会降到 x8。板子可以直接由插槽供电。
5. **接线：**
   - PS5 → 子卡丝印 **HDMI IN**；
   - JTAG 下载器 → AXAU15 的 JTAG 口；
   - 显卡 HDMI 2.1 → 电视；
   - 子卡的 HDMI OUT 是可选的环出，可以接功放空闲的输入，**不要接电脑正在用的显示器**：显示器一切输入，电脑那一路就会断开。

## 2. 准备工作目录

把仓库克隆到任意位置，然后按脚本期望的目录摆放：

```bat
git clone https://github.com/isaac-cheng-if/XCAP.git C:\src\XCAP
robocopy C:\src\XCAP\fpga\rtl    C:\dev\xcap\rtl    /E
robocopy C:\src\XCAP\fpga\hdmi   C:\dev\xcap\hdmi   /E
robocopy C:\src\XCAP\fpga\build  C:\dev\xcap\build  /E
robocopy C:\src\XCAP\driver      C:\dev\xcap\driver /E
robocopy C:\src\XCAP\host        C:\dev\xcap\host   /E
robocopy C:\src\XCAP\common      C:\dev\xcap\common /E
```

## 3. 固件与位流

### 3.1 HDMI IP 授权

把 AMD HDMI 1.4/2.0 RX/TX Subsystem 的授权文件装进 Vivado（`%APPDATA%\XilinxLicense` 或 Vivado License Manager）。评估授权能编译，但硬件会定时停止，长期使用需要正式授权。

### 3.2 MicroBlaze BSP（第一次需要）

固件依赖 AMD 的驱动库（vphy、v_hdmirxss、v_hdmitxss、v_tpg、iic、intc 等），仓库里没有。生成方法：

1. 用 Vivado 打开一个 xcau15p-ffvb676-2-i 的工程，`source C:/dev/xcap/hdmi/bd.tcl` 生成块设计，生成输出产品后导出硬件：`write_hw_platform -fixed C:/dev/xcap/hdmi/hdmi_sys.xsa`。
2. 在 Vitis 里基于这个 XSA 建一个 MicroBlaze standalone 平台，得到 BSP 的头文件和驱动源码。
3. 按 `fpga/hdmi/fw/build.ps1` 期望的结构，放到 `C:\dev\xcap\hdmi\bspx\`：`include\` 放头文件，每个驱动一个子目录放源码。

固件是按这组驱动版本写的：vphy 1.13、v_hdmirxss 6.4、v_hdmirx 2.7、v_hdmitxss 6.3、v_hdmitx 2.6、v_hdmi_common 1.7、v_tpg 8.4。新版 Vitis 生成的驱动版本更高，可能需要少量适配。

### 3.3 编译固件

```bat
powershell -ExecutionPolicy Bypass -File C:\dev\xcap\hdmi\fw\build.ps1
```

成功时最后显示 `compiled … failed 0` 和 `hdmi_fw.elf` 的大小，ELF 在 `C:\dev\xcap\hdmi\hdmi_fw.elf`。

### 3.4 编译位流

```bat
cd /d C:\dev\xcap\build
C:\AMDDesignTools\2026.2\Vivado\bin\vivado.bat -mode batch -source build_hdmi.tcl -tclargs rk_fh1159
```

大约 30–60 分钟。结束时打印 `STATUS=write_bitstream Complete! WNS=… WHS=…`，WNS 和 WHS 都应为正。位流在 `C:\dev\xcap\xcap_hdmi_rk_fh1159.bit`。以后只改固件时，用 `update_fw.tcl` 几分钟就能出新位流。

## 4. 烧进 QSPI

先备份板子出厂的 QSPI 内容，再写入新位流：

```bat
cd /d C:\dev\xcap
C:\AMDDesignTools\2026.2\Vivado\bin\vivado.bat -mode batch -source build\qspi.tcl -tclargs backup C:/dev/xcap/qspi_factory_backup.bin
C:\AMDDesignTools\2026.2\Vivado\bin\vivado.bat -mode batch -source build\qspi.tcl -tclargs write C:/dev/xcap/xcap_hdmi_rk_fh1159.bit
```

看到 `Program/Verify Operation successful` 后关机断电，再开机。此后板子上电自启，不再需要 JTAG。

## 5. 准备 Windows、安装驱动

### 5.1 关闭 Secure Boot、开启测试签名（管理员）

1. 进 BIOS 关闭 Secure Boot。BitLocker 若开着，请先暂停，并准备好恢复密钥。
2. 管理员终端执行：

```bat
bcdedit /set testsigning on
```

### 5.2 生成自己的测试证书（管理员 PowerShell，只做一次）

```powershell
$c = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=XCAP Test Signing" -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy Exportable -HashAlgorithm SHA256
New-Item -ItemType Directory -Force C:\dev\xcap\sign | Out-Null
$pw = Read-Host -AsSecureString "pfx password"
Export-PfxCertificate -Cert $c -FilePath C:\dev\xcap\sign\xcap_test.pfx -Password $pw
Export-Certificate -Cert $c -FilePath C:\dev\xcap\sign\xcap_test.cer
certutil -addstore -f Root C:\dev\xcap\sign\xcap_test.cer
certutil -addstore -f TrustedPublisher C:\dev\xcap\sign\xcap_test.cer
```

`sign.bat` 从 `C:\dev\xcap\sign\pw` 读取 pfx 密码，请把密码写进这个文件，并只留在本机。完成后**重启**，测试签名才会生效。

### 5.3 编译、签名、安装驱动（管理员）

需要 Visual Studio 2022 Build Tools，以及 WDK/SDK 26100（NuGet 包解压到 `C:\dev\wdk`）。

```bat
C:\dev\xcap\driver\build.bat
C:\dev\xcap\driver\sign.bat 1.4.0.0
pnputil /add-driver C:\dev\xcap\driver\out\pkg\xcap.inf /install
```

设备管理器里出现 "XCapture" 类设备、状态正常，就装好了。

## 6. 检查采集

编译主机工具：

```bat
C:\dev\xcap\host\build.bat
```

PS5 开机后依次运行：

```bat
C:\dev\xcap\host\out\xcap_test.exe info
C:\dev\xcap\host\out\xcap_test.exe hdmi
C:\dev\xcap\host\out\xcap_test.exe grab 10
```

| 命令 | 应看到 |
|---|---|
| `info` | `link Gen3 x4`、硬件版本号 |
| `hdmi` | `LOCKED`、`3840x2160 59.9 Hz 4:2:2 12 bit`、`HDR 1`、`source 5V on` |
| `grab 10` | 约 600 帧，`ERRORS` 一行全部为 0，最后 `PASS` |

`grab` 还可以把一帧存下来，用 `tools/frame_to_png.py` 转成 PNG 看画面。

## 7. PS5 设置

| 位置 | 设置 |
|---|---|
| 系统 → HDMI | **关闭 HDCP**（不关就没有画面，或周期性断开） |
| 屏幕和视频 | 2160p；HDR **始终开启**；120 Hz 和 VRR 关闭（采集卡是 HDMI 2.0，最高 4K60） |
| 声音 → 音频输出 | HDMI 设备类型选 **AV 功放**；电视和功放支持全景声时，音频格式（优先）选 **位流（Dolby Atmos）** |

PS5 看到的 EDID 由软件按你电视的真实能力合成，所以选项会和直连电视时一致。

## 8. Veyra

1. 克隆 [Veyra fork 的 `xcap` 分支](https://github.com/isaac-cheng-if/Veyra-NRVideo/tree/xcap)，按 Veyra 原项目说明准备 Qt 6.8.3、NVIDIA Optical Flow SDK 等依赖后编译。`veyra/build_full.bat` 是作者的编译命令，可作参考。
2. Windows 显示设置：电视设为 3840×2160、120 Hz、开启 HDR；NVIDIA 控制面板设为 10 bit、RGB、完全范围，开启 G-SYNC。
3. 启动：

```bat
veyra_qml_ui.exe --data-dir C:\veyra-data --xcap hdmi,120,2 --fullscreen
```

`--xcap` 的三个值依次是：信号源（`hdmi` 为采集卡输入，`pattern` 为卡内测试图案）、目标帧率（120）、VFG 质量（0 低、1 中、2 高，2 是最高档）。有信号时自动打开采集并全屏：30 fps 内容补 4 倍，60 fps 内容补 2 倍。

## 9. 电视与功放

| 设备 | 设置 |
|---|---|
| 电视（以 LG G5 为例） | 该 HDMI 口开启 4K / Deep Color；游戏模式；HDR 色调映射用 HGiG；VRR 开 |
| 电视声音 | 输出到 HDMI(ARC)，开启 eARC，数字音频输出选直通 |
| PS5 HDR 校准 | 接好后重新做一次 |

**先开功放再启动 Veyra：** 功放关着时，电视的 EDID 只报 2 声道 PCM。

## 10. 常见问题

| 现象 | 检查 |
|---|---|
| `HDMI card NOT FOUND` | 子卡没插好，或 J8 被短接了 |
| `source 5V off` | 线接错口（要接 HDMI IN），或 PS5 没开机 |
| 有 refclk 但一直不 LOCKED | HDCP 没关，或 PS5 输出的格式不在 EDID 里 |
| 几小时后突然没信号 | HDMI IP 用的是评估授权（硬件定时停止） |
| 颜色不对 | `xcap_test hdmi` 第二行的色彩格式，对照 PS5 设置 |
| 功放不显示 Atmos | 电视 eARC 是否开启；PS5 音频格式；游戏声音里有没有全景声对象（没有时功放显示 PCM，属正常） |
| 电脑另一台显示器断开后电视黑屏 | Windows 重新排列了显示器；在 Windows 里固定电视为 4K 120 Hz，再重启 Veyra |

## 延迟

以 30 fps 游戏为例：

| 环节 | 耗时 |
|---|---|
| 采集到内存 | 约 0.01 ms |
| 等下一帧（插帧固有） | 25 ms |
| 补帧计算与调度 | 约 8 ms |
| 上屏 | 约 2 ms |
| 电视扫到画面中部 | 约 4 ms |

合计比 PS5 直连多约 30 ms。60 fps 内容只需等 8.3 ms，合计多约 12 ms。
