# BUILD_NOTES.md — 假设与未验证项（v2.1）

本文件列出构建 YiPlayer v1 + v2 + v2.1 时做的每一个假设和每一条未验证的说法。
**v2.1 没有在 Xcode / 真机上构建或测试过** —— 本机是 Linux VM，没有
macOS / Xcode；只做了 YAML 语法、Swift 括号平衡、Python/JS 语法、
以及文件引用完整性等静态检查（见“已验证”）。
v1 的构建是真的（GitHub Actions run #4 成功，265 KB 未签名 IPA，
见“v1 历史”）；v2 的构建也是真的（Actions run #22 成功，23.4 MB
未签名 IPA，见“v2 构建实录”），用户已在 LiveContainer 里装了 v2.0.0，
报了 4 个问题，v2.1 就是针对这 4 个问题修的（见“v2.1 改了什么”）。

## v2.1 改了什么（相对 v2）

用户在 LiveContainer 里装了 v2.0.0 后报了 4 个问题，v2.1 逐个修：

- **根因 A：Python 初始化失败（错误码 4）——标准库根本没进包。**
  证据（实测 BeeWare 3.13-b18 的 `Python-3.13-iOS-support.b18.tar.gz`，
  本机解包验证）：标准库在 xcframework **根目录**的 `lib/python3.13`
  （2,512 个文件，`os.py`、`encodings/__init__.py` 都在那）；设备扩展
  模块在 `ios-arm64/lib-arm64/python3.13/lib-dynload/`（207 个 `.so`，
  含 `_socket`、`_ssl`、`_hashlib`）；`Python.framework/` 里**只有**
  二进制 + 头文件 + Info.plist。`PyConfig` 有 `stdlib_dir` 字段
  （`cpython/initconfig.h` 第 198 行）和 `platlibdir`（第 193 行）。
  旧路径（v2.0.0 错的） vs 新路径（v2.1）：
  | | 旧（v2.0.0） | 新（v2.1） |
  |---|---|---|
  | 标准库 | `<Python.framework>/lib/python3.13`（不存在） | 包内 `python-stdlib/python3.13` |
  | 扩展模块 | 未加入搜索路径 | `python-stdlib/python3.13/lib-dynload` |
  | 打包方式 | 只拷 `.framework`（Xcode 行为） | `Scripts/fetch-python.sh` 把 `lib/python3.13` + 设备切片 `lib-dynload/*.so` 拷到 `vendor/python-stdlib/`，project.yml 以 folder reference 打进包 |
  改动：`Scripts/fetch-python.sh` 重写（下载后分阶段打包标准库，剪掉
  `test` / `idlelib` / `tkinter` / `turtledemo` / `ensurepip` /
  `lib2to3`——与 Yingxia 的 python-runtime-plan 剪裁清单一致；缺
  `os.py` / `encodings` / `_socket` / `_ssl` 就大声失败；本机已用预置
  tarball 测过全新下载与缓存命中两条路，均分阶段 615 个文件 / 28 MB）；
  `project.yml` 加 `- path: vendor/python-stdlib` folder reference
  （CI 缓存键含 `Scripts/fetch-python.sh`，改脚本即失效缓存、下次重下）；
  `Runtime/PythonHost/ApplePython.h/.c` 重写初始化（新 6 参签名，
  显式设 `config.stdlib_dir`，`dynloadDir` 加进 `module_search_paths`，
  失败时把 PyStatus 的 `err_msg` 和试过的路径记进 `YiPythonLastError()`）；
  `YiCore/PySource.swift` 传新参数，初始化前先校验包内 `os.py` 是否存在，
  失败信息里带上具体原因，不再只剩“错误码 4”。
  参考来源：Yingxia `Docs/python-runtime-plan.md`（全文读过，2026-11-27；
  它把每个扩展模块转成独立 `.fwork` 框架——BeeWare 包里实际没有 `.fwork`
  文件，`.so` 直接放在 lib-dynload 里，YiPlayer 先用原样 `.so`，只在真机
  证明 `.so` 加载失败时才考虑 Yingxia 的重打包做法）。

- **根因 B：Node“未包含”——代码找错了目录。**
  证据：v2.0.0 的 IPA 清单证实 `host.mjs` 与 `worker.mjs` 在包根目录
  （`Payload/YiPlayer.app/host.mjs`），但 `NodeHost.swift` 的
  `nodeHostDirURL` 去找 `Bundle.main.resourceURL/nodehost/` 子目录，
  该目录不存在，所以 `isAvailable` 恒为 false。
  改动：`nodeHostDirURL` 改成包根目录（`Bundle.main.resourceURL`）。
  `host.mjs` 用 `new URL('./worker.mjs', import.meta.url)` 加载 worker，
  是相对自身位置的相对引用——两个文件都在包根，引用不断。
  启动失败时错误里带上实际查过的目录、入口与控制文件路径。
  参考来源：tvbox-silicon `Runtime/NodeHost/` 目录清单（只有
  `agents.mjs` / `main.mjs` / `worker.mjs` 三个文件，2026-11-27 读过）。

- **首页红色 "cancelled"（C）**：v2.0.0 只 catch 了 `CancellationError`，
  但被取消的 URLSession 任务抛的是 `URLError(.cancelled)`，
  `localizedDescription` 就是裸的英文 "cancelled"，落进 `lastError`
  显示出来。改动：`YiCore/Source.swift` 加共享 helper
  `isCancellation(_:)`（CancellationError / URLError .cancelled /
  NSUserCancelledError / 文本本身就是 "cancelled"）与
  `displayableErrorMessage(_:)`（取消返回 nil，含 "cancelled" 的文案
  也返回 nil）；Home / Discover / Search / Detail 全部走这两个 helper；
  首页空状态的“导入订阅源”原来是点了没反应的样式文字，现在是真按钮，
  点了跳到设置页（`YiPlayerApp.ContentView` 监听
  `.yiplayerShowSettings` 通知切 tab）。

- **设置页重做（D）**：订阅地址框下方放全宽显眼的“导入订阅”主按钮
  （地址为空禁用，导入中转圈）；“已导入的订阅”单独成区；新增**应用内
  文件浏览（主路径）**：列出 Documents / imports / spiders 里的
  `.json` / `.js` / `.py` / `.txt`（含 `.md5`），按修改时间倒序，点一下
  就导入，左滑删除，带刷新按钮，底部小字说明文件放法；系统文件选择器
  保留为次要按钮；粘贴导入、猫源站点选择、播放说明、本机数据保留；
  “关于”更新到 v2.1.0。导入逻辑抽成共享的 `importParsedFile(at:fileName:)`
  （应用内浏览与选择器复制后共用）。

- **诊断能力（E）**：Python 初始化失败时错误里带 PyStatus 的 `err_msg`
  和试过的路径；Node 启动失败/超时时带实际查过的目录、入口与控制文件路径。

- **版本（F）**：2.1.0 / build 3（project.yml 与 Info.plist 同步）。

- **参考代码阅读（用户要求）**：2026-11-27 读了用户 GitHub 上两个 fork
  的相关部分——tvbox-silicon 的 `Docs/python-runtime-plan.md` 全文与
  `Runtime/NodeHost/` 目录清单；`dongxipaopao/marcotv` 是 Android
  TV 启动器（不是播放器），没有可借鉴的播放器/源代码；上游
  MarcoMovie 的 `docs/native-python-source-profile.md` 当时抓取返回
  HTTP 503 未读到，Python 加载部分沿用 2026-11-27 的调研结论。
  **许可证**：两个项目都是 GPL-3.0。v2.1 只借鉴设计与做法（标准库分
  阶段打包、Node 控制协议、设置分区思路），YiPlayer 的代码是原创实现，
  没有整段复制它们的代码；如果之后往 YiPlayer 里抄了它们的代码，
  对外分发 IPA 时要按 GPL 提供对应源码并保留署名。

- **v2.1 仍未验证（等 Actions 构建 + 真机测试）**：`vendor/python-stdlib`
  文件夹引用是否原样打进包（`spiders/` 文件夹引用在 v2 已验证可行，
  同一机制）；包内 `.so` 在真机上是否加载成功（若失败，改走 Yingxia
  的 `.fwork` 框架化路线）；9280 bundle 的 `/config` / `/play` 返回
  形状仍是按 CatPawOpen 惯例推断；py 冷启动时间与包体；ATS 对
  `http://www.y456y.com` 在 v2.1 是否真的放行（v2.0.0 测试时用户未再
  报 ATS 错误，但也没有明确确认放行）；LiveContainer 下应用内文件
  浏览是否好用。

- **v2.1 构建实录**：run #36（workflow_dispatch，head d07afd5）
  在 `Fetch Python-Apple-support` 一步失败：`curl
  https://api.github.com/repos/beeware/Python-Apple-support/releases`
  返回 403（curl exit 56）——共享 Actions 跑者的未认证 API
  限额（60 次/小时/IP）被耗尽；v2.0.0 时缓存命中所以没触发。
  修复：`Scripts/fetch-python.sh` 在有 `GITHUB_TOKEN`（Actions
  每轮自带）时用 `Authorization: Bearer` 调 API；写成 if/else 而
  不是空数组（该脚本跑在 bash 3.2 下，`set -u` 时空数组展开会
  报错）。已推送，待下一次构建验证。
- **run #37（run 46012889503，push，head 7c4e7c7）成功**：
  YiPlayer-unsigned-ipa 30,854,790 字节（artifact），IPA
  31,357,817 字节，sha256
  `f1e76c8ddd6a27080bcbd5cca6923127efebbde38b351bb16f5a1d32d96a5228`，
  v2.1.0 build 3，iPhone+iPad。IPA 内已验证：`python-stdlib/
  python3.13/os.py` 与 `lib-dynload/_socket.cpython-313-iphoneos.so`
  都在包内（根因 A 已修）；`host.mjs`/`worker.mjs` 在包根目录
  （根因 B 已修）；Frameworks/NodeMobile.framework 与
  Python.framework 都在。已归档进 YiPlayer_ipa。
- **run #38（workflow_dispatch，head e5c0858）又在同一步失败，
  同样 403**：原因不是脚本——`GITHUB_TOKEN` 默认不会自动进入
  shell 步骤的环境变量，脚本里的 `${GITHUB_TOKEN:-}` 始终为空，
  所以还是未认证调用；#37 只是恰好分到了有限额的跑者 IP。
  真正的修复是 workflow 里给 Fetch Python 一步加
  `env: GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`（已改，未验证，
  下一次构建见分晓）。

## v2 改了什么（相对 v1）

- **py 源成真了**：`Runtime/PythonHost/`（`ApplePython.c/.h` C 桥、
  `spiders/_yi_bridge.py`、`spiders/base/` 最小 `base.spider`、
  `spiders/pd.py` 522 行拷贝、纯 Python `requirements.txt`）+
  `YiCore/PySource.swift` 重写（`EmbeddedPythonHost`，按 pd.py 真实接口
  调 `homeContent` / `categoryContent` / `detailContent` /
  `searchContent` / `playerContent` / `init`）。Python 框架不在仓库里，
  由 `Scripts/fetch-python.sh` 在 CI 下载（BeeWare 3.13，
  GitHub API 解析资产名，找不到就大声失败）。框架缺失时仍保留
  v1 的 “iOS 暂不支持 Python 运行时” 提示（仅限框架缺失时）。
- **猫源成真了**：`Runtime/NodeHost/`（`NodeHost.swift`、
  `NodeBridge.h/.mm`、`host.mjs` / `worker.mjs` 自写控制协议，
  按 tvbox-silicon 的 NodeHost 协议和 CatPawOpen bundle 格式）+
  `YiCore/CatSource.swift` 改写：`.md5` 校验后，服务端 bundle
  写进 Application Support，用内嵌 Node.js 26 在 127.0.0.1 上起
  Fastify 服务，走 `/spider/<站点>/{init,home,category,detail,play,search}`；
  websiteBundle 仍走 JavaScriptCore。Node 框架由
  `Scripts/fetch-node-mobile.sh` 在 CI 下载（jo32/nodejs-mobile
  26.13.0，SHA-256 校验，事实数据来自 tvbox-silicon 的公开脚本）。
- **首页不再空着**：`SubscriptionStore` 首次启动自动种入懂片帝
  （py）和 9280 猫源；`HomeView.loadHome` 依次试每个源，第一个
  有内容的胜出；`DetailView.play` 真正用选中的线路；
  `DiscoverView` 的分类按源来，py 源有日/周/月/总榜切换；
  `SourceRunner` 加了 `categories()` 和带 filter 的 `category()`
  （必须是协议方法，不能只是 extension 方法——否则 `any SourceRunner`
  调用时永远走默认实现，见 Source.swift 注释）。
- **导入修好了（LiveContainer）**：粘贴导入（文本框 + 剪贴板按钮）；
  文件导入允许 `.json` / `.javascript` / `.pythonScript` /
  `.plainText` + `UTType.data` 兜底，选中的文件先复制进
  Documents 再读，按扩展名分流（`.json` TVBox JSON、`.js` 猫源、
  `.py` py 源、`.txt` 按内容判断），失败显示具体原因。
- **ATS**：`NSAllowsArbitraryLoads = true` + `NSAllowsLocalNetworking = true`，
  Info.plist 和 project.yml 各一份。另见下面的“ATS 之谜”。
- **图标**：`YiPlayer.xcassets` 接进工程，`ASSETCATALOG_COMPILER_APPICON_NAME:
  AppIcon`（v1 删掉这两项只是因为当时没有 xcassets）。
- **工作流**：加了运行时下载（`vendor/` 缓存）、纯 Python 依赖安装
  （`.so` 检查）、根目录 pd.py 同步；触发路径加了 `Scripts/**`、
  `Runtime/**`、`**.py`、`**.mjs`。
- **v1 遗留 bug 修掉**：首页只试第一个源；详情忽略选中线路；
  取消的 `.task` 被当成错误显示红字 "cancelled"（这就是用户在
  LiveContainer 里看到的首页红字——是设计好的诚实提示，不是崩溃，
  但取消不应该显示）；`HomeView` / `DetailView` / `DiscoverView`
  现在都忽略 `CancellationError`。

## 已验证（在本机上，v1 + v2）

- `project.yml` 和 `.github/workflows/build-ios.yml` 的 YAML 语法
  （`python3 -c yaml.safe_load` 通过）。
- 全部 Swift 文件括号 / 花括号平衡（脚本检查通过）。
- `App/Info.plist` 可解析（plistlib），含 `NSAllowsArbitraryLoads: true`
  + `NSAllowsLocalNetworking: true`，版本 2.0.0 / build 2。
- `Runtime/PythonHost/spiders/_yi_bridge.py`、`base/spider.py`、
  捆绑的 `pd.py` 可 `python3 -m py_compile`（如本机有 python3）。
- `Runtime/NodeHost/host.mjs`、`worker.mjs` 可 `node --check`（如本机有 node）。
- `Scripts/fetch-python.sh`、`fetch-node-mobile.sh` 的 `sh -n` 语法检查。
- project.yml / 工作流引用的每个文件都在仓库里（`vendor/` 两个
  xcframework 除外——它们是 CI 生成的，不提交；`xcodegen generate`
  时缺失会直接失败，见上）。
- 2026-11-27 静态审计（v1）修掉的构建硬错：`onLongPressGesture`
  的 `onPressingChanged:` 标签、`NWListener(..., on: .loopback)` 类型、
  `xcodeVersion: "16.0"` 校验、空 `CODE_SIGN_ENTITLEMENTS`、
  不存在的 AppIcon / AccentColor 引用。审计还修了播放链：
  `CatJSRuntime.callSpider` 现在解析 `playerContent` 返回的
  `url` 成一条 PlayLine；`JsonSource.videoItem` 现在按 `$$$` 解析
  `vod_play_from` / `vod_play_url` 生成选集，`playLines` 按
  `playGroups` 解析出每条线路；`loadBundle` 只在 `.md5` 地址时
  才做 MD5 校验；`JsonSource.get` 按 `ac=list/detail/vid` 传参；
  HLS 代理端口只在 listener `.ready` 后读取；文件导入加了
  security-scoped 访问；Info.plist 的 `armv7` 改 `arm64`、
  加了 `UILaunchScreen` 和 iPad 方向。
- 9280 猫源地址可达性与内容标记（2026-11-27 调研）：
  `.md5` 只有一行 `d8e69da8c37a29afe50fdc8de9dbf268`；
  `index.js` 17,087 行，是 Fastify 服务端 bundle，不是 websiteBundle。
- nodejs-mobile 下载事实（2026-11-27 读 tvbox-silicon 的
  `Scripts/fetch-node-mobile.sh` 全文）：VERSION=26.13.0，
  RELEASE=v26.13.0-tvbox.1，资产 `nodejs-mobile-v26.13.0-apple.zip`，
  SHA-256 `a84ac23e389f186dc64a78e2350b747b6e3f6cf56db12c9e1c3561db156b6440`，
  LICENSE SHA-256 `12d632aa78f637d8c899f19d4549538c477b6df3836fe86731cd821f750abac8`。
- NodeHost 控制协议事实（2026-11-27 读 tvbox-silicon 的
  `Runtime/NodeHost/main.mjs` 893 行 + `worker.mjs` 151 行全文）：
  `node main.mjs <controlFile> <relistenFile>`，控制文件写
  `{"port": n, "token": "..."}`，`POST /call` + `x-yingxia-token`，
  body `{bundle, api, profile, cloudAccounts, proxy, params}`，
  worker 提供 `catServerFactory` / `catDartServerPort()`，
  bundle 导出 `start(config)`，20 秒等服务监听，`/config` +
  `POST /spider/<key>/{init,home,category,detail,play,search}`，
  搜索 404 → `{"list":[]}`，消息服务 `POST /msg`。
  YiPlayer 的 host.mjs / worker.mjs 是按这个协议自写的精简实现，
  不是 tvbox-silicon 代码的复制（省掉了云盘账号、HTTP 代理、
  配置中心登录三项，文件头里有说明）。
- BeeWare Python-Apple-support 发布事实（2026-11-27 读 releases 页）：
  最新非预发布是 3.13.18（b18）等；每个支持包是 `.tar.gz`，内含
  `Python.xcframework`（设备 + 模拟器切片），stdlib 在切片内
  `lib/` 下。资产文件名在抓到的页面文本里没出现，所以
  fetch-python.sh 在运行时用 GitHub API 解析，不硬编码文件名。
- pd.py 事实（2026-11-27 读全文，522 行）：只用 `sys/json/time/hmac/
  hashlib/os/requests` + 函数内 `uuid` / `urllib.parse.quote`，
  不用 lxml/bs4/regex/HTML 解析——所以 `base.spider` 兼容包只需
  Spider 基类那几个方法，`requirements.txt` 只需 requests 全家。

## 未验证（必须在 Mac / 真机 / Actions 上验证）

- **v2.1 Xcode 构建（待跑）**：v2 的构建已在 Actions run #22 成功
  （见“v2 构建实录”），v2.1 的构建还没有跑。v2.1 新增的风险点按顺序：
  ① `vendor/python-stdlib/` 文件夹引用是否原样打进包（与 v2 已验证的
  `spiders/` 文件夹引用同一机制）；② `ApplePython.c` 的新 6 参签名
  与 `YiPythonLastError()` 是否与 Swift 侧一致；③ `Scripts/fetch-python.sh`
  重写后的分阶段步骤在 CI 上是否跑通（缓存键含该脚本，改动即失效缓存）；
  ④ 其余 v2 已验证的风险点（xcframework 下载、NodeBridge.mm、
  `.mm` / `.c` 编进 target、host.mjs / worker.mjs 进 Resources）不再重复。
- **BeeWare stdlib 路径（v2.1 已解决，见上）**：v2.0.0 的假设
  `<Python.framework>/lib/python3.13` 是错的，实测 BeeWare 3.13-b18
  的包里根本没有这条路径。v2.1 改走包内 `python-stdlib/python3.13`，
  初始化前校验 `os.py` 是否存在，失败时报错里写明试过的路径。
- **9280 bundle 的 `/config` 和 `/play` 返回形状**：`CatSource`
  按 CatPawOpen 惯例解析（`/config` 的 sites/list/sources/data，
  `/play` 的 `{url}` / `{playUrl}` / 裸 URL）。如果 v2 装上后
  猫源列表为空或播不了，先看这两个形状是不是猜错了。
- **Node.js 服务端 bundle 实际能不能在 iOS 上跑起来**：worker 的
  20 秒等待、Fastify 在无 JIT 的 Node 26 下的启动时间、bundle
  依赖的 axios 等模块是否都在 bundle 内、bundle 要不要访问
  它自己的 `.config.js`——全部未验证。
- **py 源冷启动与包体**：+60–70 MB 是按 Yingxia 的 python-runtime-plan
  （66–68 MB/平台）估计的；首次调用 10–18 秒是 Yingxia 的实测，
  YiPlayer 自己的数字要等真机。
- **ATS 之谜（未解）**：v1 的 `App/Info.plist` 里**已经有**
  `NSAllowsArbitraryLoads: true`（2026-11-27 在工作区用 plistlib
  验证过），但用户在 v1 里导入 `http://www.y456y.com` 时仍然报
  "The resource could not be loaded because the App Transport Security
  policy requires the use of a secure connection"。最可能的解释是
  用户装的那个 IPA 是在加这个键之前构建的（v1 构建 #4 的 commit
  56ef702f 是 18:33，ATS 键的加入时间需要核对）；也不能排除
  LiveContainer 的启动路径绕过了 Info.plist。v2 在 project.yml
  的 info.properties 里也写了一份（双保险）并加了
  `NSAllowsLocalNetworking`。**如果 v2 仍报 ATS 错误，请把报错
  截图和 IPA 的构建时间发回来，不要只说“还是不行”。**
  另：`SubscriptionImporter.fetch` / `JsonSource.get` /
  `CatSource.fetchText` 都走 `URLSession.shared`，NodeHost 的
  loopback 调用走 ephemeral session——ATS 是 Info.plist 级别
  的系统强制，对所有 NSURLSession 生效，不存在“某个请求绕过
  ATS”的配置；Node 自己的 HTTP 栈本来就不受 ATS 约束。
- **LiveContainer 文件导入**：复制进 Documents 再读的方案是按
  LC 沙盒行为推断的（直接读安全域 URL 不可靠），没有在 LC 里
  验证过；如果仍失败，界面会写具体原因，请把那句话截图发回来。
- **JS 运行时**：`CatJSRuntime` 的 `JSContext.setObject` 传入
  `@convention(block)` 闭包、`JSValue.toDictionary()` 的类型、
  `net.req` 里的同步信号量等待，在真机上可能需要改成
  JSExport / 异步回调。v1 的 Spider 调用只解析了
  `{"list": [...]}` 这一层形状，完整 CatVod 结果解析未实现。
- **HLS loopback 代理**：`NWListener` 在 iOS 后台 / 锁屏时的行为、
  并发连接处理、HTTP 分块传输未验证；v1 是最小实现（一次一连接）。
- **播放**：HDR / DV 不偏色、0.5x–4x、双击/长按手势、音轨字幕
  选择、断点续播，全部未在真机上验证。手势组合
  （双击 + 长按 + 拖动）在同一 `VideoPlayer` 上可能冲突，
  真机上要调。
- **TVBox JSON**：`JsonSource` 的 `ac=list/detail/vid` 参数是 MacCMS
  惯例，未对真实源验证；`detail()` 现在解析 `vod_play_url`
  （`Name$playid#...`，按 `$$$` 分线路）生成选集和 `playGroups`，
  `playLines` 按线路解析直链 URL，但 playid 是 token（需蜘蛛二次
  解析）时会被跳过。`isHDR` 在建 `AVPlayerItem` 后立即读，资源
  未加载时通常是 false，徽标可能不准；`PlayerViewModel.deinit`
  访问 MainActor 隔离属性在 Swift 5.10 下是警告。
- **NOCTRA / Rex 界面**：两家官网文本抓取看不到布局/截图
  （见 research-noctra-rex-cat.md），UI 是按“深色、接着看、
  海报墙、详情多来源聚合、液态玻璃 HUD”这些文字描述做的，
  不是像素级复刻。
- **图标**：`YiPlayer.xcassets` 的 15 个尺寸、tvOS、TopShelf
  都已在仓库里，但 `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`
  是否被 XcodeGen 正确应用、图标在真机上是否显示，要等构建。

## v1 历史（已发生，不用再验证）

- 第 1 次 Actions 构建失败（2026-11-27 18:02，exit 65，3 个编译错，
  均已修）：`NWListener(..., on: .loopback)` 不是合法写法，改成
  `on: .any`（OS 分配临时端口，`.ready` 后读取）；`HomeView` 的
  `.background(.accent, ...)` 改成 `Color.accentColor`；
  `AVPlayerItem` 没有 `eligibleForHDRPlayback` 这个成员，v1 不再
  预检 HDR（播放仍原样透传，播不了时靠 CoreMedia -17223 报错，
  HDR 徽标在 v1 不显示）。另把播放器里 MainActor 隔离属性在
  Sendable 闭包里的修改包进 `Task { @MainActor ... }`，免得升
  Swift 6 后变报错。
- 构建 #4 成功（2026-11-27 18:33，run 45983066045，commit 56ef702f，
  56 秒）：artifact `YiPlayer-unsigned-ipa`，265 KB，
  sha256 `32322d7a9385c45de8ff5b486cd48d4d1526544637195366011c27b91afd61fe`，
  2026-12-11 18:34 CST 过期。用户反馈“啥也运行不了，只有 200 多 K”——
  265 KB 本身不是 bug（Swift 运行时在 iOS 里，v1 没有资源文件），
  真正的原因是 v1 首页是空的（没有预置源）且两个真实源都播不了，
  v2 针对这两点修。
- 所用 API 均为真实 API：SwiftUI（`TabView`、`NavigationStack`、
  `AsyncImage`、`VideoPlayer`）、AVKit（`AVPlayer`、`AVPlayerItem`）、
  AVFoundation、JavaScriptCore（`JSContext`）、Network（`NWListener`、
  `NWConnection`）、CryptoKit（`Insecure.MD5`、`SHA256`）、Foundation
  （`URLSession`、`UserDefaults`、`JSONSerialization`）。

## 假设

- 用户说的 “marcotv” 指 Pilipala9919/MarcoMovie（播放器），
  不是 MarcoTV（Android TV 启动器）。见 research-tvbox-marcotv.md。
- `pd.py` 是 CatVod py 蜘蛛（懂片帝，dongpian17.com），已在仓库
  根目录，522 行，2026-11-27 已读。接口与 555.py 不同：/v1/*
  REST + HMAC-SHA256 签名，分类 全部/电影/剧集/短剧/动漫/综艺 ×
  日/周/月/总榜，播放 id 是 `<token>` 或 `<token>@@<line_id>`，
  经 resolve + resolve-line 二次解析，官方线路优先、4K 排前，
  匿名游客会话自动登录；`localProxy` 是空实现。v2 的
  `base.spider` 兼容包只实现 pd.py 实际用到的基类方法
  （`__init__` / `init` / `getName` / `isVideoFormat` /
  `manualVideoCheck` / `destroy` / `localProxy` / `fetch`），
  其它 CatVod py 蜘蛛如果用到更多 base API（正则/HTML 清洗等），
  要再补——不要假设这个包能跑任意 py 蜘蛛。
- `catvodsub.txt` 里只有 9280 那个猫源地址（用户消息里只给了这一个）。
- 用户的 GitHub 仓库是 dongxipaopao/YiPlayer（main 分支），
  2026-11-27 已连接 Muse（账号 dongxipaopao），仓库里已有
  根目录的 pd.py 和 catvodsub.txt；骨架推送时不覆盖这两个文件。
- iPhone + iPad 通用（`TARGETED_DEVICE_FAMILY: 1,2`，用户 2026-11-27
  决定：先做手机+iPad 通用 IPA，测试没问题后再做 tvOS）。tvOS 是下一步。
- 免费 GitHub Actions macos-15 runner 可用；未签名 IPA 的
  14 天 artifact 保留期足够用户下载。

## 已知缺口（v2 明确不做）

- MKV/AV1 重封装（无 FFmpeg）、下载/离线、直播、弹幕、
  Trakt/iCloud 同步、浅色主题、tvOS、多端同步、
  云盘/音乐/漫画/小说、JVM/DEX。
- 任意 py 蜘蛛的通用支持（只保证 pd.py；其它蜘蛛按需补 base API）。
- 任意猫源 bundle 的通用支持（只保证 9280 这种 Fastify 服务端
  bundle 和 websiteBundle 两种结构；`/config` / `/play` 形状
  是按惯例推断的，见“未验证”）。

## 图标怎么进仓库（v2 新增）

`YiPlayer.xcassets` 里的 .png 不能走文本接口推送，所以打成
`icons-b64/part-*`（gzip tarball 的 base64 分片，每片 220 KB）一起
推送，工作流的 "Restore icon assets" 步骤在 `xcodegen generate`
之前解出来。换图标时重新打包分片即可；`.github/workflows/build-ios.yml`
仍需走网页上传（接口对 workflow 文件返回 403，v1 已验证）。

## v2 构建实录（2026-11-27，Actions 上已验证）

- #17（run 46005851164）Build 失败 exit 65，两个 Swift 错误：
  NodeHost.swift 里 `guard let control` 在 catch 块重复绑定（前面
  的 guard 已解包，`control` 不再是 Optional）→ 改成
  `guard let fresh = self.control`；SettingsView.swift 的
  `UTType.javascript` 不存在 → 改成
  `UTType(filenameExtension: "js") ?? .sourceCode`。
- #19（run 46007783251）Build 失败：`fatal error: 'node/node.h'
  file not found`。实测下载 nodejs-mobile-v26.13.0-apple.zip
  验证：xcframework 里只有 `NodeMobile.h`（声明
  `int node_start(int argc, char *argv[])`），根本没有 node/
  头文件。NodeBridge.mm 改用 `node_start`，不再 include
  `<node/node.h>`、不再调用 `node::Start`；project.yml 删掉
  HEADER_SEARCH_PATHS（框架头经 FRAMEWORK_SEARCH_PATHS 解析）。
- #22（run 46008258962）成功：YiPlayer-unsigned-ipa 23,082,294
  字节，IPA 23,416,561 字节，sha256
  `91be87c4…553fda0`，v2.0.0 build 2。IPA 内已验证含有
  Frameworks/NodeMobile.framework（66.5 MB）、
  Frameworks/Python.framework、host.mjs、worker.mjs、
  spiders/pd.py + _yi_bridge.py + requests。
- 仍未验证（等真机测试）：9280 bundle 在无 JIT Node 26 下
  能否启动 Fastify 并返回 /config / /play；pd.py 首次冷启动
  时间和包体；ATS 对 http://www.y456y.com 是否真的放行；
  LiveContainer 文件导入修复；图标显示。
- 补充：用户后来给了 classic PAT（custom.github-pat），接口
  403 的限制解除——workflow 文件、日志下载、二进制上传都
  可以直接走 API，不用再经网页上传。
