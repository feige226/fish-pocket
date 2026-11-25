# 第三方声明

本项目的代码以 [MIT](LICENSE) 协议发布，另有几条附加限制（商用需要授权，发布改造版前要先提 issue），见 LICENSE 末尾。下面的组件不属于本项目，保留各自的许可证和版权声明。**吉祥物图片不适用 MIT**，见[吉祥物](#吉祥物不适用-mit)一节。

本仓库不包含这些组件的源码。它们在构建时下载或安装，版本钉死在 `engine/package-lock.json`、`app/project.yml` 和 `scripts/` 里。编译出的 App 会包含它们，分发 App 时要一并遵守这些许可证。

## 主要组件

| 组件 | 版本 | 许可证 | 版权方 | 用途 |
|---|---|---|---|---|
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh` 及其插件包） | 0.2.2-rc.4 | MIT | Copyright (c) 2026 DeepSeek | 引擎 |
| [nodejs-mobile](https://github.com/digidem/nodejs-mobile)（digidem 分支，上游为 [nodejs-mobile/nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile)） | 24.20.0-0 | Node.js 许可证（MIT 及其捆绑组件的各自许可证） | Node.js 贡献者等 | 内嵌 Node 运行时，以预编译的 `NodeMobile.xcframework` 下载 |
| [just-bash](https://github.com/vercel-labs/just-bash) | 3.6.0 | Apache-2.0 | Copyright 2025 Vercel Inc. | bash 解释器和内置命令 |
| [CPython](https://github.com/python/cpython)（python.org 的 iOS 构建） | 3.15.2 | PSF 许可证第 2 版（及其捆绑组件的各自许可证） | Copyright (c) 2001 Python Software Foundation 等 | 内嵌 Python 运行时，以预编译的 `Python.xcframework` 下载，含标准库和 `ensurepip` 自带的 pip |
| [FFmpeg](https://ffmpeg.org) | 9.0.2 | LGPL 2.1 或更高版本（只开 LGPL 组件） | FFmpeg 贡献者 | `ffmpeg`、`ffprobe` 命令，从官方源码编译成动态框架 `FFmpeg.framework`，有少量改动，见下文 |
| [libgit2](https://github.com/libgit2/libgit2) | 1.9.7 | GPLv2 + 链接例外 | libgit2 贡献者 | git 能力，未修改源码，静态链接 |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.10.0 | MIT | Copyright (c) 2019-2022 Miguel de Icaza 等 | 终端界面 |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 1.7.3 | MIT；随包的数学字体各有许可证（GUST 字体许可证、SIL OFL 等），见其 README 的 Fonts 一节 | Copyright (c) 2023 Computer Inspirations | 回复里的公式排版 |
| [KaTeX](https://github.com/KaTeX/KaTeX) | 0.18.7 | MIT（包括随包的字体） | Copyright (c) 2013-2020 Khan Academy and other contributors | SwiftMath 排不了的公式（带中文、`\xrightarrow`、`\boxed` 等）改由它排版，和网页版同一版本；只带 woff2 字体，`scripts/build-katex.sh` 生成 |
| [pnpm](https://github.com/pnpm/pnpm) | 11.28.5 | MIT | Rico Sta. Cruz、Zoltan Kochan 及贡献者 | 插件安装 |
| [DS Bot](https://github.com/Fei2411/DS-Bot)（`ds-bot`） | 0.3.8 | Apache-2.0 | Copyright 2026 Fei2411 and the DS Bot contributors | Bot 功能的后台，内置在引擎里 |
| [dsh-image-gen](https://github.com/shanliuling/dsh-image-gen)（`dsh-image-gen`） | 0.11.4 | Apache-2.0 | Copyright 2026 shanliuling | 生图功能的后台，内置在引擎里；网页版里的画布、图库和 Studio 是它自己的界面 |
| [Simple Icons](https://github.com/simple-icons/simple-icons) | 16.37.0 | CC0-1.0 | Simple Icons 贡献者 | Bot 连接器页面的品牌图标 |
| [page-agent](https://github.com/alibaba/page-agent)（`@page-agent/page-controller`、`@page-agent/ui`） | 1.12.4 | MIT | Copyright (c) 2026 SimonLuvRamen, Copyright (c) 2026 Alibaba Group Holding Limited | 智能体操作浏览器时读网页、点击和输入，操作时网页上的光效、指针和状态面板 |
| [ai-motion](https://www.npmjs.com/package/ai-motion) | 0.4.8 | MIT | Copyright (c) 2025 Simon | page-agent 遮罩层的动态光效 |
| [React](https://github.com/facebook/react)（`react`、`react-dom`、`scheduler`） | 18.3.1 | MIT | Copyright (c) Meta Platforms, Inc. and affiliates | 「我的应用」里的小应用用的 React |
| [Sucrase](https://github.com/alangpierce/sucrase) | 3.35.1 | MIT（打包进来的依赖 `ts-interface-checker` 为 Apache-2.0，其余为 MIT） | Copyright (c) 2012-2018 various contributors | 在手机上把小应用的 JSX、TypeScript 编译成 JavaScript |
| [WebRTC AudioProcessing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing)（WebRTC 的回声消除 AEC3） | 2.1 | BSD-3-Clause（另有 WebRTC 的专利授权，见 `PATENTS`） | Copyright (c) 2011 The WebRTC project authors | 语音通话里把她自己的声音从麦克风里消掉，未修改源码，静态链接 |
| [Abseil](https://github.com/abseil/abseil-cpp) | 20240722.0 | Apache-2.0 | Copyright The Abseil Authors | AEC3 用到的 C++ 头文件 |

Simple Icons 是上面这句话的例外：用到的 28 个图标以 SVG 文件直接放在仓库里（`app/DshIOS/Assets.xcassets/Connectors`）。CC0 只覆盖图标文件本身，各图标仍是其品牌方的商标，App 里只用来标明连接的是哪家服务。

AEC3 也是例外：`scripts/vendor-aec3.sh` 从这两个官方发布包（脚本里钉死了 sha256）里只挑出 AEC3 的源码和它包含的头文件，原样放在 `native/aec3`（`webrtc/`、`abseil/`），由 App 自己编译。许可证全文随源码放在 `native/aec3/webrtc/LICENSE`、`native/aec3/webrtc/PATENTS` 和 `native/aec3/abseil/LICENSE`。

page-agent 也是例外：`scripts/build-page-controller.sh` 把它的 page controller、遮罩层（自动操作时罩在页面上的光效和指针）、状态面板，连同遮罩层依赖的 ai-motion 和本仓库的一小段包装打成一个脚本，提交在 `app/DshIOS/Browser/PageController.js`，文件开头保留了 page-agent 和 ai-motion 的 MIT 许可证全文。没有改动它们的源码，只是在页面上加了一条样式，让遮罩层不挡用户的点按，用户随时可以接手。它的页面结构提取移植自 [browser-use](https://github.com/browser-use/browser-use)（MIT）。

React 和 Sucrase 同样不走 npm 包：`scripts/build-mini-app-runtime.sh` 把它们打成几个脚本，提交在 `app/DshIOS/MiniApps/Runtime`，每个文件开头保留了所含各包的许可证全文。没有改动它们的源码。

CPython 的完整许可证及其捆绑组件（OpenSSL、SQLite、libffi、zlib、bzip2、xz、zstd、expat、mpdecimal 等）的许可证见 [Python 文档的许可证页](https://docs.python.org/3.15/license.html)；标准库里的 `LICENSE.txt` 随 App 一起分发。

FFmpeg 按 LGPL 2.1 或更高版本使用，构建方式见 `scripts/build-ffmpeg.sh`：

- **只开 LGPL 组件。** 不加 `--enable-gpl` 和 `--enable-nonfree`，不链接 x264、x265、LAME 等外部库，构建时检查 configure 报告的许可证。H.264、HEVC 编码走系统的 VideoToolbox。
- **动态链接。** FFmpeg 的库和 ffmpeg、ffprobe 两个程序编成一个独立的动态框架 `FFmpeg.framework`，App 的其余部分只通过它导出的两个函数调用它。框架里附带 LGPL 2.1 全文（`LICENSE`）。
- **改动公开。** 为了让两个程序在 App 内作为函数运行，对 FFmpeg 源码做了少量修改：改名入口函数、不安装信号处理、不读终端、`pipe:` 协议改用当次命令的管道，以及每次运行前复位程序的全局变量。改动全部在本仓库的 `native/ffmpeg/`（`ffmpeg.patch`、`fftools-prefix.h`、`tool.c`），任何人都可以用原版或自己修改过的 FFmpeg 源码重新编译出这个框架并替换进 App。
- **源码。** 官方源码包 <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz>，构建脚本里钉死了 sha256。许可证全文见源码里的 `COPYING.LGPLv2.1` 和 [FFmpeg 的许可证说明](https://ffmpeg.org/legal.html)。
- **预编译包。** 为了省去每次构建都编译一遍，本仓库的 GitHub Release（tag 以 `ffmpeg-` 开头）里放着用上面的脚本和改动编好的同一个框架，`scripts/fetch-ffmpeg.sh` 下载它并校验 sha256。它和从源码编出来的框架内容相同，上面几条同样适用。

libgit2 的完整许可证见其仓库的 [COPYING](https://github.com/libgit2/libgit2/blob/main/COPYING)。其中的链接例外允许把未修改的库链接进其他程序并分发，只有修改库本身时才受 GPLv2 约束。

## 打进 App 的 npm 包

`scripts/build-engine.sh` 组装出的引擎目录约有 687 个 npm 包，按各包 `package.json` 的 `license` 字段统计分布如下：

| 许可证 | 包数量 |
|---|---|
| MIT | 579 |
| Apache-2.0 | 59 |
| BSD-3-Clause | 20 |
| ISC | 16 |
| BSD-2-Clause | 7 |
| 其他（0BSD、Unlicense、Python-2.0、MPL-2.0、MIT-0、BlueOak-1.0.0 各 1 个） | 6 |

另有 4 个包是双许可，已按首选许可证计入上表。

上游自带的许可证文件会随包一起打进 App。准确清单以 `engine/package-lock.json` 为准，个别包不带单独的许可证文件，以其 `package.json` 的声明为准。

需要单独留意的几项：

- **`@deepseek-ai/libreoffice-kit`（MPL-2.0）：** 只保留了很小的 JS 外壳，平台二进制、静态库和 wasm 在打包时已删除，`office-kit` 和 Office 技能也已禁用（`engine/ios.patch.yml`）。
- **`ds-bot`（Apache-2.0）：** 它的 npm 包只带 LICENSE，不带上游仓库的 NOTICE。按 Apache-2.0 第 4 条，`engine/notices/ds-bot.NOTICE`（取自上游 v0.3.8）在打包时放到 `ds-bot/NOTICE`，随 App 一起分发。原生界面只调用它的接口，没有使用它的界面代码。
- **`dsh-image-gen`（Apache-2.0）：** 上游仓库没有 NOTICE，npm 包里的 LICENSE 随包分发。打包时删掉了它的 README 截图和文档，代码没有改动。原生的设置页、对话里的图片卡片和图片标注都是 App 自己的界面，只调用它的接口；网页版里用的是它自己的界面。它的灵感库收录了以下开源内容：
  - 手绘风格手册取自 [yang0/handraw-style](https://github.com/yang0/handraw-style)（MIT），原作者 yang0 要求使用时署名，App 的生图设置页里也写明了出处。
  - 封面构图类型取自 [JimLiu/baoyu-skills](https://github.com/JimLiu/baoyu-skills) 的 baoyu-cover-image 技能（MIT）。
  - 案例集取自 [freestylefly/awesome-gpt-image-2](https://github.com/freestylefly/awesome-gpt-image-2)（MIT），只打包了提示词文字，示例图片在网页版里按需从网上加载，不随 App 分发。
- **`just-bash` 自带的 CPython（Python 许可证）：** 位于 `just-bash/vendor/cpython-emscripten`，随 just-bash 一起打包，但 iOS 上没有启用 `python` 命令。

## 吉祥物（不适用 MIT）

吉祥物图片不是本项目的原创，**不按 MIT 授权**。它们基于社区二创形象“鲸鱼娘·大肥鱼”，版权归原作者，按 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)（署名、非商业使用、相同方式共享）使用，完整协议见 [docs/design/brand/LICENSE](docs/design/brand/LICENSE)。

| 贡献 | 作者 | 来源 |
|---|---|---|
| 鲸鱼娘原始角色形象（原创角色“溟月”） | 上善无形 | [Bilibili](https://space.bilibili.com/4456176) |
| 加入 DeepSeek 元素的女仆二次设计 | ZipZipPipe | [Pixiv《AI娘化》](https://www.pixiv.net/artworks/148186519) |
| 以原始鲸鱼娘形象为基础，用 AI 重新生成表情 | sai | 本项目 |

这个协议覆盖下面的文件：

- `docs/design/brand/mascot-icon.png`
- `app/DshIOS/Assets.xcassets/AppIcon.appiconset/`、`AppIcon-Pink.appiconset/`、`AppIcon-Mint.appiconset/`、`AppIcon-Violet.appiconset/`、`AppIcon-Sticker.appiconset/`、`LaunchMark.imageset/` 和 `ShareMascot.imageset/` 里的 PNG，以及 `AppIconPreview/` 里的 `Default`、`Pink`、`Mint`、`Violet`、`Sticker` 五张
- `docs/design/brand/generated/sticker.png`
- `docs/assets/icon.png`、`docs/assets/mascot.png`
- `docs/assets/demo-widget.gif`、`docs/assets/demo-ipad.gif`（画面含 App 图标）
- `docs/promo/` 里的宣传片（画面含吉祥物）

本项目的修改：`mascot-icon.png` 以原始鲸鱼娘形象为基础，用 AI 重新生成了表情。其余文件由 `docs/design/brand/make-icons.py` 从它生成，只做了缩放、圆角、灰度和换色处理（樱花粉、薄荷绿、葡萄紫三个备选图标把蓝色换成了别的色相）；备选图标「贴纸」是用 AI 图片生成把吉祥物重画成的扁平贴纸，原图在 `docs/design/brand/generated/sticker.png`；`ShareMascot.imageset/` 里的分享海报用图另外去掉了背景。这些修改同样按 CC BY-NC-SA 4.0 发布。「简洁」一组的备选图标里，小鲸鱼（`AppIcon-Whale` 和 `AppIconPreview/Whale.imageset`）由 `docs/design/brand/make-drawn-icons.swift` 用代码画成；「字标」一组（`AppIcon-Word*` 和 `AppIconPreview/` 里同名的三张）由 `docs/design/brand/make-wordmark-icons.swift` 用代码画成，字体是 Geist Pixel、Noto Sans 和 JetBrains Mono（均为 SIL Open Font License 1.1），仓库里只有渲染出的图片，不含字体文件；「几何鲸鱼」「像素鲸鱼」（`AppIcon-Geometric`、`AppIcon-Pixel`、`AppIconPreview/` 里同名的两张，原图 `docs/design/brand/generated/geometric.png`、`pixel.png`）用 AI 图片生成。这些都不含吉祥物，按 MIT 授权。

**如果你要商用这份代码：** 先按 [LICENSE](LICENSE) 的附加条款取得作者的授权。授权只覆盖代码，不覆盖这些图片，请换掉上面的文件，或者自行取得原作者的许可。

本项目没有使用 DeepSeek 的 Logo，也和上述作者没有隶属或背书关系。

## 参考但未包含的内容

- **官方 Web UI：** `docs/webui/` 的功能清单和协议说明，以及原生界面的部分文案和行为，整理或移植自 `@deepseek-ai/*`（MIT，Copyright (c) 2026 DeepSeek）。
- **DSH Go：** AGPL-3.0。本项目参考过它的方案和协议，没有使用它的代码。
- **Agents Anywhere：** Apache-2.0，Copyright 2026 Agents Anywhere Contributors。远程控制（`app/DshIOS/Remote/`）对接它的服务器接口，事件合并、斜杠指令和交互表单的处理规则参照它公开的 iOS 客户端重新实现。App 不捆绑它的任何组件，电脑端和服务器由用户自己安装或部署。
