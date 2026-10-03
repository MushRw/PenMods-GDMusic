# GD 音乐 · 词典笔音乐插件

给 **有道词典笔 YDP02X**（运行 [PenMods](https://github.com/Lyrecoul/PenMods) 定制系统）用的第三方在线音乐插件。

纯 QML 实现，**不需要编译**。改完推送到设备、重启宿主即可生效。

> 界面按 320×170 的逻辑分辨率设计（设备物理屏 320×480，dp 缩放后为 320×170）。

## 功能

- **搜索**：网易云音源
- **下载**：可选 128k / 192k / 320k / 无损 16bit / 无损 24bit，带队列、进度、失败重试
- **本地库**：扫描下载目录，支持播放、删除、与在线音源匹配（补封面/歌词）
- **歌单**：本地建歌单、增删排序；可选登录网易云账号，**扫码登录后同步本人歌单**
- **播放**：由设备上的 mpv 承担，播放逻辑在 `bin/gdnext.lua` 里常驻后台
  —— 关掉插件页音乐不会停，插件只是"遥控器"
- **系统集成**：通过 `MediaBridge` 把播放状态接到系统的下拉快捷面板
  （曲目、歌词、进度、播放/暂停/上下首）

## 环境要求

| 依赖 | 说明 |
|---|---|
| PenMods 框架 | 提供插件加载（`YDynamicPageStack`）与设备上的 mpv |
| mpv | 插件内的 `gdnext.lua` 驱动它取流播放，预期路径 `/userdisk/mpv/mpv` |
| 网络 | 搜索/取流走第三方 API（`music-api.gdstudio.xyz`）；歌单同步直连 `music.163.com` |
| 网易云账号 | 可选，只有"同步本人歌单"需要 |

## 安装

插件目录固定为 `/userdisk/PenMods/plugins/gdmusic`：

```bash
export ADB_SERIAL=<你的设备序列号>      # adb devices 可查
adb -s "$ADB_SERIAL" shell "mkdir -p /userdisk/PenMods/plugins/gdmusic"
```

把 `plugin/` 下的内容整体推上去（保持 `bin/` `qml/` 的相对结构），然后重启宿主：

```bash
adb -s "$ADB_SERIAL" shell "killall YoudaoDictPen"
```

或者直接用仓库里的部署脚本，它会顺带做重复声明门禁、逐文件 md5 核对、清 QML 缓存：

```bash
ADB_SERIAL=<你的设备序列号> bash tools/deploy.sh
```

## 目录结构

```
plugin/          插件本体（推送到设备的就是这个目录）
  metadata.json  插件元数据
  icon.png       图标
  bin/
    gdnext.lua   常驻播放器：取流、顺序播放、唤醒锁（跑在 mpv 里）
    gdipc.pl     QML 与 mpv/lua 之间的 IPC
  qml/
    main.qml     主控制器（网络、下载、歌单、播放状态镜像都在这）
    MediaBridge.qml  系统媒体会话桥
    Theme.qml / components / pages
probe/           探针：源码级结构断言 + 真机 qmlscene 验证
tools/
  deploy.sh      推送 + 门禁 + 清缓存 + 重启
  qml-dupdecl.js 重复 property/function/id 声明检查
  gen_icon.py    重新生成 icon.png
docs/            与上游框架相关的开发笔记 / issue 草稿
```

## 开发与调试

两种探针，**都必须能跑**才算改完：

```bash
bash probe/buttons.sh        # 纯本地：源码结构断言（触摸目标尺寸、声明顺序等）
bash probe/login.sh          # 纯本地：拿 main.qml 真源码求值，断言语义与边界
bash probe/sidecar-device.sh # 真机：把 QML 推上去用 qmlscene 加载，验证真能跑起来
```

- 源码级探针只做字符串与求值断言，**不解析 QML 结构** —— 所以另有 `tools/qml-dupdecl.js` 兜住
  "重复声明导致整页打不开"这类错误，它已挂进 `deploy.sh` 的推送前门禁。
- 真机探针需要设备在线，脚本读 `ADB_SERIAL` 环境变量。

改 QML 后**必须**清缓存并重启宿主，否则界面不会变（Qt 的 QML 编译产物在宿主进程内存里）：

```bash
bash tools/deploy.sh        # 已包含这一步
```

## 已知限制

- 音源**只有网易云**。JOOX 是海外服务（国内 IP 取不到流）、B 站取流需要登录态，
  两者能搜到结果但点了没声音，已从可选列表移除。**切源的代码路径保留**，
  日后接入可用音源即可启用。
- 网易云那条链路有服务端风控：短时间内反复申请登录二维码会被限流，
  插件里做了冷却与提示，但**频繁重试没有意义**。
- 无损音质取决于音源是否提供以及账号权限。
- 仅在 YDP02X 上实测过，其他机型未验证。

## 免责声明

本项目仅供个人学习与技术研究使用。所有音乐内容、歌词、封面的版权均归各自平台与权利人所有，
本插件不存储、不分发任何音频内容，只做播放器与第三方接口之间的胶水。
请勿用于商业用途，下载的内容请勿二次传播。

## 许可证

暂未指定。在补充许可证文件之前，默认保留所有权利。
