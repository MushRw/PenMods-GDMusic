# 真机 QML 加载验证报告（task-8 / qmlverifier）

设备：`2AB2900000800514`（`adb devices` 显示 `Nexus_4/mako` 是伪造 USB 描述符）
真机：`Linux YoudaoDictionaryPen-514 4.4.159 #1 SMP Fri Aug 18 16:54:58 HKT 2023 aarch64`
Qt：**5.15.2**（`/usr/lib/libQt5Qml.so.5.15.2`）；`qmlscene` 在 `/usr/bin/qmlscene`
所有命令均为**只读设备**：未碰 `/userdisk/PenMods/plugins/gdmusic/`、未 killall、未 reboot、未跑 deploy.sh。

一键复跑（**15 PASS / 0 FAIL / 3 NOTE，退出码 0**）：

```bash
export ADB_SERIAL=2AB2900000800514
bash probe/qmlverify.sh
```

---

## 先回答 Lead 的四个问题（结论速览）

| # | 问题 | 回答 |
|---|---|---|
| 1 | 负向对照跑出预期失败了吗？ | **跑了，两个对照都精确复现 `Type MediaBridge unavailable`**（见 §2.1）。正向「通过」因此有意义 |
| 2 | `MediaBridge` singleton 能否加载？ | **能。`QV RESULT pass=34 bad=0`**（独立于 Lead 的 `PROBE RESULT = OK`，结论一致，见 §2） |
| 3 | 有没有办法在真机上证明「少传实参抛 `Insufficient arguments`」？ | **有，已在真机上直接证明**（见 §3.3）。⚠️ 但要区分三种可调用对象：**QML 函数**少传→`undefined` 不抛（Lead 说得对）；**QML 信号**少传→**抛**；**C++ 方法**少传→**抛**。而 `qmlGlobal.showToast` 是**信号** ⇒ 少传**会抛** |
| 4 | 有没有没做完的？ | **有 3 项未决**（见 §6）：`YGlobal::showToast` 的默认值未能证明；HEAD 未经真机部署验证；/tmp 已清空但 Lead 的 3 个文件在我查看前就不在了 |

---

## 0. 🔴 首先必须说清的版本事实

**设备上部署的不是本地 HEAD。** 逐文件 md5 比对（设备 `md5sum` vs `git cat-file blob`）：

| 文件 | 设备 md5 | HEAD(7fb470a) | b10e8b6(=HEAD~1) | 结论 |
|---|---|---|---|---|
| `qml/main.qml` | `3c98d012…` | 同 | 异 | **= HEAD** |
| `qml/MediaBridge.qml` | `6da2582f…` | `71b91f2e…` | **同** | **= HEAD~1（旧版）** |
| `qml/qmldir` / `Theme.qml` / 4 个 components / 9 个 pages / `metadata.json` / `bin/gdipc.pl` / `bin/gdnext.lua` | — | 全部同 | — | **= HEAD** |

结论：**22 个文件中 21 个 = HEAD(7fb470a)，只有 `MediaBridge.qml` 停在 `b10e8b6`（HEAD~1）**。
`b10e8b6` 提交时间 `2026-10-06 13:27:07`，正是「10-06 的版本」。

⇒ 本报告所有「设备实测」结论**只代表 `MediaBridge.qml = b10e8b6` 那一版**。
**`showToast` 实参修复（7fb470a）未部署到设备，未经真机验证** —— 见 §3.7，我用 HEAD 副本做了对照，但那不是「设备上跑着的那一版」。

---

## 1. 既有探针 `qmlcheck.qml`（照 `probe/qml-e2e.sh:23` 的调用方式）

命令（原始）：

```sh
cd /tmp && QT_QPA_PLATFORM=offscreen timeout 40 /usr/bin/qmlscene /tmp/qmlcheck.qml 2>&1
```

原始输出（完整件见 [`qmlcheck-raw.txt`](./qmlverify-evidence/qmlcheck-raw.txt)，177 行）：

```
This plugin does not support createPlatformOpenGLContext!
qml: GD_SYSMEDIA mediaPlayerManager=no ; mediaManager=no ; ... ; mediaSession=no
qml: CHK hasBackSignal=true
qml: CHK hasExitPlugin=true
...
qml: CHK pback selfGuard=search (期望 search)
```

- **输出 177 行，其中 84 行为 `qml: CHK `** ⇒ `main.qml` 确实被 `Loader` 加载到 `Loader.Ready`（无 `CHK LOAD-ERROR`）。
- **零 QML 警告/错误**：按 `login-device.sh:23` 的同一正则扫描
  （`Error:|Unable to assign|TypeError|ReferenceError|is not a function|Cannot read propert|QML (Debug|Warning)|Assertion failed`）**命中 0 条**。
- 唯一的非 `qml:` 行是 `This plugin does not support createPlatformOpenGLContext!` —— offscreen 平台固有，与插件无关。
- **没有出现 `Type MediaBridge unavailable`**。

> ⚠️ 假绿防护：`qmlverify.sh` 第 3 段要求 `CHK 行数 ≥ 10` 才判绿。
> 第一版 runner 因为漏了 `adb shell`（在主机上跑 qmlscene）拿到 1 行空输出，
> 却因为「没有 warning」被判成 PASS —— 这是**假绿**，已修。

---

## 2. 🔴 核心目标：MediaBridge singleton 能否独立加载

探针 [`qmlverify-singleton.qml`](./qmlverify-singleton.qml)：**不经 main.qml**，直接
`import "file:///userdisk/PenMods/plugins/gdmusic/qml"`，然后触碰 `MediaBridge`。

原始输出：

```
qml: QV PASS 夹具自检 rawCheck(false) 计到 1（证明 PASS 不是恒真）
qml: QV PASS A1 MediaBridge 可解析（非 undefined）
qml: QV PASS A2 typeof MediaBridge  [得到 "object"，期望 "object"]
qml: QV PASS B1 pluginId  [得到 "com.gdmusic.player"，期望 "com.gdmusic.player"]
qml: QV PASS B5 mpvSock  [得到 "/tmp/gdmusic.sock"，期望 "/tmp/gdmusic.sock"]
qml: QV PASS B9 holdMs=3min  [得到 180000，期望 180000]
qml: QV PASS C1 39 个公开方法全部为 function（缺：[]）  [得到 0，期望 0]
qml: QV PASS E1 stopText(user)  [得到 "已停止"，期望 "已停止"]
qml: QV PASS E3 stopText(fail) 用 o.text  [得到 "本地文件已丢失"，期望 "本地文件已丢失"]
qml: QV PASS F1 Toast.qml 组件 Ready（错误：）  [得到 1，期望 1]
qml: QV PASS F2 Toast.qml 实例化成功（证明 import ".." + Theme singleton 可用）
qml: QV PASS G2 Theme.danger 值（MediaBridge 字面量取自它）  [得到 "#e5605c"，期望 "#e5605c"]
qml: QV RESULT pass=34 bad=0
```

**结论：`MediaBridge` singleton 在真机上能独立加载，34/34 断言通过。**

### 2.1 阴性对照（证明这条探针真能测到「加载失败」）

否则「PASS」可能只是探针测不到失败。在 `/tmp` 下做两份**故意的坏副本**（只读源目录，写 `/tmp`）：

| 对照 | 构造 | 原始输出 |
|---|---|---|
| A | `MediaBridge.qml` 剥掉 `pragma Singleton` | `Type MediaBridge unavailable`<br>`qmldir defines type as singleton, but no pragma Singleton found in type MediaBridge.` |
| B | `MediaBridge.qml` 追加语法错误 | `Type MediaBridge unavailable`<br>`negB/MediaBridge.qml:850 Syntax error` |

**两份对照都精确复现了 `Type MediaBridge unavailable`** ⇒ 2026-10-03 事故那条「singleton 一挂、所有 `import "."` 连坐」的链路可复现，且本探针确实能捕获它。

### 2.2 连坐链路的等效复现

`components/*.qml` 与 `pages/*.qml` 全部写 `import ".."`（= 插件 qml 目录）。
探针 F 段实际实例化了 `components/Toast.qml`（它 `import ".."` 并用 `Theme.radius/line/text`），
组件 `Ready` 且拿到 `Theme.radius = 5` ⇒ **相对 import + singleton 这条链在真机上是通的**。

---

## 3. `qmlGlobal.showToast` 的实参个数问题

### 3.1 先纠正 Lead 交给我的一条前提（重要）

Lead 给的签名出处是 `PenMods/src/common/Utils.h:30`：

```cpp
// Utils.h:30（已读源码确认，三个仓库副本一致）
void showToast(const std::string& content, const QColor& theme = "#1A1B1F");
```

**但这个 `showToast` 不是 QML 调的 `qmlGlobal.showToast`。** 证据是 mangled 符号：

| 符号 | 解码 | 参数类型 |
|---|---|---|
| `_ZN3mod9showToastE…NSt3__112basic_string…` | `mod::showToast(std::string const&, QColor const&)` | **`std::string`** ← 对应 `Utils.h:30` |
| `_ZN7YGlobal9showToastERK7QStringRK6QColor` | `YGlobal::showToast(QString const&, QColor const&)` | **`QString`** ← 这才是 `qmlGlobal` |

`Utils.cpp:54-57` 也写明了二者是包装关系：

```cpp
void showToast(const std::string& content, const QColor& theme) {
    PEN_CALL(uint64, "_ZN7YGlobal9showToastERK7QStringRK6QColor", YGlobal*, const QString&, const QColor&)
    (YPointer<YGlobal>::getInstance(), QString::fromStdString(content), theme);
}
```

⇒ **`Utils.h:30` 的 `= "#1A1B1F"` 默认值属于 `mod::showToast`，不能直接拿来证明 `YGlobal::showToast` 有默认值。**
两个函数的「参数类型」和「默认值」是两件独立的事。

另外：`YGlobal` 在 `PenMods/src/base/YPointer.h:48` 只是 `class YGlobal { char filler[0x20]; };`（**空壳**），
真实实现不在任何本地仓库里 ⇒ **无法从源码直接读出 `YGlobal::showToast` 的签名**。

### 3.2 实测：`showToast` 是**信号**，不是方法

`neo/factory-qml/qml/commons/YToast.qml:61-67`：

```qml
Connections {
    target: qmlGlobal
    ignoreUnknownSignals: true
    function onShowToast(qsMsg, clrBg) { id_global_toast.show(qsMsg, clrBg) }
}
```

`Connections` 只能连**信号**，`onShowToast` 是信号处理器命名约定。
且宿主 moc 字符串表里 `showToast` 紧邻的参数名正是 **`qsMsg` / `clrBg`**，与 `YToast.qml` 完全一致：

```
YGlobal|requestSettingPage||index|isPoemReadingChanged|showToast|qsMsg|clrBg|showLoginPage|…
```

⇒ `YGlobal::showToast` 是 **signal `showToast(QString qsMsg, QColor clrBg)`**（`_ZN7YGlobal9showToastE…` 就是 moc 生成的 emitter）。

### 3.3 实测：三种可调用对象，少传实参行为**各不相同**

这是回答 Lead 问题 3 的关键实测。探针 [`qmlverify-fn-vs-signal.qml`](./qmlverify-fn-vs-signal.qml)
把三种可调用对象**放在同一个探针里**分别测（避免混为一谈）：

```
qml: FN CALL QML函数 twoArgs('x') threw=false err="" ret="a=x b=undefined argc=1"
qml: FN PASS (1)  QML **函数** 少传实参不抛错（threw=false）—— 与 Lead 的说法一致
qml: FN PASS (1b) 缺的形参确实是 undefined（ret="a=x b=undefined argc=1"）
qml: FN CALL QML信号 twoArgSignal('only-one') threw=true err="Error: Insufficient arguments" 处理器调用次数=0
qml: FN PASS (2)  QML **信号** 少传实参**抛 Insufficient arguments**（threw=true）
qml: FN PASS (2b) 信号处理器一次都没被调用（0）
qml: FN PASS (3)  C++ Q_INVOKABLE 少传抛 Insufficient arguments（err="Error: Insufficient arguments"）
qml: FN CONCLUSION QML函数少传抛错=false QML信号少传抛错=true C++方法少传抛错=true
qml: FN RESULT pass=7 bad=0
```

| 可调用对象 | 少传实参 | 缺的形参 |
|---|---|---|
| **QML JS 函数** `function f(a,b)` | **不抛** | `undefined` ← Lead 的说法正确 |
| **QML 信号** `signal sig(string,color)` | **抛 `Insufficient arguments`**，处理器**完全不执行** | — |
| **C++ Q_INVOKABLE**（无默认值时） | **抛 `Insufficient arguments`** | — |

> 🔴 我自己的假设在这里被证伪了。我原本推测「信号少传 = 缺的参数是 `undefined`，不抛错，后果只是颜色失效」——
> 探针第一版就是按这个假设写的断言，真机实测**两条全红**。已按实测结果改正断言。
>
> **关键**：`qmlGlobal.showToast` 是**信号**（§3.2）⇒ 它落在第二行，**少传会抛**。
> 所以 Lead 说的「QML 函数少传不抛」虽然对，但**不适用于 showToast** —— 两者不是一回事。
> 这也说明「不能用 QML 函数夹具模拟」是对的，但结论方向与 Lead 的推测**相反**：
> 实测结果是「会抛」，与 MediaBridge 注释的原判断一致。

### 3.4 顺带实测：QML **看得见** C++ 默认参数（纠正一条机制表述）

MediaBridge 注释里写「moc 注册完整参数表，少传一个会抛 `Insufficient arguments`」。
后半句对（无默认值时确实抛），但「moc 注册完整参数表所以永远要传满」这个**机制解释是错的**。
用 Qt 自带、**C++ 侧确有默认值**的方法做对照（探针 [`qmlverify-arity.qml`](./qmlverify-arity.qml)）：

```
qml: AR2 CALL CAL1 contains() 零参（无默认值）        threw=true  err="Error: Insufficient arguments"
qml: AR2 CALL CAL2 childAt(1) 单参（两参都无默认值）   threw=true  err="Error: Insufficient arguments"
qml: AR2 CALL CAL3 childAt(1,1) 双参（基线）          threw=false
qml: AR2 CALL D1 nextItemInFocusChain() 零参（forward 有默认值 true） threw=false
qml: AR2 CALL G0 grabToImage() 零参 threw=true err="Unable to determine callable overload.  Candidates are:
                                                  grabToImage(QJSValue)
                                                  grabToImage(QJSValue,QSize)"
qml: AR2 SUMMARY 校准成立=true 默认参数可见=true
```

`nextItemInFocusChain(bool forward = true)` 是 Qt5 里**只有一个声明**的方法，零参调用**成功**；
`contains()` / `childAt(x)` 少传就抛。⇒ **抛不抛只取决于该参数在 C++ 侧有没有默认值。**

进一步证明 QML 不只是「不抛错」，而是真的**应用了默认值**
（探针 [`qmlverify-defaultarg.qml`](./qmlverify-defaultarg.qml)，构造焦点链 A→B→C，站在 B 上）：

```
qml: FOC CALL B.nextItemInFocusChain()      -> C   ← forward 取到默认值 true
qml: FOC CALL B.nextItemInFocusChain(false) -> A
qml: FOC CALL B.nextItemInFocusChain(true)  -> C
qml: FOC RESULT pass=6 bad=0
```

⇒ **`YGlobal::showToast` 若有默认值，单实参调用就是合法的；若没有，则必抛。**
我**未能**从设备二进制里判定 `YGlobal` 这一项（见下）。

### 3.5 未能证明的部分（如实标注）

- **`YGlobal::showToast` 第 2 参数到底有没有默认值 —— 未能证明。**
  `YGlobal` 在本地只是 `char filler[0x20]` 空壳，真实类声明不在任何本地仓库；
  设备上也没有 `qmlplugindump` / `qmldump`（只有 `/usr/bin/qml`、`qmlscene`、`qmltestrunner`、`qmlpreview`），
  无法把 `qmlGlobal` 的元信息转储出来。
  我尝试过：① 搜 `YGlobal` stringdata 里的颜色字面量 —— **没有**任何 `#RRGGBB`；
  ② 手写 Perl 解析 `qt_meta_data` 找 moc 克隆条目 —— 启发式定位不可靠（多次自相矛盾），
  **不作为证据**。⇒ 这一项标记为 **未能证明**。
- **`qmlGlobal` 在裸 qmlscene 里是 `undefined`**（它是宿主注入的 context property），
  所以**无法**在 qmlscene 里直接读它的元信息 —— 这条路走不通，已放弃。

### 3.6 严格夹具实测：设备上那一版的实际实参个数

探针 [`qmlverify-toast-arity.qml`](./qmlverify-toast-arity.qml) 注入一个**严格挑剔**的假 `qmlGlobal`：
它用 `arguments.length` 数真实实参个数，`< 2` 就主动抛 `Insufficient arguments`
（这正是项目吃过亏的「夹具太宽松 ⇒ 测不出真 bug」的防法）。

夹具自检先证明自己有判别力：

```
qml: TO PASS 夹具自检 单实参调用被夹具判为不足并抛错（n=1）
qml: TO PASS 夹具自检 双实参调用通过（n=2）
```

对**设备上部署的** MediaBridge（`b10e8b6`）三个调用点：

```
qml: TO CALL notifyFailure     -> 实参个数=1  夹具抛错数=1
qml: TO CALL onNow(stopped,fail)-> 实参个数=1  夹具抛错数=1  调用次数=1
qml: TO CALL onOpenRequested   -> 实参个数=1  夹具抛错数=1
qml: TO SUMMARY 三个调用点实参个数=[1,1,1] 全部传满2=false
qml: TO RESULT pass=5 bad=6
```

对**HEAD 修复版**（把 HEAD 的 `MediaBridge.qml` 推成 `/tmp` 下的对照副本，**未改设备插件**）：

```
qml: TO CALL notifyFailure     -> 实参个数=2  夹具抛错数=0
qml: TO CALL onNow(stopped,fail)-> 实参个数=2  夹具抛错数=0
qml: TO CALL onOpenRequested   -> 实参个数=2  夹具抛错数=0
qml: TO SUMMARY 三个调用点实参个数=[2,2,2] 全部传满2=true
qml: TO RESULT pass=11 bad=0
```

⇒ **同一份夹具能区分两版（旧 `[1,1,1]` bad=6 / 新 `[2,2,2]` bad=0）**，证明夹具不是恒真也不是恒假。

### 3.7 🔴 端到端：失败提示到底会不会到用户眼前

把上面两件事合起来：用**信号型**假 `qmlGlobal`（忠实复刻 `YGlobal` 形态）+ 假 shell，
走 MediaBridge 的真实失败路径 `onNow(stopped, reason="fail")`
（探针 [`qmlverify-e2e-toast.qml`](./qmlverify-e2e-toast.qml)）。

**设备部署版（b10e8b6，单实参）：**

```
qml: E2E PASS 夹具自检 真实信号单实参抛错且处理器未调用（toastCount=0）
qml: E2E PASS 前置 桥已持有会话
qml: E2E RESULT toast 弹出次数=0 消息=[] 颜色=[] shell 里有 'toast failed'=true
qml: E2E FAIL 用户能看到失败提示（toast 实际弹出 0 次）
qml: E2E SUMMARY toastCount=0 toastFailedLogged=true
```

**HEAD 修复版：**

```
qml: E2E RESULT toast 弹出次数=1 消息=["取不到播放地址"] 颜色=["#e5605c"] shell 里有 'toast failed'=false
qml: E2E PASS 用户能看到失败提示（toast 实际弹出 1 次）
qml: E2E PASS 没有出现 'toast failed'（异常未被吞掉）
qml: E2E SUMMARY toastCount=1 toastFailedLogged=false
```

⇒ **真机实测确认（在 b10e8b6 上）：**
1. 失败时 `showToast` 抛 `Insufficient arguments`；
2. 异常被 `notifyFailure` 自己的 `try/catch` 吞掉（日志出现 `toast failed`）；
3. **toast 一次都没弹，用户什么都看不到** —— 这正是 7fb470a 要修的缺陷；
4. 把 `showToast` 调用改成传满 2 个实参后，toast 正常弹出 1 次、颜色 `#e5605c` 正确、无 `toast failed`。

> ⚠️ 注意这是「**用 HEAD 副本做对照**」，不是「设备上跑着 HEAD」。设备上跑的仍是 `b10e8b6`。

---

## 4. 我纠正/补充了 Lead 转来的三条结论

| # | Lead 的说法 | 我的实测/取证结果 |
|---|---|---|
| 1 | 「设备上部署的是 10-06 的版本，只有 `MediaBridge.qml` 与 HEAD 不同」 | **成立**，并精确定位：`MediaBridge.qml` = **`b10e8b6`（HEAD~1）**，其余 21 个文件 = `HEAD(7fb470a)`。逐文件 md5 见 §0 |
| 2 | 「**QML 函数**缺实参只得到 `undefined`、不抛错（与 C++ 不同）」 | **前半句成立**（真机实测 `twoArgs('x')` → `b=undefined`，不抛）。**但不能据此推断 `showToast` 也不抛** —— `showToast` 是**信号**不是函数，而**信号少传同样抛**（§3.3 三合一实测）。⇒ 该说法若被用来推翻「少传会抛」，方向是**反的** |
| 3 | 「用 `Utils.h:30` 的默认值证明 showToast 是双参」 | **该出处不匹配**。`Utils.h:30` 是 `mod::showToast(std::string,…)`；QML 调的是 `YGlobal::showToast(QString,…)`，是**信号**，其默认值**未能证明**。不过「必须传满 2 个实参」这个**结论**在 b10e8b6 上仍由 §3.6/§3.7 **真机实测**支持（与默认值有无无关：实测就是抛了） |
| 4 | 「QML 信号少传 = 缺的参数是 `undefined`」（我自己最初的假设） | **证伪**。实测信号少传抛 `Insufficient arguments` 且处理器**完全不执行**。我的探针第一版按错误假设写断言，真机跑出两条 FAIL，已改正 |

---

## 5. 交付物

| 文件 | 用途 |
|---|---|
| [`probe/qmlverify.sh`](./qmlverify.sh) | 一键真机验证 runner（**15 PASS / 0 FAIL / 3 NOTE**，退出码 0），含版本指纹、零警告、singleton、机制、严格夹具、端到端、HEAD 差分、阴性对照、清理 |
| [`probe/qmlverify-singleton.qml`](./qmlverify-singleton.qml) | 🔴 MediaBridge singleton 独立加载（34 断言） |
| [`probe/qmlverify-toast-arity.qml`](./qmlverify-toast-arity.qml) | showToast 实参个数严格夹具（可区分两版） |
| [`probe/qmlverify-e2e-toast.qml`](./qmlverify-e2e-toast.qml) | 端到端：失败提示是否到用户眼前 |
| [`probe/qmlverify-signal.qml`](./qmlverify-signal.qml) | 信号少传实参行为实测（8 断言） |
| [`probe/qmlverify-fn-vs-signal.qml`](./qmlverify-fn-vs-signal.qml) | **函数 vs 信号 vs C++ 方法** 少传实参对比（回答 Lead 问题 3） |
| [`probe/qmlverify-arity.qml`](./qmlverify-arity.qml) | QML 是否看得见 C++ 默认参数（Qt 自带对照） |
| [`probe/qmlverify-defaultarg.qml`](./qmlverify-defaultarg.qml) | 默认值是否被**应用**（焦点链 A→B→C） |
| [`probe/qmlverify-negsetup.sh`](./qmlverify-negsetup.sh) + `qmlverify-neg-*.qml` | 阴性对照（复现 `Type MediaBridge unavailable`） |
| [`probe/qmlverify-headsetup.sh`](./qmlverify-headsetup.sh) | 在 `/tmp` 建 HEAD 副本做对照（不动设备插件） |
| [`probe/qmlverify-evidence/qmlcheck-raw.txt`](./qmlverify-evidence/qmlcheck-raw.txt) | qmlcheck 完整原始输出（177 行） |

---

## 6. 未决项（含「没做完」的坦白）

1. **`YGlobal::showToast` 第 2 参数是否有默认值 —— 未能证明。** 需要宿主 `YGlobal` 的真实类声明（不在任何本地仓库，
   `PenMods/src/base/YPointer.h:48` 只是 `class YGlobal { char filler[0x20]; };` 空壳），
   或一个能转储 `qmlGlobal` 元信息的工具（设备上没有 `qmlplugindump` / `qmldump`）。
   我尝试过两条路都失败：① 搜 `YGlobal` stringdata 里的颜色字面量 —— **没有**任何 `#RRGGBB`；
   ② 手写 Perl 解析 `qt_meta_data` 找 moc 克隆条目 —— 启发式定位不可靠（多次自相矛盾），**不作为证据**。
   *影响*：只影响「机制解释」，**不影响结论** —— §3.6/§3.7 已在 b10e8b6 上直接实测「单实参调用确实抛」。
2. **HEAD(7fb470a) 的 `MediaBridge.qml` 未经真机部署验证**（设备上跑的是 b10e8b6）。
   已用 `/tmp` 副本对照证明修复有效（§3.7），但**要真正验证 HEAD，需要一次 deploy** —— 超出我的只读范围，交 Lead/用户决定。
3. **`qmlverify.sh` 在 PowerShell 下需要先 `export ADB_SERIAL`**；另外 `bash` 不在 PATH 上，
   本机要用 `D:\Program Files\Git\bin\bash.exe` 调用（已实测）。
4. **`/tmp` 已按 Lead 要求清空**（含 Lead 授权可清的 `qmlcheck.qml`）。
   注：Lead 提到的 `/tmp/gd-qmlglobal.qml`、`/tmp/gd-mb-probe.qml`、`/tmp/gd-ab.qml` 在**我第一次查看时就已不存在**（非我所删）。
   清空后的 `ls -la /tmp` 证明见 §7。

---

## 7. 设备安全复核（含 Lead 要求的 md5 对照）

清理后 `/tmp` 只剩系统/其它功能文件，**我的探针与 `qmlcheck.qml` 均已清除**：

```
$ adb shell "ls -d /tmp/qmlverify /tmp/qmlverify2 /tmp/qvdbg /tmp/qmlcheck.qml 2>/dev/null || echo '全部已清除'"
全部已清除
```

设备插件 md5 对照（**与 Lead 给的期望值逐字一致**）：

```
$ adb shell "cd /userdisk/PenMods/plugins/gdmusic && md5sum bin/gdnext.lua qml/MediaBridge.qml qml/main.qml bin/gdipc.pl qml/qmldir metadata.json"
9014a19063147fe156c9407fa0eaa26e  bin/gdnext.lua      ← 期望 9014a19063147fe156c9407fa0eaa26e ✅
6da2582f4aea294d510eb0e2edcda197  qml/MediaBridge.qml ← 期望 6da2582f4aea294d510eb0e2edcda197 ✅
3c98d0126cdce52e39077c14fd4aa136  qml/main.qml
0f3367c72e1d2ce92c325bc0ecc6ca39  bin/gdipc.pl
6e8e70acabe1239b2228b291ed037901  qml/qmldir
22fbe82a5458afafa8994206af8e9d30  metadata.json
```

- `/userdisk/PenMods/plugins/gdmusic/` **未被本次验证改动**（md5 前后一致，目录 mtime 仍为 `Oct 6 13:15/13:16`）。
- 宿主 `YoudaoDictPen` 进程存活。
- 未执行 `killall` / `reboot` / `deploy.sh`；所有写入仅在 `/tmp/qmlverify*` 与 `/tmp/qvdbg`（均已删除）。
- runner 最后一段会自动断言「设备插件未被改动」（`[PASS] 设备插件未被本次验证改动`）。
