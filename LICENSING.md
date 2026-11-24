# 许可说明

XCAP 的源码公开，**个人、学习、研究等非商业用途免费**，**禁止商业使用**。

## 各部分用什么许可

| 部分 | 许可 | 说明 |
|---|---|---|
| 除下面两行以外的全部内容：FPGA RTL 与仿真、块设计与约束、MicroBlaze 固件、Windows 驱动、`xcap_test` / `xcap_play` 等工具、脚本、文档与图片 | [PolyForm Noncommercial 1.0.0](LICENSE.md) | 可以自用、修改、分享；不得用于任何商业目的 |
| 主机接收库：`host/xcap.h`、`host/xcap.cpp`、`host/xcap_edid.h`、`host/xcap_edid.cpp`、`host/xcap_sim.h`、`host/xcap_sim.cpp`、`common/xcap_hw.h`、`common/xcap_ioctl.h`（文件头标有 `SPDX-License-Identifier: GPL-3.0-or-later`） | [GPL-3.0-or-later](LICENSES/GPL-3.0.txt) | 这几个文件被编译进 Veyra（GPL-3.0），必须保持与 GPL 兼容，Veyra 才能合法分发 |
| `fpga/hdmi/fw/dp159.*`、`fpga/hdmi/fw/idt_8t49n24x.*` | MIT（AMD/Xilinx 原始声明保留在文件中） | 第三方代码，见 [`fpga/hdmi/fw/THIRD_PARTY.md`](fpga/hdmi/fw/THIRD_PARTY.md) |

## 什么算商业使用

以下情况都需要另行取得商业授权：

- 销售采集卡成品、套件、烧好位流的板卡，或以此提供付费服务；
- 把 XCAP 的 FPGA 设计、固件或驱动集成到商业产品中；
- 公司以营利为目的在内部使用。

PolyForm Noncommercial 明确允许个人自用、学习研究、爱好项目，以及慈善、教育、公共研究、政府机构等非营利组织使用，具体以 [LICENSE.md](LICENSE.md) 原文为准。

需要商业授权，请通过 [GitHub](https://github.com/isaac-cheng-if) 联系作者。

## 以前的版本

在许可变更之前（提交 `3eeb183` 及更早）发布的版本是 GPL-3.0，已经拿到这些版本的人仍可按 GPL-3.0 使用那些版本；新的许可只适用于之后的版本。
