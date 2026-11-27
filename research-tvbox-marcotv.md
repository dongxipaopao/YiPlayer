# YiPlayer 调研 — tvbox-silicon / marcotv（2026-11-27）

来源：子代理只读调研，未构建、未推送。

## 结论
- tvbox-silicon / Yingxia：可直接借鉴的 iOS 原生路线。SwiftUI + AVPlayer，订阅是 TVBox JSON，猫源靠 Node.js，py 源在 iOS 上是在建工程，不是现成能力。
- “marcotv”有歧义，必须先确认：
  - Pilipala9919/MarcoTV：Android TV 桌面启动器，不是播放器，没有猫源/py源/播放内核，只能借鉴界面（卡片、焦点动画、紫色叠卡）。
  - Pilipala9919/MarcoMovie：这才是播放器，多端自适应，iOS 端是 Flutter + AVPlayer/libmpv 双引擎 + QuickJS + 原生 CPython。用户大概率想指这个。
- HDR / 4K / 杜比视界不偏色的最短路径：只用 AVPlayer，不转码、不调色。HEVC/HDR10/DV5/DV8 原样透传给 VideoToolbox 硬解；只有 AVPlayer 打不开的容器（MKV 等）才用 FFmpeg 重封装成 fMP4 HLS 再喂 AVPlayer。不要以 libmpv/VLC 为主播放器——Yingxia 明确否决了，MarcoMovie 也只把它当回退。

## tvbox-silicon（Yingxia）
- https://github.com/jo32/tvbox-silicon ，Swift + SwiftUI，iOS/iPadOS 17+、tvOS 17+、macOS 15+；652 stars，GPL-3.0-only，0 releases。
- 构建：Xcode + XcodeGen（project.yml → TVBox.xcodeproj，schemes TVBox-macOS / TVBox-iOS / TVBox-tvOS），JDK 19 + Maven，uv；Scripts/build-java-host.sh、build-script-host.sh、build-python-host.sh，再加 build-apple-ffmpeg.sh、build-apple-libass.sh。
- 结构：App/（HomeView、DiscoveryView、DiscoverDetailView、PlaybackView、PlayerView、MobilePlayer、LiveGuide、DownloadsView、CatPawSignInView 等）；Packages/TVCore/（订阅、网络、目录、本地化、运行时边界；Sources/TVCore/ScriptAssets/sites/ 是常用源的 QuickJS 轻量移植）；Runtime/（AppleRuntime 内嵌 JVM、JavaHost、NodeHost main.mjs/worker.mjs/agents.mjs、ScriptHost host.mjs、PythonHost、sandbox）；Vendor/（DEX 解释器、QuickJS-ng、FFmpeg）；Docs/（DEVELOPMENT.md、INSTALL.md、on-device-runtime-status.md、python-runtime-plan.md、mkv-playback-plan.md、subtitles.md 等）。
- 订阅：TVBox JSON，按 URL 导入，可多订阅合并（SubscriptionMerge），每个源保留来源；失败刷新不抹掉上次可用配置；保留 ext、spider、规则等插件字段；相对 URL 按订阅最终响应地址解析。
- 源类型：type 1 / type 4 标准 JSON 源；type 3 插件源（JAR、JavaScript、Mac 上还有 Python）。
- 猫源：Mac 捆绑 Node.js 跑 JS； iOS/tvOS 下载 jo32/nodejs-mobile 的 Node.js 26 LTS（无 JIT），Scripts/fetch-node-mobile.sh 校验 SHA-256；另一条 JS 路径：ScriptAssets/sites/ 轻量移植先在 QuickJS 上跑，原插件做回退。
- .md5 处理：在已读 README / DEVELOPMENT.md 里没有找到 .md5 订阅的解析说明（只在 DEX 检查处提到 inline MD5 fingerprint）。不能断言 app 是“去 .md5 后缀取 index.js 再校验哈希”——构建阶段对 TVCore 订阅解析代码核实。
- 直播：M3U / TXT 播放列表、分组、搜台、收藏；Bilibili / 斗鱼 / 虎牙 / 抖音直播间并列。
- py 源：macOS 可用（实验性），CPython 3.12 + requirements.txt，LocalJarHost 独立进程跑 Runtime/PythonHost/host.py，受 spider.sb 沙箱约束。iOS/tvOS：DEVELOPMENT.md 明确写“没有 Python”，py 源显示“This source requires a Python runtime, which is not available on this platform.”；在建方案 Docs/python-runtime-plan.md（2026-10-25，phase 1 done，Issue #125）：嵌 CPython 3.14（BeeWare Python-Apple-support），动态 Python.framework，C 桥 Runtime/AppleRuntime/Native/ApplePython.c 的 TVPythonRequest，EmbeddedPythonHost + SerializedPluginWorker；库只含 requests、bs4、pyquery、pycryptodome、lxml；包增约 66–68 MB/平台，模拟器首次冷启动约 18s；133 个 py 源抽测：Mac 37 个全过、iOS 模拟器 35–36 个、tvOS 36 个。
- 播放：AVPlayer + AVKit，HLS、0.5x–4x 倍速、手势、画中画、Mac 独立播放窗口；CENC 加密 MP4 资源加载器、离线下载走 loopback server。
- MKV/AVI/FLV/WMV/RMVB：AVPlayer 只开 MP4/MOV/TS/HLS，用小 FFmpeg（LGPL，只含 demuxer + MP4 muxer + 必要解码器，dav1d 解 AV1）在设备上重封装成 fMP4 HLS，经 RemuxServer（127.0.0.1）喂 AVPlayer。拷贝优先：H.264、HEVC（8/10-bit、HDR10、HLG、DV5/DV8）、AAC、AC-3、E-AC-3、FLAC、ALAC 原样进分片，不解码、不重编码；只有 Apple 解不了的才 libavcodec 解码 + VideoToolbox 重编码；DTS/TrueHD/Opus 等转 AAC（5.1 保留）。HDR 在不支持的设备上：AVPlayer 会拒播（CoreMedia -17223），此时才把 HDR10/HLG 经 VideoToolbox/swscale 色调映射到 8-bit BT.709 SDR，DV5 保持原样。明确否决第二播放器（KSPlayer/VLCKit）。

## MarcoMovie（“marcotv”最可能的所指）
- https://github.com/Pilipala9919/MarcoMovie ，GPL-3.0-only；1,343 stars，668 commits，220 releases；版本 iOS 0.7.10、Apple TV 0.1.1、Android 手机 0.7.2 / 电视 0.6.2。
- 定位：多端自适应播放器，不内置任何影视资源，首次打开需用户自行导入配置。
- 结构：android-tv/、android-mobile/、lite/ 各自独立原生 Android 工程；shared/ 跨平台共享层：catpaw/（DRPY 引擎、host.cjs、node_bridge.c、各站点适配器）、script-host/；flutter/ 跨平台工程（Windows/macOS/iPhone/iPad/HarmonyOS NEXT），Flutter 3.38.9，media_kit，packages/quickjs_engine/；tvos/ 原生 Apple TV 工程：SwiftUI + AVKit + QuickJS-NG，Sources/CQuickJS/、Sources/MarcoTVCore/（Parser/、Network/、JavaScript/、Storage/）；docs/（BUILD.md、DECODERS.md、USER_GUIDE.md、catvod-profile.md、native-python-source-profile.md、subscription-compatibility-2026-11-07.md、js-spider-compatibility.md、ios-source-acceptance.md、python-host-startup.md 等）；scripts/、.github/workflows/build-multiplatform.yml。
- 导入：手机/平板/桌面原生输入框、剪贴板一键粘贴、本地 JSON 文件选择；电视端局域网手机扫码推送、手动输入、WebDAV 同步；配置备份/还原，多端 marco-movie-sync v2。
- 解析器（tvos/）：ConfigDecoder + CmsParser + LiveCatalogParser，支持 UTF-8 BOM、UTF-16LE/BE、GZIP、JPEG/PNG 隐写、AES-128-CBC hex 配置、Base64、JSON 注释/尾逗号、MacCMS JSON 与 XML、vod_play_list、M3U/TXT 直播。
- 猫源/JS 源：shared/catpaw/ 是 pinned 的 DRPY 引擎（drpy-core.js、drpy-worker.cjs 等）；docs/catvod-profile.md 说明这是有界的、app 自有的 CatVod ES 模块子集，不是完整 FongMi 宿主：实现 Spider、net.req/net.json、proxyUrl、page、md5X/sha256X，6 MiB 请求体上限，不实现 Local 持久化、WebSocket、WASM、AES/DES/RSA 等；QuickJS 宿主：tvOS 是 QuickJS-NG 0.14.0（CQuickJS），Flutter 是 quickjs_engine。
- HLS 相对路径：LocalHeaderProxyServer（NWListener，127.0.0.1）重写 .m3u8 变体/分片/#EXT-X-KEY URL；网盘走 NetdiskRangeProxyServer。
- py 源：Android 内置 CPython 3.11.17（Chaquopy + JNI 桥）；iOS：共享的原生 Python 加载器，一个源一个专用解释器，保留 base.spider.Spider，requests.Session 走 app 自有传输；包限制 256 文件、单文件 2 MiB、总计 6 MiB；同名模块分解释器隔离；不能加载原生 wheel；已验证 Crypto 库与原生 lxml port；iOS 验证包 35,315,507 字节。
- 播放：iOS/iPadOS 原生 AVPlayer（画中画/AirPlay 2）+ libmpv 双引擎自动回退；Apple TV 原生 AVPlayer（HLS / 4K HDR10 / 杜比视界）；详情页统一纯文字媒体规格徽章（4K / HDR10+ / DV · ATMOS）；手势：双击自定义、左右滑快进、左半屏亮度、右半屏音量、长按 2.0x 倍速等；iOS 26 有液态玻璃影院 HUD。
- 构建 iOS：Flutter 端 flutter build ios --release --no-codesign；tvOS 原生端 python3 tvos/prepare_tvos.py → xcodebuild -project tvos/RunnerProject/MarcoMovieTV.xcodeproj -scheme MarcoMovieTV -sdk appletvos -configuration Release CODE_SIGNING_ALLOWED=NO → python3 tvos/patch_tvos_ipa.py … --ipa …-unsigned.ipa。这套“未签名 IPA 打包脚本”正是 YiPlayer 可直接参考的模板。

## MarcoTV（如果用户字面意思就是它）
- https://github.com/Pilipala9919/MarcoTV ，152 stars，121 commits，39 releases，当前 0.21.3；GPL-3.0-only；Java，Android 6.0/API 23 起。
- Android TV 桌面启动器：横向卡片、连续焦点动画、4K 60fps 动态壁纸、Magic Desktop、卡片长宽高/圆角/封面自定义、手机扫码传图/无线投屏、最近任务、本地备份、时钟屏保。
- 没有播放器、没有猫源/py 源、没有订阅导入。对 YiPlayer 只能借鉴：紫调三层叠卡品牌视觉、焦点动效、卡片自定义、设置分栏、壁纸/屏保。

## 给精简版 YiPlayer 的借鉴 / 跳过
借鉴：Yingxia 分层 SwiftUI App/ + 核心包 TVCore + Runtime/ + Scripts/，压缩为 App/ + YiCore（订阅模型、CmsParser、源调度、历史/收藏本地存储）+ Runtime/（JS 宿主、py 宿主二期）；订阅导入“URL/粘贴/本地文件 + 多订阅合并 + 失败保留上次可用 + 相对 URL 按订阅地址解析”，SubscriptionMerge + SourceHealth；猫源 v1 先走 Yingxia 轻量路线 QuickJS + Node.js（jo32/nodejs-mobile，无 JIT），不要一上来写 JVM/DEX，MarcoMovie shared/catpaw/ DRPY + catvod-profile.md 的有界 API 清单可作 JS 宿主能力边界；py 源 v1 可降级，先只支持 JSON/type 1/4 + JS 猫源，明确标“iOS 暂不支持”或走 MarcoMovie 原生 CPython 加载器路线，真要做按 Yingxia python-runtime-plan.md 嵌入式 CPython 3.14 + C 桥，预算 +60MB、首次冷启动十几秒、只含 requests/bs4/lxml/pycryptodome；播放只用 AVPlayer，MKV 等按 mkv-playback-plan.md FFmpeg 重封装 → fMP4 HLS → loopback server，HEVC/HDR10/DV 原样拷贝，eligibleForHDRPlayback 为假时才降级 SDR；HLS 相对路径必须有本机 loopback 代理重写 m3u8/分片/KEY，否则猫源相对分片播不出；详情/选集/搜索：每源独立书架、全局跨源搜索、选集、自动下一集、片头片尾跳过、继续观看，50 集分组、线路胶囊、正序/倒序、规格徽章、手势；未签名 IPA / 免费构建：Yingxia build-ios.yml 草稿（macos-15、JDK 19、XcodeGen、CODE_SIGNING_REQUIRED=NO）+ MarcoMovie .github/workflows/build-multiplatform.yml + tvos/patch_tvos_ipa.py。
跳过：Yingxia 的内嵌 JVM + DEX 转换 + unidbg/Unicorn、云盘、音乐、漫画、小说、DLNA、直播平台账号、Services/ Workers、官网；MarcoMovie 的多端 Android TV/手机/Lite、HarmonyOS、Windows/macOS Flutter、网盘扫码、WebDAV 同步、多端同步 v2、DRPY 33 条专有路由、Anime4K、磁力；MarcoTV 的桌面启动器逻辑，只借视觉。
风险：.md5 订阅解析方式未证实，构建阶段必须读 TVCore 订阅解析源码再定；py 源 iOS 是最大成本，两家都证明可行但都未宣称“任意源都行”，v1 建议先不上 py，只留接口与“暂不支持”提示；许可证：两家都是 GPL-3.0-only，YiPlayer 若复制其代码，即使放私有仓库，对外分发 IPA 时也要按 GPL 提供对应源码并保留署名；构建前提：iOS 真机/未签名 IPA 仍需 macOS + Xcode（GitHub Actions macos runner 可免费做），本地 Linux 编不出 IPA；签名仍需用户自己的 Apple ID（cider/Sideloadly，免费签 7 天）或开发者证书。
