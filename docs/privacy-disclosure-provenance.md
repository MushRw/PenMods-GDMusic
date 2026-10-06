# 隐私声明取证对照表（D1）

> 用途：`SettingsPage.qml` 的「隐私说明」与 `README.md` 的「数据与隐私」两处用户可见文案，
> 每一句都能在这里找到源码依据。**改文案之前先改这张表，再改文案。**
>
> 基线：`main.qml` 3577 行（2026-10）。行号会漂，重新核对时按符号/字面量搜，别只信行号。

## 一、用户可见声明 ↔ 源码依据

| # | 用户看到的声明 | 源码依据 | 核实程度 |
|---|---|---|---|
| 1 | 下载的音频/歌词/封面写入 `/userdisk/Music/GDMusic` | `main.qml:71`（`downloadDir`）、`:2309` / `:2640`（`mkdir -p downloadDir`）、`:2688` / `:2757`（文件路径）、`:79-82`（sidecar 同目录） | 读码确认 |
| 2 | 长期凭据 `MUSIC_U` 明文存插件本地数据库 | `main.qml:3057` `INSERT OR REPLACE INTO kv VALUES(?,?)` ← `["ncookie", ncCookie]`；库为 `main.qml:2949-2950` `LocalStorage.openDatabaseSync("gdmusic", ...)` | 读码确认 |
| 3 | 凭据敏感度等同账号密码 | `main.qml:195` 属性注释自承「cookie（MUSIC_U 等，curl 直接 -H 'Cookie: ...'）」；`:192` 注释称其为**长期凭证** | 注释自承，非推测 |
| 4 | 扫码期间 cookie 明文写 `/tmp/gdmusic_nc_cookie.jar` | `main.qml:1716`（`ncJarPath()`）；`main.qml:622` `-c jar -b jar` 落盘 | 读码确认 |
| 5 | 凭据经 `-H 'Cookie: …'` 进入 curl 命令行参数 | `main.qml:598` | 读码确认 |
| 6 | 同机其他进程能否读到 argv **取决于 hidepid，未确证** | — | ⚠️ **未确证**，本机无设备。文案保留「取决于…未确证」 |
| 7 | unikey 完整拼进 URL 发给第三方 `api.pwmqr.com` | `main.qml:643-645`（`ncQrContent()` 构造 `https://music.163.com/login?codekey=<unikey>`）+ `:648`（整体 encode 后拼进 `https://api.pwmqr.com/qrcode/create/?url=`） | 读码确认 |
| 8 | 用桌面浏览器 UA 绕过网易云风控 | `main.qml:213-224`：`uaBrowser`（Chrome 120 完整 UA）、`ncHdr`、`ncBaseCookie`；注释 `:218` 自承「8821…请求头不像浏览器是首要嫌疑」 | 注释自承 |
| 9 | 退出登录会清除**数据库里**的凭据 | `main.qml:1826-1834` `ncLogout()`：清 `ncCookie/ncUid/ncNick` 后调 `ncSaveCookie()` 回写 | 读码确认。⚠️ **只清数据库那一份**，见第 10 条 |
| 10 | `/tmp` 的 cookie jar **不会**因退出登录而被删除 | `ncJarPath()`（`main.qml:1716`）三个调用点 `:1673` 播种 / `:1722` 轮询 / `:1716` 定义，**无一处 `rm -f`**；全树 18 处 `rm -f` 均与 jar 无关。jar 留到下次重启 / tmpfs 清空才消失 | 读码确认 |

## 二、明确**没有**写进声明的事（故意的）

- **没有说凭据已加密**。D2（cookie 加密）是**故意没实现**的：QML/JS 侧无可用加密原语，
  方案选型未决。见 `gdmusic-p0-drafts/README.md` 第四节 D。
  自写 XOR/查表被明确否掉——那比明文更糟，会给人虚假的安全感。
- **没有说 /tmp 的 jar 会被主动清理**。`ncLogout()` 只回写数据库，
  jar 与历史 argv **不由插件主动清理**——所以也没写「退出登录即全部清除」。
  ⚠️ 这条不是措辞保守，是**核实过的现状**：jar 确实删不掉（见上表第 10 条）。
- **没有把 argv 风险写成已发生**。见上表第 6 条。

## 二之二、待决（需要产品/用户拍板，paper 不代拍）

### 退出登录后，`/tmp/gdmusic_nc_cookie.jar` 里的 cookie 该怎么办

**现状**：`ncLogout()`（`main.qml:1826`）只清数据库那份。jar 里由 curl `-c` 回写的
`Set-Cookie` **明文留在 `/tmp`**，直到下次重启 / tmpfs 清空为止。

**两个选项**：

| 选项 | 代价 | 现状 |
|---|---|---|
| A. `ncLogout()` 顺手 `rm -f` 掉 jar | 一行 shell（`shell.exec("rm -f " + ncJarPath())`） | **未实现** —— 属 `main.qml`，在 paper 写入范围外 |
| B. 保持现状，只在文案里如实说明 | 零改动 | 当前状态 |

⚠️ 这是**产品决策不是文案问题**：A 改变了插件行为，超出 paper 的职责边界
（只做如实表达），需要写 `main.qml` 的队友来做并单独验收。
在那之前，**文案只能按 B 走**：描述现状（jar 明文存在），不承诺"退出即清除"。

## 三、旧文案的错误（已修正，留档）

| 位置 | 原文 | 问题 |
|---|---|---|
| `SettingsPage.qml:153` | 「本插件不存储任何音乐内容，仅做接口转发。」 | **事实错误**。下载确实把完整 mp3 + sidecar 写到 `/userdisk/Music/GDMusic`（上表第 1 条） |
| `README.md:104` | 「本插件不存储、不分发任何音频内容，只做…胶水。」 | 同上。这是最需要警惕的一类错——**听起来无害的谎** |

## 四、SettingsPage 那块的排版账

⚠️ **本机没有设备，以下全部未在真机验证。** 只是按 QML 字体度量做的估算。

- 屏 320×170；声明区宽 `parent.width - 20` = **300px**，字号 9px，行高 1.35 ⇒ 行高约 **12.2px**。
- 折叠态：仅一行标题，高 **14px**（原来那块是 46px ⇒ **折叠态反而更矮**）。
- 展开态：6 条正文，按 9px 中文约 42 字/行估 ⇒ 约 **13-15 行** ⇒ 正文约 **170px**，
  加标题共约 **190px**，超出单屏（170px）⇒ 需滚动。
- **未新增滚动容器**：展开后的高度并入外层 `Flickable`（`SettingsPage.qml:21-28`，
  `contentHeight: col.height`），所以不会出现嵌套滚动。折叠态与展开态都可滚到。

**待真机确认**：① 标题行在 9px 下是否真的单行不折；② `▾/›` 字符在设备字体下是否可见
（若无字形会显示豆腐块，应改用纯文本「展开/收起」）；③ 展开后滚动是否顺手。