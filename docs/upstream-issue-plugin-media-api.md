# 上游 issue 需求整理：给插件系统补一条「媒体会话」通道

> **状态：草稿，未提交。** 用户要求"先整理需求，别发"。
> 目标仓库：`Lyrecoul/PenMods`
> 查重结果（2026-10-01）：上游 7 条 issue 里无同类诉求。最近的是 #7「下拉面板希望记住上次停留的视图」——
> 触及同一处代码（`YQuickSettingLayer.qml` 的 `musicControlsAvailable`）但诉求完全不同，正文中已显式区分。
> 证据基准：上游 `main` 载荷（`qrc_qml.h` 解出 345 个 `.qml`），非我方归档分支。

---

## 一、一句话诉求

PenMods 有插件系统，但**插件和"系统媒体 UI"之间没有任何官方通道**。

想让插件播的歌显示在下拉面板音乐卡片上、并且能被那个卡片控制，目前只能去逆向原厂
`YMediaPlayerManager` 的 mangled 符号。希望官方提供稳定的媒体会话接口。

---

## 二、现状：上游代码事实

### 2.1 音乐卡片只认原厂单例

上游 `qml/components/YQuickMusicPlayer.qml`（269 行）**直接读写**原厂上下文属性 `mediaPlayerManager`：

```qml
readonly property bool isPlaying: mediaPlayerManager.playState === YEnum.PLAYING
readonly property string currentTitle: mediaPlayerManager.title || ""
readonly property string currentMainLyric: !mediaPlayerManager.hasLrc ? "" : (...)
```

四个控制按钮全部直连原厂槽：

```qml
onValidClicked: mediaPlayerManager.onClickedPrev()      // 上一首
onValidClicked: isPlaying ? mediaPlayerManager.onClickedPause()
                          : mediaPlayerManager.onClickedPlay()   // 播放/暂停
onValidClicked: mediaPlayerManager.onClickedNext()      // 下一首
onValidClicked: musicPlayer.stop()                      // 停止（这个反而是 PenMods 的）
```

组件内**没有任何扩展点**：没有可注入的数据源，也没有可拦截的转发层。

### 2.2 卡片可见性判据里 3/4 条绑在原厂单例上

`qml/YQuickSettingLayer.qml` 第 50-53 行：

```qml
readonly property bool musicControlsAvailable: musicPlayer.hideFloatingWindow
                                    && mediaPlayerManager.playerMode === YEnum.PM_AudioPlayer
                                    && mediaPlayerManager.title.length > 0
                                    && mediaPlayerManager.playState !== YEnum.STOPPED
```

第 2/3/4 条对**任何自己播放音频的插件恒不成立** ⇒ 插件在播歌时，下拉面板里那个音乐入口
（`id_show_music_button`）根本不会出现。

### 2.3 插件 API 现状：一条媒体通道都没有

- `src/plugin/PluginSDK.h`：只暴露 `PluginHookAPI{ querySymbol, hookFunction }`，就是裸的符号查询 + inline hook。
- `src/plugin/QmlPluginWrapper.{h,cpp}`：只有插件**列表管理**（`getPluginCount` / `getPluginInfo` /
  `setPluginEnabled` / `uninstallPlugin` / `requestPluginList`），没有一项与媒体相关。
- `README.md` 第 76-79 行对插件系统的定位是"以 QML 为主，原生运行库为辅"——但恰恰是"播音乐"这类
  最典型的插件场景，纯 QML 拿不到任何官方接口。

---

## 三、代价举证：第三方插件现在得逆向到什么程度

一个真实的第三方音乐插件，为了"点歌即用系统 UI 播放 + 复用系统的上一首/下一首/播完事件"，
不得不硬解下面这些 mangled 符号：

```cpp
// 单例定位
"_ZN10YSingletonI19YMediaPlayerManagerE1tE"
"_ZN10YSingletonI13YMediaManagerE8instanceEv"
"_ZN10YSingletonI7YGlobalE8instanceEv"
// 状态读写
"_ZNK19YMediaPlayerManager9playStateEv"
"_ZN19YMediaPlayerManager12setPlayStateERKN12YEnumWrapper10Play_StateE"
"_ZN19YMediaPlayerManager9setHasLrcEb"
"_ZN19YMediaPlayerManager8wipeDataEv"
// 控制事件回流
"_ZN19YMediaPlayerManager13onClickedPlayEv"
"_ZN19YMediaPlayerManager13onClickedPauseEv"
"_ZN19YMediaPlayerManager13onClickedNextEb"
"_ZN19YMediaPlayerManager13onClickedPrevEb"
"_ZN19YMediaPlayerManager10onSoundEndEj"
// 交给宿主播放
"_ZN13YMediaManager9playAudioERK18YColumnMediaEntityb"
"_ZN18YColumnMediaEntityC2EP7QObject"
"_ZN7YGlobal15showAudioPlayerEv"
"_ZN7YGlobal23setAudioPlayingColomnIdERK7QString"
```

而且不止符号——还得读**内部内存布局**：为了对齐 `MusicPlayer` 的会话判断，
插件要按 `self + 0x20 → 内层对象 + 0x64` 的偏移去取"当前音频会话序号"。

**这条路的脆弱性是结构性的**：
- 上游任何一次重构、或设备固件升级导致符号/布局变化，插件都会**静默失效甚至是崩**（不是编译期报错，是运行时）。
- 每个想做音乐的插件都要各自重复一遍这套逆向，做不对还容易把宿主搞崩。
- 与 `README.md` 里"插件以 QML 为主"的定位直接矛盾——**纯 QML 插件根本没法完成接入**。

---

## 四、诉求

### 方向 A —— 上报（插件 → 系统 UI）

插件能把自己正在播放的内容与状态写进一个受支持的会话对象，让下拉面板音乐卡片、
悬浮球、播放页正确显示：

- 标题、时长
- 播放状态（播放 / 暂停 / 停止）
- 当前进度
- 歌词（主行 + 翻译）
- 清除（停止播放时让卡片回到隐藏态）

### 方向 B —— 接收（系统 UI → 插件）

卡片上的播放 / 暂停 / 上一首 / 下一首 / 停止被点击时，能路由给**当前活跃会话的属主**
（原厂播放器，或注册过的插件会话）。现在这几下直接打在 `mediaPlayerManager` 的槽上，
插件没有任何介入机会。

### 方向 C —— 判据解耦（可选，但建议一并考虑）

`musicControlsAvailable` 的后三条建议从"原厂单例状态"改写成"**当前是否存在有内容的活跃会话**"。
语义不变（仍然只在真正有音频在播时才提供音乐控制），但不再把第三方会话排除在外。
> 与 #7 的关系：#7 里我写了"这四个条件本身是合理的，不建议改动它们"——指的是
> **"什么时候该出现音乐控制"这条语义不要动**。此处诉求不是改语义，而是让"活跃会话"的来源可以是插件。

---

## 五、建议的最小实现（降低上游成本）

### 方案 1：`PluginSDK.h` 增补一个 `PluginMediaAPI`（对齐既有 `PluginHookAPI` 的风格）

```c
typedef struct {
    /* 上报：写进当前插件会话 */
    void (*setNowPlaying)(const char* title, int durationMs);
    void (*setPlayState)(int state);          /* 0=stopped 1=playing 2=paused */
    void (*setPosition)(int positionMs);
    void (*setLyric)(const char* mainLrc, const char* transLrc);
    void (*clear)(void);

    /* 接收：系统 UI 的控制事件回调（在插件线程/主线程调用） */
    void (*setControlHandler)(void (*handler)(int action));
    /* action: 0=play 1=pause 2=prev 3=next 4=stop */
} PluginMediaAPI;
```

由 `PluginManager` 随 `init_plugin_with_hook_api` 一起注入（或新增
`init_plugin_with_media_api`）。插件从此**不需要知道任何 mangled 名字和内存布局**。

### 方案 2（更轻，且与现有风格一致）：PenMods 侧 setContextProperty 一个 `mediaSession`

PenMods 已经用同样手法暴露了 `musicPlayer` / `externalPlayer` / `shell` / `pluginManager` 等
几十个上下文属性，再加一个风格完全一致的 `mediaSession` 即可，**纯 QML 插件直接可用**：

```qml
mediaSession.setNowPlaying("歌名", 180000)
mediaSession.setPlayState(1)
mediaSession.onControlAction.connect(function(action) { ... })
```

两个方案可以共存（C++ 插件走 1，QML 插件走 2），也可以只做方案 2 —— 后者更贴合
README 里"插件以 QML 为主"的定位。

### 涉及改动点（供参考）

| 文件 | 改动 |
|---|---|
| `src/plugin/PluginSDK.h` | 增补 `PluginMediaAPI`（方案 1） |
| `src/plugin/PluginManager.cpp` | 注入 API / 或 setContextProperty(`mediaSession`)（方案 2） |
| `qml/components/YQuickMusicPlayer.qml` | 数据源从"直读 `mediaPlayerManager`"改为"读当前活跃会话"；按钮走会话仲裁而非直调原厂槽 |
| `qml/YQuickSettingLayer.qml` | `musicControlsAvailable` 后三条改为按活跃会话判定 |

---

## 六、待确认项（提交前应说明或补测）

1. **纯 QML 插件里 `mediaPlayerManager` 是否可见、可写**——同 engine / 同 root context 理论可见，
   但"能否调用 setter"未实测（setter 参数含 `YEnumWrapper::Play_State`，QML 侧不一定构造得出来）。
   我方已在插件里加了一个只读探针，结果待回。
2. `onClickedPlay` / `onClickedPause` 等槽是否已注册进元对象系统（上游 QML 自己在调 ⇒ 应当是）。
3. 上游是否**有意**只让原厂播放器占用这套 UI（如果是设计选择而非遗漏，那这条 issue 的定位要改成"讨论"）。

---

## 七、issue 正文草稿

> ⚠️ **本节是初版草稿**（口径偏硬、诉求列了三条 A/B/C、附了符号清单）。
> 已按「温和 + 只提主要诉求」收敛为最终版 —— **同目录 `issue-body.md`**，
> 提交时用那个文件做 `--body-file`。
> 本节保留作对照；答辩/被质疑时的举证材料见 §2、§3。

**初版标题**：希望插件能接入系统的音乐控制（下拉面板卡片 / 播放状态）

```markdown
### 避免发送重复的功能请求

- [x] 我已查看所有打开的 Issues，确保这个功能没有被提出过

### 您遇到了什么问题？

PenMods 的插件系统支持"以 QML 为主"地扩展（README 里也这么定位），但**插件和系统媒体 UI
之间没有任何官方通道**——想做音乐插件的开发者只能去逆向原厂的 mangled 符号。

问题出在三个地方：

**1. 音乐卡片只认原厂单例。** `qml/components/YQuickMusicPlayer.qml` 直接读写原厂上下文属性
`mediaPlayerManager`：

```qml
readonly property bool isPlaying: mediaPlayerManager.playState === YEnum.PLAYING
readonly property string currentTitle: mediaPlayerManager.title || ""
...
onValidClicked: mediaPlayerManager.onClickedPrev()
```

组件里没有任何可注入的数据源，也没有可拦截的转发层。

**2. 卡片可见性判据里 3/4 条绑在原厂状态上。** `qml/YQuickSettingLayer.qml`：

```qml
readonly property bool musicControlsAvailable: musicPlayer.hideFloatingWindow
                                    && mediaPlayerManager.playerMode === YEnum.PM_AudioPlayer
                                    && mediaPlayerManager.title.length > 0
                                    && mediaPlayerManager.playState !== YEnum.STOPPED
```

后三条对任何"自己播放音频的插件"恒不成立 ⇒ 插件在放歌时，下拉面板里那个音乐入口根本不出现。

**3. 插件 SDK 里一条媒体接口都没有。** `src/plugin/PluginSDK.h` 只给了
`PluginHookAPI{ querySymbol, hookFunction }`（裸符号查询 + inline hook），
`QmlPluginWrapper` 只管插件列表。

**后果**：一个第三方音乐插件要实现"点歌即用系统 UI 播放、复用系统的上一首/下一首/播完事件"，
得自己硬解十几个 mangled 符号：

```text
_ZN10YSingletonI19YMediaPlayerManagerE1tE
_ZN19YMediaPlayerManager12setPlayStateERKN12YEnumWrapper10Play_StateE
_ZN19YMediaPlayerManager13onClickedPlayEv / PauseEv / NextEb / PrevEb
_ZN19YMediaPlayerManager10onSoundEndEj
_ZN13YMediaManager9playAudioERK18YColumnMediaEntityb
_ZN18YColumnMediaEntityC2EP7QObject
_ZN7YGlobal15showAudioPlayerEv
...
```

还不止符号——为了对齐 `MusicPlayer` 的会话判断，插件要按 `self + 0x20` → 内层 `+ 0x64`
的**内存偏移**去读会话序号。

这条路是结构性脆弱的：上游任何一次重构都可能让插件**静默失效甚至崩溃**（不是编译期报错），
而且每个做音乐的插件都要各自重复一遍。最关键的是——**纯 QML 插件根本没法完成接入**，
这与"插件以 QML 为主"的设计目标是矛盾的。

### 您认为还缺少什么？

希望在插件 API 里补一条双向的「媒体会话」通道：

**A. 上报（插件 → 系统 UI）**：插件能把自己播放的内容写进一个受支持的会话对象，
让下拉面板卡片 / 悬浮球 / 播放页正确显示标题、时长、播放状态、进度、歌词，停止时清除。

**B. 接收（系统 UI → 插件）**：卡片上的播放 / 暂停 / 上一首 / 下一首 / 停止被点击时，
能路由给当前活跃会话的属主（原厂播放器，或注册过的插件会话）。

**C.（可选）** `musicControlsAvailable` 的后三条建议改成按"当前是否存在有内容的活跃会话"判定。
语义不变，只是不再把第三方会话排除在外。
> 补充：这与 #7 不冲突。#7 里我说"这四个条件本身是合理的"指的是
> **"什么时候该出现音乐控制"这条语义不要动**；这里不是改语义，而是让"活跃会话"的来源可以是插件。

**建议的实现**（两选一，或都做）：

- **方案 1**：`PluginSDK.h` 增补一个 `PluginMediaAPI`（对齐既有 `PluginHookAPI` 的风格），
  由 `PluginManager` 随 hook API 一起注入：
  `setNowPlaying / setPlayState / setPosition / setLyric / clear` + `setControlHandler(action)`。
- **方案 2（更轻，推荐）**：PenMods 侧再 `setContextProperty` 一个 `mediaSession`，
  风格与已有的 `musicPlayer` / `externalPlayer` / `shell` / `pluginManager` 一致，
  **纯 QML 插件直接可用**：

```qml
mediaSession.setNowPlaying("歌名", 180000)
mediaSession.setPlayState(1)
mediaSession.onControlAction.connect(function(action) { ... })
```

这样插件开发者不需要知道任何 mangled 名字和内存布局，也不用再各自逆向一遍。

**未验证项（如实说明）**：纯 QML 插件里 `mediaPlayerManager` 是否可读、可写，我还没实测完
（setter 参数含 `YEnumWrapper::Play_State`，QML 侧不一定构造得出来）；`onClickedPlay` 等槽
是否已注册进元对象系统也没最终确认。如果这些其实都已经可用，那这条 issue 可以降级为
"把现有能力官方文档化 / 包一层稳定接口"。
```

---

## 八、提交前检查清单

- [ ] 与用户确认**是否真要提**（用户原话：先别发）
- [ ] 确认标题风格与既有 issue 一致（中文、口语、短）
- [ ] `gh issue list --repo Lyrecoul/PenMods --state all` 再查一次重（避免期间有人提了同类）
- [ ] `--body-file` 提交，**不要用 `--label`**（非协作者会被静默忽略）
- [ ] 提交后 `gh issue view <n> --json title,body,url` 校验
- [ ] 稿件留在本目录，日后回看"我为什么提这条"
