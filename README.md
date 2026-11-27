# YiPlayer — 精简版视频播放器空壳（v1）

Bundle ID `com.yiplayer.app` · SwiftUI · iOS 17+ · 无外部 Swift Package 依赖。
参考：tvbox-silicon（Yingxia）、MarcoMovie（“marcotv”最可能的所指）、
NOCTRA（noc.zijiu522.cn）、Rex（rexnow.tv）。调研见 `research-tvbox-marcotv.md`
和 `research-noctra-rex-cat.md`。**本仓库不含任何片库，也不内置任何源。**

## v1 能做什么

- **订阅导入**：粘贴 URL 或本地文件导入。支持 TVBox JSON（type 1 / type 4）
  和猫源（`.js` / `.js.md5`）。多订阅合并；刷新失败保留上次可用配置，
  不会把好好的片库清掉；相对 URL 按订阅的最终地址解析。
  - 默认测试猫源：`https://9280.kstore.vip/cat/index.js.md5`
- **猫源**：JavaScriptCore 有界宿主（`Runtime/CatJSRuntime.swift`），
  只暴露 `Spider` / `net.req` / `net.json` / `proxyUrl` / `page` / `md5` /
  `sha256`，请求体上限 6 MiB。不是完整 Node.js，不是 Fastify 服务端。
- **首页 / 发现 / 详情 / 搜索**：接着看（断点续播）、海报墙、分类
  （电影 / 连续剧 / 综艺纪录 / 动漫 / 短剧）、详情（海报、演员、简介、
  线路胶囊、选集按 50 集分组）、跨源搜索合并。
- **播放**：AVPlayer 原样透传。HEVC / HDR10 / HLG / DV5 / DV8 不转码、
  不调色，所以不会偏色；设备播不了 HDR 时 AVPlayer 会拒播
  （CoreMedia -17223），界面会如实提示，而不是偷偷降成 SDR。
  0.5x–4x 倍速、双击 ±10 秒、左半屏亮度、长按 2 倍速、跳过片头/片尾、
  音轨/字幕选择、选集、线路切换。
- **HLS 相对路径**：本机 loopback 代理（`Runtime/HLSLoopbackProxy.swift`，
  `127.0.0.1`，NWListener）重写 `.m3u8` 分片 / KEY 的相对地址，
  和 Yingxia / MarcoMovie 的做法一样。

## v1 不能做什么（请先读这段）

- **py 源不能播。** iOS 没有 Python 运行时。`YiCore/PySource.swift`
  里是 `EmbeddedPythonHost` 桩：任何 py 源调用都会返回
  “iOS 暂不支持 Python 运行时（v2 嵌入 CPython，参考 Yingxia
  python-runtime-plan）”。接口已按仓库根目录的 **pd.py（懂片帝，
  dongpian17.com，/v1/* REST + HMAC-SHA256 签名）** 接好：
  分类 全部/电影/剧集/短剧/动漫/综艺 × 日/周/月/总榜，详情取
  `/v1/catalog/<vid>`，播放是 `<token>` 或 `<token>@@<线路ID>`，
  经 `/v1/playback/resolve` + `resolve-line` 二次解析，官方线路
  优先、4K 排前，匿名游客会话自动登录。注意这不是 555.py 的
  MacCMS 接口（没有数字 vod_id，也没有 `{id}-{sid}-{nid}`），
  v2 换成真 CPython 宿主时调用方不用改，但宿主还要提供 pd.py
  依赖的 `base.spider` 包和 `requests`。
- **9280 那个猫源包有限制。** `index.js.md5` 只有一行 MD5
  `d8e69da8c37a29afe50fdc8de9dbf268`；`index.js` 本身（17,087 行）
  是 CatPawOpen 风格的 **Fastify 服务端 bundle**，不是
  websiteBundle（aaaaa2780009 那个 65,702 行、`// ====慕猫源` 的包
  才是）。v1 会先校验 MD5，再交给 JS 运行时；运行时认出它是服务端
  bundle 后**不会强行执行**，而是明确报错说明限制
  （其 SOURCE_ORDER 为 douban,360,renren,hanjutv，但回退成可播源
  未在 v1 实现，见 BUILD_NOTES.md）。
  一个真正的 websiteBundle 包走正常 Spider 路径。
- **MKV / AV1 等 AVPlayer 打不开的容器**：v1 没有 FFmpeg 重封装
  （Yingxia 的 mkv-playback-plan 路线），这类流会直接报错。
  这是 v2 的工作。
- **未签名 IPA 装不到手机上就能用。** CI 产物是未签名包，装机要
  自己签名（见下）。

## 导入订阅源

1. 打开 YiPlayer → 设置 → 订阅源。
2. 粘贴订阅地址（默认已填 9280 测试猫源），点“导入”；或点“本地文件”
   选一个 `.json` / `.txt` / `.js` 文件。
3. 回到首页 / 发现，就能看到该订阅的片库。点一部片子 → 选集 → 选线路 → 播放。
4. 导入失败时旧订阅不会被清掉，错误会显示在订阅下面。

## 在 Mac 上本地构建

需要 macOS + Xcode 16+（Linux 编不出 IPA）。

```bash
cd YiPlayer
brew install xcodegen
xcodegen generate
open YiPlayer.xcodeproj   # 选 YiPlayer-iOS，真机或模拟器运行
```

## GitHub Actions 免费构建（未签名 IPA）

工作流：`.github/workflows/build-ios.yml`，手动触发（Actions → Run workflow）。

```text
macos-15 → brew install xcodegen → xcodegen generate
→ xcodebuild -scheme YiPlayer-iOS -sdk iphoneos -configuration Release
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive
→ 打包 YiPlayer-unsigned.ipa → artifact YiPlayer-unsigned-ipa（保留 14 天）
```

不使用任何 Secrets，不签名。

## 安装未签名 IPA

用电脑 + 免费 Apple ID 签名 7 天（cider / Sideloadly 二选一）：

```bash
cider account login
cider sign YiPlayer-unsigned.ipa --apple-id --install --refresh
```

装好后在手机“设置 → 通用 → VPN 与设备管理”信任自己的 Apple ID。
**Apple ID 密码只在 cider / Sideloadly 里自己输，永远不要发在聊天里。**

## 结构

```text
YiPlayer/
  project.yml                 XcodeGen（生成 YiPlayer.xcodeproj，无 SPM 依赖）
  App/                        YiPlayerApp / Home / Discover / Detail / Search
                              / Settings+Subscription / PlayerView / Info.plist
  YiCore/                     Subscription / Source / VideoItem / Episode
                              / PlayLine / CatSource (+JsonSource) / PySource
                              / HistoryStore
  Runtime/                    CatJSRuntime (JavaScriptCore 有界宿主)
                              HLSLoopbackProxy (127.0.0.1 m3u8 重写)
  Player/                     YiPlayerView (AVPlayer + HUD + 手势)
  .github/workflows/build-ios.yml
  BUILD_NOTES.md              所有假设与未验证项（必读）
```

## 还需要用户提供什么

- **pd.py 的 `base.spider` 包**：pd.py 开头 `sys.path.append('..')`
  依赖上一级目录的 `base` 包，v2 嵌入 CPython 时要一起提供；
  v1 不执行它，所以不影响构建。
- **catvodsub.txt 已在仓库里**：根目录的 `catvodsub.txt` 只有
  9280 那个猫源地址（`https://9280.kstore.vip/cat/index.js.md5`），
  如果以后还有别的订阅地址，加到这个文件里就行。

## 许可证注意

tvbox-silicon 和 MarcoMovie 都是 GPL-3.0-only。本仓库是**从头写的
空壳**，没有复制它们的代码；但如果你之后往里面抄了它们的代码，
即使放在私有仓库，对外分发 IPA 时也要按 GPL 提供对应源码并保留署名。
