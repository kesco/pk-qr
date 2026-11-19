# 协议：功能二维码内容与图形参数

本文档定义本项目必须逐字节复现的内容算法，以及二维码的输出图形参数。

参考项目：`nahtaki/k1ii-qr`，本地克隆于 `docs/k1ii-qr/`（被 `.gitignore` 排除），对照提交 `e322a60b43d02396be27ed5cdaf37186560ff410`。

## 1. 适用范围

| 机型 | 机型值 `modelWord` | 功能 ID | 文件前缀 |
| --- | --- | --- | --- |
| K-1 II | 78400 | 2, 11, 14, 17 | `K1II` |
| K-1 | 77970 | 2, 11, 14, 17 | `K1` |
| K-3 III（彩色） | 78420 | 28, 31, 34, 37 | `K3III` |
| K-3 III Monochrome | 78550 | 28, 31, 34, 37 | `K3IIIM` |

四项功能的固定顺序与显示名：

| 序号 | 功能 | K-1 / K-1 II ID | K-3 III / Monochrome ID | ASCII slug（文件名用） |
| --- | --- | --- | --- | --- |
| 1 | 渐变 ND | 2 | 28 | `gradient-nd` |
| 2 | 星点自动对焦 | 11 | 31 | `star-autofocus` |
| 3 | 遥控对焦微动 | 14 | 34 | `remote-focus-step` |
| 4 | 星空影像处理 | 17 | 37 | `astro-processing` |

K-1 与 K-1 II 的功能 ID 相同，但 `modelWord` 不同，因此同样序列号生成的二维码内容不同，不可混用。

K-3 III Monochrome 与彩色版共用功能 ID，但 `modelWord` 不同（78550 对 78420），因此同样序列号生成的 payload 不同，不可混用。

不在范围内：K-3 II 及其他机型。未获得其机型值或功能 ID，不得推测。

## 2. 输入：序列号规范化

序列号是打印在机身上的十进制串，规则与桌面版/Python `str.strip()` 语义一致：

1. 去掉首尾空白。空白集合为 Python `str.strip()` 认定的字符：
   `U+0009–U+000D`、`U+001C–U+0020`、`U+0085`、`U+00A0`、`U+1680`、`U+2000–U+200A`、`U+2028`、`U+2029`、`U+202F`、`U+205F`、`U+3000`。
2. 去掉空白后必须是 1–20 个 **ASCII** 数字 `0`–`9`。
3. 前导零有含义，按字符串处理，绝不能被解析成整数。

拒绝的输入：空串、纯空白、全角数字、阿拉伯-印度数字、内含空格、`-`/`../` 等路径字符、21 位以上、NUL 字节、`U+FEFF`（不在 strip 集合内）、非字符串。

## 3. 内容算法

常量（均为 ASCII 字面量）：

| 常量 | 值 |
| --- | --- |
| 机型前缀 | `g05gdn4z621s33z2woiyxny0ehj2qh2a` |
| 功能前缀 | `pcig9piz9825bd2iz0j4oe2tszkefde5` |
| 序列号前缀 | `urj4rwz08lyr637pzabdu8pvdo995hbs` |
| 迭代次数 `HASH_ROUNDS` | `0x1617` = 5655 |

推导步骤（`SHA-256` 均为标准 SHA-256，输出 32 字节）：

```text
serialBytes = ASCII(serial) 右补 0x00 至 20 字节
modelHash   = SHA256( ASCII("g05gdn4z621s33z2woiyxny0ehj2qh2a") || LE32(modelWord) )
featureHash = SHA256( ASCII("pcig9piz9825bd2iz0j4oe2tszkefde5") || LE32(featureId) )
serialHash  = SHA256( ASCII("urj4rwz08lyr637pzabdu8pvdo995hbs") || serialBytes )

digest = SHA256(modelHash || featureHash || serialHash)      // 96 字节输入
重复 5655 次：digest = SHA256(digest)                        // 每次输入 32 字节
payload = digest 的 64 个小写十六进制字符
```

细节：

- `LE32` 为 32 位小端无符号整数，4 字节。
- 机型值与功能 ID 只参与各自前缀哈希，**不**直接出现在合并输入里；合并输入固定 96 字节。
- 迭代输入是二进制摘要（32 字节），不是十六进制文本；迭代次数是 5655，加上首次合并哈希共 5656 次 SHA-256。
- 输出是摘要，不是可逆加密，不包含任何可用于反推序列号的明文。
- 每个功能独立计算；单次运行共 4 × 5656 = 22624 次 SHA-256，耗时在毫秒级。

校验示例：K-1 II、序列号 `1234567`、渐变 ND（ID 2）→
`3076671264a298371f15269a729d07ffe3eccd7d80efeacefc93d4fb27f1df62`。

## 4. 二维码图形参数

相机对二维码的容错能力未知，因此严格照搬参考实现的参数，不自行优化：

| 参数 | 值 |
| --- | --- |
| 内容 | 64 个 ASCII 小写十六进制字符（字节模式，无前缀、无分隔符） |
| 版本 | 固定 Version 5（37×37 模块） |
| 纠错等级 | L（约 7%） |
| 编码模式 | 字节模式 |
| 静区（白边） | 4 模块 |
| 模块像素 | 12 px |
| 图像尺寸 | (37 + 4×2) × 12 = **540×540** |
| 配色 | 纯黑白，无渐变、无圆角、无 logo |

内容长度固定为 64 字节，Version 5-L 数据容量 106 码字（单块，28 个纠错码字，共 134 码字），容量足够且版本不变，实现可只支持这一种组合。

掩码图案参考实现由 Nayuki 编码器按惩罚分自动选择；不同实现可能选到不同掩码，**解码内容一致即可**，mask 不构成兼容性要求。

## 5. 验证向量

以下向量已用独立实现（Python `hashlib` + 本文第 3 节公式）复算，与参考项目的 `vectors.json`、`k1-vectors.json`、`k3iii-vectors.json`、`k3iiim-vectors.json` 全部一致（60/60）。

列顺序固定为：渐变 ND / 星点自动对焦 / 遥控对焦微动 / 星空影像处理。

| 机型 | 序列号 | 渐变 ND | 星点自动对焦 | 遥控对焦微动 | 星空影像处理 |
| --- | --- | --- | --- | --- | --- |
| K-1 II | `0` | `4833e56d7252517de6fc8513a3e5fdd6a19b777f25ad22e7a0a9072da162405a` | `7693eb216e882fdc1f0ccc4eb221f9e4533be0bfb4f47d639ef7a57aa99f9246` | `e7e63da7344f8752e5af9561f50afe19f3852eaffbec43da5b19f84ae6046b12` | `4f80c357ab3b9f9674785688667a0764978037674921a6cb36fcfe596fa9d9da` |
| K-1 II | `0000000` | `d9ea127cc4c358bc2dd11353a7a8662b8ec60ca705833adc4112d139b116975d` | `f54a59b086cfe12a4d6e157d91c380aadb9ba689c64f079a776ac486f076a024` | `5d232aa0c75c7336a9680be3732639271ee282dad4bbbb0040c8389ee99bcbbc` | `9ce5492d0075540da7fd7ded04db9fd96da0114eac5f1d9292f1cdd520de3f3f` |
| K-1 II | `1234567` | `3076671264a298371f15269a729d07ffe3eccd7d80efeacefc93d4fb27f1df62` | `ceaa65445b9e17a6cec5d12a4c2290906fc2ffcd398d6b601c7b9c09012df49b` | `6584dcaec17c1677c9d1ae728cf49e574bf68fd1f54cd12b4aeb94193435a6c3` | `7228700f4a1092c12ddd60e6fefd7ef9e7adb9a87edafe0a337a6a1bb3206cf0` |
| K-1 II | `0012345` | `9ca3113083e40d33f8f52f9ced111d2b716f2a20426b8c75171edfa3b402829d` | `652845984289c653634905376836ca6e6c12c08b012820efe700209e201873ed` | `996cb980fb475902f044774eea093fdbfa83f1ba063978141f5c70bc757923e9` | `ffc70185e25c82f800dc073fea942c7b45a1273592304d8be2c589f928bf817d` |
| K-1 II | `12345` | `ae4ca93b6937616322166e4801d12d6fc22789fee4dcd892c6bce68954cdeca0` | `4af4d880e79ff44738d898760c9e9ae2ab808a9bd2ba10ebf64ff5a93cbd2689` | `614226d3e398460eeca1a48967a19719b8a1dd3cfcc3fadceefad0ec01afee7d` | `aa2f40001f4748cb719b505c285116e890fed70d48c199e092d6ed383d22eddf` |
| K-1 II | `12345678901234567890` | `a458d7e3e6703744a37689f0addc0fba7f8450daeb90d39682c2aee1f162e1dd` | `44942c90ddcfed54ef5d23f1daa303bb3416841dbb1ea6e8b9824c2d8cf79899` | `5e89df9a1862d40a1c0cceec6cc95b2be84bd4cf53c7f9dc6b997d05bd5495ab` | `b69d69b9b418669f9abd3859cac8d4c55b9cfba7ac30b907a6c579276ac64e12` |
| K-1 | `1234567` | `2dc37209a5aa646ae002f448d239f2f3bf12898984efaf93d96920cc73a109fd` | `e9ff5c3f136d72a535b1f01a85e66596eaec2d1eeff4a558580830fd9bc5f05f` | `ac6717720c92513179347e512a7bf9ac725aaba009da29682be8dc481107164a` | `6f374bd9544dfa38a239d5d8636b365cacc9c50ed0938ac86b86ca3107b9eb23` |
| K-1 | `0012345` | `2b2085e26f5e83a209aad82c7ec565e2b5685ba3e4f378d4d4dc37c87149695e` | `5d1ead7cb66a3d1f8a59ae8cbb41a1f1a0235eb5732f7445b527ad907d198eb4` | `0367b6d23896c04b6c0ca8d9ab7aeabf368f372f9b20efb85d0fce8cce645f62` | `854368834445fe8ba920c390b0f7224cccc99df7e911b401b9abcc9d7b4dc911` |
| K-1 | `12345678901234567890` | `49643ec4c4239d21201aec69dfefd8c42e0cc6d5d0d57ff7e32fd4b4676e69c7` | `5193ba6df3c66ee8d038a6c7c4c04fe7716c202973dd47b2b392322cd345c676` | `e9e2ba7e29020c1c9aaa5be7a4a920c0137aabfc625bc33488a436cbbbb7a73c` | `a3edf1a6d6c881a27e5cc4f34fe74c21275760b0287aab8c9b0b459bdb77c11e` |
| K-3 III | `1234567` | `43e11198220fe7dedd925ee771cbabb8664413b7e098ba248ed32921831eac2c` | `c13a576b9586918782466fb70693f1212c1a8d0da7d4467127cd8da7d4af369a` | `7cde30895632fda14f76bb7db6cdd6cd39064704d5c45f048b2a6faf5d7f977f` | `f212ad5fd23dc69deefb532017176a10df9a6d94a4ee7ece706941ec5d76aa66` |
| K-3 III | `0012345` | `950139aefdeaceab303b3cd94efe6c525c6d868569c659eba1c7b7911fe35a6f` | `fd80ac345bddf4323bf2e43738b98ca11d7752d590371abb96090339bc576460` | `f5f69e80f85003bf1e52dce03d0597f329d5f07df439d751051f9ad9d2de9361` | `2f36d1a23b52b04fe529b93622b50d8d037efecf1a12c7cb0510b403c49b5d11` |
| K-3 III | `12345678901234567890` | `5fed6ccd22260a43dba165111f27a7d0c6b9a81c8776a70d4b1670c8623b3a4a` | `9ca005088b5785f0c80cf41dacf2ad6dde81900ea3c35f0ef6bb06bee0a483ba` | `ecb2457b2e8b9ea155b845996515039d8748e3eeb77e3233010190d2fccffa4b` | `9b7feabb2406fd825e6a6207e1229046438b2c93108b1501382afd6d8dc8cac4` |
| K-3 III Monochrome | `1234567` | `f02089cea127420a2c651bac708dd8a15c5975b1278cefa6262a0f2ab3471e5a` | `d4d5eb69d9529bc6c6fe42f3607c2ed2b0fa42db60201e484d21675ad76e9ad7` | `846c3a81c1f671dcc3486e1d9598c2423304efabcdf81eaafebbabda69e156ab` | `68b8680d22a23c8aad042b988dcc14297c33b1e22b233e8f56d3fa9f7d514d1e` |
| K-3 III Monochrome | `0012345` | `27b3fdc8f70f78feb8623cae0180dd4dd3e1b1f11cc595c37b6a001dfde262e6` | `61cf713deab65a1b1a518d271eadf0c3bfcda26e0e71c5893ccddd5d3ac57f65` | `400e649439fd6a25b52c7bb1965b3001eb112d45dbda012fc4903b82e31bc9de` | `d32f62620f3464b3e8006a460aaa992ee1b218409ef06710dd28eb47e791072b` |
| K-3 III Monochrome | `12345678901234567890` | `bb0246e68de1f1cbad9ac7b3bdc8a535924a87f4cb925508212b2e877377e57d` | `eee141f1b48c2bccb3446a7e96d99ea0eb170440e37846c149932abba1892a03` | `2785b91832ea0135c72b0c26aa872ec0bf818b6f0e94756971620d419ed6776c` | `abca5f7477aa4e6a85908875dc6c503d3227e9a31bc1e939484b3eeeb207ecfe` |

## 6. 验收标准

1. 对上述每个（机型、序列号、功能）三元组，本实现的 payload 必须与向量表逐字相等。
2. 生成 PNG 必须是标准可解码二维码，解码结果为 64 个小写十六进制字符，且与该三元组的 payload 相等。
3. 相同输入重复运行必须产出逐字节相同的 PNG（确定性）。
4. 序列号规范化必须拒绝第 2 节列出的全部非法输入，且不得把 `0012345` 变成 `12345`。

## 7. 未完成验证 / 风险

- 参考项目自述：K-1 与 K-3 III 已通过原始固件 ARM 指令与原生 SHA-256 的离线验证；K-3 III Monochrome 的 12 条向量来自固件 2.20 的独立原生实现；K-1 II 的验证以样本哈希界定范围（样本容器版本字段 `0x0232`、内嵌文本写作 `Version 2.51`）。
- K-3 III（彩色）已由维护者真机确认相机可接受生成的二维码（2026-11-05）；K-1 II 与 K-3 III Monochrome 同样已真机确认（2026-11-19）。仅 K-1（初代）尚未在真机上确认扫码结果，仍需实机测试；测试失败时应先怀疑图形参数（尺寸、静区、模块大小），而不是内容算法。
- 本仓库不包含任何真实序列号、固件或二维码照片；向量使用合成序列号。
