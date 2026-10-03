### 避免发送重复的功能请求

- [x] 我已查看所有打开的 Issues，确保这个功能没有被提出过

### 您遇到了什么问题？

我在开发一个第三方音乐插件，音频由插件自己播放（不经过宿主播放器）。

这种情况下，下拉快捷设置面板里的音乐控制区域不会出现，也无法用它控制插件的播放 ——
它显示和控制的始终是宿主播放器。

相关代码是两处：

- `qml/components/YQuickMusicPlayer.qml` 直接读宿主播放器状态（`mediaPlayerManager` 的
  `title` / `playState` / 歌词等），按钮也直接调 `onClickedPlay()` / `onClickedPause()` /
  `onClickedPrev()` / `onClickedNext()`；
- `qml/YQuickSettingLayer.qml` 里这块区域的显示条件：

  ```qml
  musicControlsAvailable: musicPlayer.hideFloatingWindow
      && mediaPlayerManager.playerMode === YEnum.PM_AudioPlayer
      && mediaPlayerManager.title.length > 0
      && mediaPlayerManager.playState !== YEnum.STOPPED
  ```

  后三个条件取决于宿主播放器，所以插件放歌时这个入口不会出现。

目前插件只能靠直接调用宿主内部符号来接入。这种方式能用，但依赖具体内部实现，
宿主改动或固件更新后容易失效。

### 您认为还缺少什么？

希望插件播放的音乐也能出现在系统的音乐控制 UI 上，并能用它控制播放 / 暂停 / 上一首 / 下一首。

实现方式上，两个方向都可以：

1. `PluginSDK.h` 里加一个媒体接口（与现有 `PluginHookAPI` 风格一致），
   用于上报当前播放内容与状态，并接收控制事件；
2. 或者像 `musicPlayer` / `externalPlayer` / `shell` 那样注册一个上下文属性
   （如 `mediaSession`），纯 QML 插件即可使用。

如果已有推荐的接入方式，也请指出。
