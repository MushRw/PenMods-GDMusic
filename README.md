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
  test-qml-dupdecl.js / test-reason-flow.js / test-onnow-order.js
                 门禁自检（挂进 deploy.sh，见「开发与调试」）
  gen_icon.py    重新生成 icon.png
docs/            与上游框架相关的开发笔记 / issue 草稿
```

### 跨进程状态文件必须原子写（`now.json`）

`/tmp/gdmusic/now.json` 是 **lua 写、QML 读**的跨进程通道（每秒各一拍）。
写侧**必须**走「写同目录 `.tmp` → `os.rename` 覆盖」，不能直接 `io.open(p,"w")`：
后者是**截断式写**，`open` 到 `close` 之间存在「文件为 0 字节」的窗口，
读者会读到空文件 ⇒ `JSON.parse` 抛错 ⇒ 被当成「没在放」⇒ 正在放的歌被掐断。

真机实测（2026-10-07，词典笔 YDP02X）：

| 写实现 | 每次读的坏读率 |
|---|---|
| 截断式写（旧） | 0.054%（隔离夹具）/ 0.0136–0.0291%（真 now.json，n 最大 386 万） |
| 原子写（现） | **0.000000%**（真 now.json + 真 mpv，12 万次读） |

⚠️ 一个反直觉的点：原子写**并没有把写窗口 W 变小**（in-situ p50 354µs vs 旧 328µs，
因为多了一次 rename）。它的收益是**消除了可被观察到的中间态** ——
`.tmp` 写完之前，目标文件始终是完整的旧内容。所以验证要看**坏读率**，不是看 W。
QML 侧另有一层容忍（读到坏数据时沿用上一拍状态）作纵深防御，见 `test-onnow-order.js`。

## 开发与调试

两种探针，**都必须能跑**才算改完：

```bash
bash probe/buttons.sh        # 纯本地：源码结构断言（触摸目标尺寸、声明顺序等）
bash probe/login.sh          # 纯本地：拿 main.qml 真源码求值，断言语义与边界
bash probe/sidecar-device.sh # 真机：把 QML 推上去用 qmlscene 加载，验证真能跑起来
```

- 源码级探针只做字符串与求值断言，**不解析 QML 结构** —— 所以另有 `tools/qml-dupdecl.js` 兜住
  "重复声明导致整页打不开"这类错误，它已挂进 `deploy.sh` 的推送前门禁。
- 检查器自己有自检（`node tools/test-qml-dupdecl.js`，25 项合成夹具），也**已挂进门禁**：
  一个从没被验证过的检查器，它的"全绿"和"根本没跑"输出一样 —— 而它上一版恰好漏检了
  事故文件 `MediaBridge.qml` 本身。
- `node tools/test-reason-flow.js`（20 项）：从 `MediaBridge.qml` **真源码**抠出
  `stopText`/`notifyFailure` 求值，钉住「取流失败只提示一次」「user/end 不提示」。
  这类"每秒判一次"的逻辑最容易退化成每次轮询都弹一次骚扰，或把用户主动停报成错误。
  同样**已挂进门禁**。
- `node tools/test-onnow-order.js`（11 项）：钉住 `MediaBridge.onNow` 的**分支顺序**。
  为什么把"顺序"单独当断言对象：`now.json` 是 lua 写、QML 读的跨进程文件，
  一旦读到 0 字节/半截，旧代码会把它当成"没在放"⇒ `release()+killMpv()`
  ⇒ **正在放的歌被掐断**。修法是「读到坏数据时沿用上一拍状态」，但这条容忍
  **必须排在"播放器已死"的回收分支之后** —— 否则「读不到 **且** mpv 已死」
  两个判据都够不到，会话永不释放。两段代码各自都对，只有顺序错，所以必须钉顺序。
  （这个回归是 2026-10-07 修 P1 时 Lead 自己写反引入的，同轮被该测试抓住。）
- ⚠️ **调用宿主 `qmlGlobal.showToast` 必须传满两个实参** —— 因为它是**信号**，
  不是方法。真机实测（2026-10-07）：
  - `qmlGlobal.showToast` = `YGlobal` 的 **signal** `showToast(QString qsMsg, QColor clrBg)`。
    证据：`neo/factory-qml/qml/commons/YToast.qml:61-67` 用
    `Connections { target: qmlGlobal; function onShowToast(qsMsg, clrBg) }`（**Connections 只能连信号**）；
    宿主 moc 元对象字符串表里 `YGlobal → showToast → qsMsg → clrBg` 参数名紧邻。
  - 少传实参的行为**分三种**（真机实测，同一探针内对照）：
    | 可调用对象 | 少传实参 | 缺的形参 |
    |---|---|---|
    | QML JS **函数** | 不抛 | `undefined` |
    | QML **信号** | **抛 `Insufficient arguments`**，处理器完全不执行 | — |
    | C++ `Q_INVOKABLE`（该参数无默认值） | 抛 | — |
  - ⇒ 抛不抛**只取决于该参数在 C++ 侧有没有默认值**；QML 其实**看得见**默认参数
    （Qt 的 `nextItemInFocusChain(bool forward = true)` 零参调用成功，且真的应用了默认值）。
  - ⚠️ 别拿 `PenMods/src/common/Utils.h:30` 的 `mod::showToast(std::string, QColor = "#1A1B1F")`
    当作依据 —— 那是**另一个函数**（`_ZN3mod9showToastE...`），
    `qmlGlobal` 的真身是 `_ZN7YGlobal9showToastERK7QStringRK6QColor`（`QString` 而非 `std::string`），
    它有没有默认值**未能从设备二进制证明**（无 `qmlplugindump`，`YGlobal` 在本地只是空壳）。
    但 `YGlobal` 是信号，而**信号声明不能有默认参数** ⇒ 必须传满。
  - 这类错误特别阴：调用点外面套着 `try/catch`（toast 绝不能影响播放控制），
    异常被静默吞掉 ⇒ 用户什么也看不到，日志只有一行 `toast failed`。
    `test-reason-flow.js` 的假 `showToast` **刻意校验实参个数**来防它 ——
    夹具若对参数个数没意见，就永远测不出这类回归（第一版夹具正是如此）。
- 真机探针需要设备在线，脚本读 `ADB_SERIAL` 环境变量。
- `probe/shot.sh` 的段 E 断言另一个仓库的 `ScreenGrabber.cpp`，只在 PenMods 的
  `tmp/quick-setting-port` 分支上。缺该文件时它打印 SKIP 并 **`exit 2`**
  （没能完成检查），不会用一堆假红盖住段 A~D 的真实信号。

### 在 Windows 上跑门禁（PowerShell）

`deploy.sh` 是 bash 脚本，`"$L"/qml/*.qml` 由 **bash 自己展开**，不用管。但在 PowerShell
里手跑门禁时，**Node 不会展开通配符** —— 直接写 `node tools/qml-dupdecl.js plugin/qml/*.qml`
传进去的是字面量 `*.qml`，会 ENOENT。必须先展开成文件列表：

```powershell
$files = (Get-ChildItem plugin/qml -Filter *.qml -File) `
       + (Get-ChildItem plugin/qml/pages -Filter *.qml -File) `
       + (Get-ChildItem plugin/qml/components -Filter *.qml -File)
node tools/qml-dupdecl.js ($files | ForEach-Object { $_.FullName })
```

退出码：`0` = 通过，`1` = 查到重复声明，`2` = **参数写错（根本没检查成功）**。
1 与 2 刻意分开，否则 CI 里一道红会被误读成"有 bug 去修"，实际是参数错了。

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

## 数据与隐私

插件**只在用户主动点击下载时**把音频写到设备上，不缓存、不内嵌任何音频内容；
但"下载了就是落盘了"，这是文件，不是插件内部的状态。

### 音频文件存在哪

下载的音频（以及随歌下载的封面 `.jpg`、歌词 `.lrc`）会写入设备的
**`/userdisk/Music/GDMusic`**。选这个目录是因为它已经是设备上的音乐仓库
（`LX-Pen` 等原生下载也放在这里），这样系统自带的文件管理器和原生播放器也能直接看到这些歌。
完整文件才从缓存区 `mv` 进去，歌曲文件夹里不会出现半截 mp3。可在本插件的「本地库」里删除。

### 登录凭据怎么存的

⚠️ **目前是明文，没有加密。** 登录网易云后：

| 存在哪 | 内容 | 依据 |
|---|---|---|
| 插件本地数据库（`LocalStorage` 名 `gdmusic`） | 长期登录凭据 `MUSIC_U` 等 + uid + 昵称 | `main.qml:3057` |
| `/tmp/gdmusic_nc_cookie.jar` | 扫码轮询期间的 curl cookie jar | `main.qml:1716`（`-c`/`-b` 明文落盘） |
| curl 命令行参数 | `-H 'Cookie: …'`，即凭据出现在进程 argv 里 | `main.qml:598` |

`MUSIC_U` 是**长期凭证，敏感度等同账号密码级**——拿到它基本等于拿到账号。
退出登录会清除数据库里的记录（`main.qml:1826`），但 `/tmp` 下的 jar 与历史进程 argv 不由插件主动清理。

**关于 argv 这一条要说明白**：同机其他进程能否读到，取决于系统 `/proc` 的 `hidepid` 配置，
**这一点我们没有设备、未能确证**。可能的暴露面是有的，但不要把它当成已证实的事实。

### 发送给第三方的内容

- **扫码登录**：unikey 会完整拼进 URL，交给第三方二维码服务 **`api.pwmqr.com`** 生成图片
  （网易云官方的 `/login/qrcode/<key>` 接口已废弃返回 404，只能用第三方）。
  该 unikey 是登录流程的一次性凭据，第三方因此能看到它。`main.qml:643-645` / `:648`
- **搜索与取流**：走 `music-api.gdstudio.xyz`（见上文「环境要求」）
- **歌单同步**：直连 `music.163.com`

### 请求头伪装

对网易云的请求带**完整桌面 Chrome UA** 与 Referer，目的是**绕过网易云的风控**，
否则接口会返回 8821「请切换其他登录方式」。这是刻意伪装成桌面浏览器，不是如实声明客户端身份。

### 为什么没做加密

不是遗漏。QML/JS 侧没有可用的加密原语，需要调 `openssl`（设备是否预装**未确证**）
或自写算法——后者不如明文诚实。方案选型尚未决定，所以这里如实说明现状是明文，
而不是先写一个给人虚假安全感的实现。详见 `gdmusic-p0-drafts/README.md` 第四节 D。

## 免责声明

本项目仅供个人学习与技术研究使用。所有音乐内容、歌词、封面的版权均归各自平台与权利人所有。
插件本身不内嵌、不分发音频内容，但它**会把用户主动下载的文件写到设备上**（见上一节），
只做播放器与第三方接口之间的胶水。请勿用于商业用途，下载的内容请勿二次传播。

## 许可证

暂未指定。在补充许可证文件之前，默认保留所有权利。
