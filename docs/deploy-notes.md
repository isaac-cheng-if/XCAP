# PS5 Pro → 采集卡 → 5090 补帧 → LG G5（eARC 接功放）

```
PS5 Pro ──HDMI──▶ RK-FH1159 HDMI IN ─▶ AXAU15 ─PCIe Gen3 x4─▶ Windows / RTX 5090（Veyra 补帧）──HDMI──▶ LG G5 ──eARC──▶ 功放
```
PS5 看到的 EDID 由电脑按 G5 和功放的真实能力合成（HDR 亮度、声道、Dolby/DTS 格式），视频部分限制在 HDMI 2.0（4K60 4:2:2 HDR10）。

## A. 先在测试机（.31）上验证子卡
1. 关测试机并断电。AXAU15 跳线 **J8 必须断开**（断开 = VADJ 1.8 V，短接 = 1.2 V）。
2. 插 RK-FH1159，PS5 接丝印 **HDMI IN**（HDMI2）。
3. 开机后在 Mac 上下载位流（会重启测试机，只重启测试机）：
```bash
/Volumes/NAS-HDD/MacOS/XDMA-DLSS/tools/load_fpga.sh
```
4. 看状态，应为 `HDMI card found`、`source 5V on`、`LOCKED`、`3840x2160`、`4:2:2`：
```bash
ssh pcie-win "C:\xcap\xcap_test.exe hdmi"
```
5. 走 Veyra 采集源：
```bash
ssh pcie-win "cd /d C:\xcap\veyra & veyra_xcap_probe.exe 10 hdmi sound"
```
之后再换位流或评估核超时，用不重启的版本（约 19 秒）：
```bash
/Volumes/NAS-HDD/MacOS/XDMA-DLSS/tools/reload_fpga.sh
```

## B. 装进 5090 主机（需要你自己关机、改设置，我不会重启这台）
1. BIOS 关 Secure Boot（BitLocker 没开，不会触发恢复密钥）。
2. 管理员终端执行，然后重启：
```bash
bcdedit /set testsigning on
```
3. 信任测试证书（管理员终端，两条）：
```bash
certutil -addstore -f Root C:\dev\veyra-xcap\driver\xcap_test.cer
```
```bash
certutil -addstore -f TrustedPublisher C:\dev\veyra-xcap\driver\xcap_test.cer
```
4. 插卡。优先插芯片组的 x4 槽；如果插 CPU 的第二条 x16 槽，开机后确认 5090 仍是 x16：
```bash
nvidia-smi --query-gpu=pcie.link.width.current --format=csv
```
5. 管理员运行 `C:\dev\veyra-xcap\reload_fpga.cmd` 下载位流。找不到卡就热重启一次（不要断电），再运行一次。
6. 管理员运行 `C:\dev\veyra-xcap\install_driver.cmd`。
7. 双击 `C:\dev\veyra-xcap\xcap_play.exe`。

测试签名模式和关 Secure Boot 会影响部分带反作弊的 PC 游戏。想避免，需要给驱动做微软正式签名（要 EV 证书）。

## C. xcap_play 做了什么
- 按 EDID 找到带 Dolby 的那台显示器（G5，不要求是主显示器；也可 `tv=LG TV` 指定），电视切到 4K **120 Hz** 并开 HDR（G5 的 165 Hz 实际显示不稳定，不用）。原来若是 165 Hz，退出后会恢复原样，建议直接在 Windows 里也固定成 120 Hz。
- 等 PS5 出信号，自动打开采集、全屏、防息屏；退出后恢复原来的显示设置。
- 补帧：NVIDIA VFG 高质量，目标 120 fps，按真实帧率自动选倍率（30→4X，40→3X，60→2X），低延迟和 VRR 打开。
- 参数：`fps=120`、`quality=0..5`（1 = 中，2 = 高）、`hz=120`（刷新率上限，默认就是 120）、`keep`（不动显示设置）、`pattern`（测试图案）。

- 没有卡也能看效果：双击 `C:\dev\veyra-xcap\test_without_card.cmd`。

## D. 各设备设置
| 设备 | 设置 |
|---|---|
| PS5 HDMI | **关 HDCP**（不关没画面）；HDMI 设备联动可关 |
| PS5 画面 | 2160p；HDR 选“**始终开启**”（避免进出游戏时切换，切换一次约 1 秒黑屏）；120 Hz 关、VRR 关 |
| PS5 HDR 校准 | 接好后重新做一次，电视用 HGiG |
| PS5 声音 | HDMI 设备类型选 AV 功放；先用线性 PCM 调通，再选 Dolby Atmos |
| 显卡 | NVIDIA 控制面板：10 位、RGB、完全；G-SYNC 打开（窗口和全屏） |
| LG G5 | 该 HDMI 口开“HDMI Deep Color / 4K”；游戏模式；HDR 色调映射选 **HGiG**；VRR 开；输入图标改成 PC |
| LG G5 声音 | 声音输出 HDMI(ARC)、**eARC 开**、数字音频输出选 **直通（Pass Through）** |
| Windows 声音 | 不用改，Veyra 自动选 LG 电视端点 |

## E. 声音
| PS5 输出 | 走法 |
|---|---|
| 立体声 / 5.1 / 7.1 PCM | Veyra 音画同步播放，Windows → G5 → eARC → 功放（Windows 里把 LG 端点配置成 7.1） |
| Dolby Atmos（MAT 或 E-AC-3）| 端点支持就原样直通，功放应显示 Dolby Atmos；否则解码成 PCM，没有高度对象 |
| DTS | G5/功放没有申报，也不会向 PS5 申报 |

- 2026-11-23 接 G5 + 功放实测：AC-3、E-AC-3、MAT 端点都支持，MAT 和 E-AC-3 载体直通 15 秒 0 断流。复查命令：
```bash
ssh vivado-win "C:\dev\veyra-xcap\veyra_xcap_audio_tests.exe"
```
- 音频延迟自动跟随补帧的实际画面延迟。
- PS5 和显卡的时钟差几十 ppm，位流不能重采样，所以每隔几分钟整帧增减一次，优先挑安静的时刻。
- MAT 里如果装的是 PCM 而不是 TrueHD（MAT 2.0），只能直通，不能解码。

- **先开功放再开 xcap_play 和 PS5。** G5 的 EDID 跟着功放变：功放关着只报 2 声道 PCM，开着报 7.1 PCM、E-AC-3 Atmos、MAT。PS5 已有信号时，只有能力真正变好才会重新热插拔一次。

- 功放是雅马哈 RX-A4A（MusicCast 网络接口，IP 见功放设置），可以直接问它收到什么格式：`tools/avr_check.sh <功放 IP>`。
- **2026-11-23 实测：真 Atmos（DD+ JOC，Dolby Access 自带片源）直通到功放显示 `Dolby Atmos/PCM`，全景声通。** G5 会解码 Dolby 再以 MAT 送给功放：有对象的显示 Atmos，没有对象的 5.1（测试音）显示 PCM，这是正常的。G5 的“数字音频输出”改成“直通”是可选项，能少一次转换。

## F. 出问题先看
| 现象 | 看什么 |
|---|---|
| `HDMI card NOT FOUND` | 子卡没插好，或 J8 短接了 |
| `source 5V off` | 线、口不对（要 HDMI IN），或 PS5 没开 |
| `refclk` 有值但不 LOCKED | HDCP 没关，或格式不在 EDID 里 |
| 几小时后突然没信号 | HDMI 评估核超时：`reload_fpga.sh` / `reload_fpga.cmd` |
| 画面偏色 | `xcap_test hdmi` 第二行对照 PS5 设置 |
| 功放没显示 Atmos | 上面的端点测试；G5 的 eARC 直通；PS5 音频格式 |
| 日志 | `C:\dev\veyra-xcap\logs\veyra-qml.log`、`xcap_play.log` |

## G. 与 PS5 直连的差别
- 补帧必须等下一帧：30 fps 4X 固有 25 ms，加显卡和采集，实测（虚拟采集卡，5090）最后一行到上屏 P95 约 33 ms。这是插帧原理决定的，不可能和直连一样低。
- PS5 走 HDMI 2.0，4K60 HDR 是 4:2:2；直连 G5 时可以是 4:4:4/RGB。
- HDMI-CEC（手柄开电视等）不经过采集卡。

## H. QSPI（未烧）
出厂内容已备份在 `fpga/qspi_factory_backup.bin`（32 MB）。没烧之前每次断电都要重新下载位流。
烧录命令（在 vivado-win 上执行 `fpga/build/qspi.tcl -tclargs write`）还没运行过。
