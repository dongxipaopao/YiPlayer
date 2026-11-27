# YiPlayer 调研 — NOCTRA / Rex / 猫源测试地址（2026-11-27）

来源：子代理只读调研，未构建。凡没亲眼看到的都写“未看到 / 未证实”。

## NOCTRA（noc.zijiu522.cn）
- iPhone 播放器，官网是产品页+帮助文档站；首页文本抓取超时，没看到布局/配色/截图。
- 开发者成波林，v1.0.1，350.2 MB，2026-10-23 上架，免费、无内购（情报页说法）。
- 定位：自有媒体库播放器，不带片库、不卖片。接入 Emby / Jellyfin / Plex / SMB / WebDAV / 本地文件夹。
- 免费版：4K 及以上每天限播 3 次、只能加 1 个服务器；1080p 及以下不限；本地文件夹不占名额。Pro 解除。
- 播放器：三引擎可选 CineCore / MPV / 系统播放器；播放信息栏显示容器、编码、分辨率、帧率、音轨、动态范围（HDR/DV）。
- 选集、字幕轨/音轨、断点续播；字幕偏移、外挂字幕、实时字幕；缓存管理分开清；iCloud、Trakt 同步；隐私空间 Face ID。
- 首页可自定义，把内容加进 “NOC Studio Preview”，可调栏目顺序、轮播、外观；收藏/待看/日历提醒。
- 借鉴：三引擎切换 + 播放信息面板；“先连一个源、确认能播再配其他”；连接失败分“不可达 / 账号被拒 / 证书”三类报错。

## Rex（rexnow.tv）
- iPhone / iPad / Apple TV / Mac（Mac beta，Apple 芯片 + macOS 14+）自有媒体库播放器。
- 官网是极简落地页（8 行）：“Rex — 专属好剧，一触即发。”聚合媒体服务器、网络文件夹与本地视频。App Store：开发者菲方，v1.1（2026-11-10），238.5 MB，iOS 17+，4.25 分。
- 定价：PRO 月 $3.99 / 年 $29.99 / 终身 $39.99；免费片库 1 个、高清每天 3 次，PRO 无限。
- 首页可自由编排；TMDB 海报、剧照、简介、演员、预告片；收藏可显示为海报墙 / DVD 架 / 电影票。
- 接着看、观看日历（下集何时播、提醒）、观看统计、Trakt；详情页多来源/多版本聚合。
- 播放器：Dolby Vision、HDR、Dolby Atmos；双字幕、屏幕弹幕、跳过片头/片尾；AI 字幕；原生 iOS 界面，浅色/深色，iCloud 同步。
- 手势/倍速/弹幕开关等细节官网和商店都没写，未证实。
- 借鉴：接着看 + 观看日历 + 提醒 + 统计的追剧闭环；详情页多来源聚合；收藏三种形态。

## 共同点 / 关键结论
- 两家都是自有库播放器，不带片库，没有“导入猫源订阅”流程；它们的源是媒体服务器，不是 TVBox/猫源。
- YiPlayer 的订阅导入、猫源解析、py 源执行不能从它俩抄，要按 Yingxia / tvbox-silicon 的路子；能抄的是外壳：首页编排、发现、详情、接着看、观看统计、播放器面板（引擎切换、音轨/字幕、跳过片头片尾、双字幕）。

## 猫源测试地址
- https://9280.kstore.vip/cat/index.js.md5 ：能打开，全文只有一行 MD5：`d8e69da8c37a29afe50fdc8de9dbf268`（index.js 的校验值，不是订阅地址本身）。
- https://9280.kstore.vip/cat/index.js ：能打开，17,087 行，压缩混淆大包。开头是异步队列 + Fastify 服务端代码，不是纯前端配置。
- 标记：默认 SOURCE_ORDER:"douban,360,renren,hanjutv"；TMDB / Bangumi 源枚举；弹幕模块 @dan-uni/dan-any（2.3.9）；很大的 Ott 配置，内含 alist / 网盘类站点列表。
- 没找到 websiteBundle、慕猫、CatPaw、ALLOWED_SOURCES——和之前 aaaaa2780009/cat-bundle 那个包（65,702 行，首行 // ====慕猫源，定义 globalThis.websiteBundle）不是同一个构建。
- 结论：这是一个 CatPawOpen 风格的完整服务端+前端 bundle，不是 TVBox JSON 订阅。YiPlayer 不能当 JSON 解析，要像 Yingxia 那样用 JS 运行时加载执行它（iOS 上对应 tvbox-silicon 用的 Node.js for iOS/tvOS），并用 .md5 做版本校验。

## 未证实
- NOCTRA 官网首页、两家 App 实际界面截图、手势和播放器控制栏布局——文本抓取看不到，需真机看。
- NOCTRA 的 HDR / 杜比视界是否偏色、哪个引擎不出问题——官网只写三引擎可切换 + 动态范围信息，无实测结论。
- 9280.kstore.vip 这个猫源包的实际播放效果——只验证可达和内容标记，没跑过播放。
