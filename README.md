# 宾得QR CLI

宾得（PENTAX）功能二维码的 CLI 生成器。纯本地计算，不联网、不连接相机、不上传序列号。用 Zig 编写，单文件可执行程序，零第三方依赖。

支持 K-1、K-1 II、K-3 III 彩色版与 K-3 III Monochrome，每台机身四张码：渐变 ND、星点自动对焦、遥控对焦微动、星空影像处理。

实现原理参考 [k1ii-qr](https://github.com/nahtaki/k1ii-qr)。

## 输出

| 格式 | 用途 |
| --- | --- |
| `png`（默认） | 540×540、1-bit 灰度、白边 4 模块，可直接打印或显示 |
| `svg` | 矢量，适合排版与打印 |
| `text` | 直接打印到终端，手机扫屏幕；`--color=always` 用半块字符，管道/重定向自动降级为 `██`/空格 |

相同输入重复运行产出逐字节相同的 PNG（无时间戳、确定性压缩）。

## 构建

需要 Zig **0.17.0**：

```sh
zig build                        # 生成 zig-out/bin/pk-qr
zig build test                   # 单元测试
zig build -Doptimize=ReleaseSafe # 发布构建
```

交叉编译：

```sh
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

## 用法

```sh
# K-1 II，四项功能，写到当前目录
pk-qr --serial 1234567

# 指定机型、输出目录、缩放与静区
pk-qr -m k3iii -s 0012345 -o out --scale 16 --border 4

# K-3 III Monochrome（黑白版），功能 ID 与彩色版相同
pk-qr -m k3iiim -s 0012345 -o out

# 只要渐变 ND 与星空影像处理
pk-qr -s 0012345 --feature gradient-nd --feature 37

# 直接打印到终端，用手机扫屏幕（不写任何文件）
pk-qr -s 0012345 --feature 2 -f text

# 机器可读输出，不落盘
pk-qr -s 0012345 --dry-run --json

# 覆盖已存在文件
pk-qr -s 1234567 -o out --force
```

参数与契约的完整说明见 [docs/design.md](docs/design.md) 第 8 节。文件名格式：

```text
{机型前缀}_{序号2位}_{功能slug}_{序列号}.{png|svg}
K1II_01_gradient-nd_0012345.png
K3IIIM_01_gradient-nd_0012345.png
```

`--feature` 接受功能 ID（如 `2`）或 slug（如 `gradient-nd`），可重复，默认全部四项。K-3 III 与 K-3 III Monochrome 使用同一组 ID：`28`/`31`/`34`/`37`。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 2 | 参数用法错误 |
| 3 | 输入非法（序列号、机型、功能） |
| 4 | I/O 失败（目录不存在、写盘失败） |
| 5 | 目标文件已存在且未加 `--force` |

## 已验证

- 60 条内容向量（15 组「机型 + 序列号」× 4 项功能）与参考实现逐字节一致，见 [docs/protocol.md](docs/protocol.md) 第 5 节；其中 K-3 III Monochrome 的 12 条来自参考项目固件 2.20 向量。
- 生成的 PNG 经 zxing-cpp 解码，4/4 得到预期 payload；终端半块字符渲染与无色渲染同样可解码。
- K-3 III（彩色，`-m k3iii`）已由维护者真机确认相机可接受生成的二维码（2026-11-05）；K-1 II（`-m k1ii`）与 K-3 III Monochrome（`-m k3iiim`）同样已真机确认（2026-11-19）。仅 K-1（初代）尚未真机确认，见 [docs/roadmap.md](docs/roadmap.md) 第 4 节。

## 许可

本项目以 **GNU General Public License v3.0 or later** 发布，完整条款见 [LICENSE](LICENSE)。源文件统一带 SPDX 标识：

```zig
// SPDX-License-Identifier: GPL-3.0-or-later
```

本项目是独立实现，未复制参考项目的源代码。参考项目源码仅用于交叉核对逆向结论，克隆在 `docs/k1ii-qr/`，已被 `.gitignore` 排除，不进入版本库，也不随发行物分发。

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/protocol.md](docs/protocol.md) | 二维码内容算法、机型与功能表、验证向量、验收标准 |
| [docs/design.md](docs/design.md) | 实现架构、模块划分、CLI 契约、输出格式 |
| [docs/roadmap.md](docs/roadmap.md) | 里程碑、测试策略、真机验证记录、决策记录 |

## 免责声明

非官方工具，与理光/宾得无关联。K-1 II、K-3 III（彩色）与 K-3 III Monochrome 已通过真机扫码确认；K-1（初代）尚未确认，请自行评估风险。
