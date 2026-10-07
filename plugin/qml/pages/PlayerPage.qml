import QtQuick 2.12
import ".."
import "../components" as Components

// 播放页布局（2026-10-07 A1）—— 320×170 横屏，**很矮**，每一像素都要算。
//
//   ┌───────────────────────────────────────────────────────┐
//   │ ←  正在播放      ⤓ ＋ ≡  ▶  ⚙                        │ 32
//   ├──────────┬────────────────────────────────────────────┤
//   │  ┌────┐  │                                            │
//   │  │封面 │  │        ┌──────────────────────────┐        │
//   │  └────┘  │        │  一群嗜血的蚂蚁 被腐肉所吸引  │        │
//   │   夜曲    │        │  我面无表情 看孤独的风景      │        │
//   │  周杰伦   │        └──────────────────────────┘        │
//   ├──────────┴────────────────────────────────────────────┤
//   │ 0:12 ━━━━━━●━━━━━━━━━━━━━━ 3:45    ⏮   ⏯   ⏭        │ 36
//   └───────────────────────────────────────────────────────┘
//
// 2026-10-07 第二轮调整（用户要求）：
//   · 封面 72 → 56（缩小一点）
//   · 两行标题（歌名/歌手）从**中列**移到**封面正下方**，与封面同列
//   ⇒ 中列只剩歌词，于是歌词框从 71 高变成**整个内容区 102 高**（多约 2 行），
//     歌词宽度基本不变（224 → 200，代价换的是高度）。
//     这是"标题让位"换来的：标题只占左列宽度，歌词独占中列。
//
// 三处刻意的设计决定：
//   ① 进度条与播控**共用底部一条**：进度条贴左、播控贴右。
//      比"播控竖排在最右、进度条单独一行"多出约 40px 歌词宽度（≈4 汉字/行）。
//   ② 下载/加歌单/队列**移到顶栏**（TitleBar.showActions）：同样是为了歌词宽度。
//      代价是顶栏键 30×28 比播放页的 36×32 小，落指精度略降 —— 已知并接受。
//   ③ 三列用**锚定关系**推导坐标，不写魔法数字：左列固定宽、中列吃掉剩余宽度。
//      旧版十几处手写 x/y，改一处忘一处就会出现"封面变大了、歌词还压在它上面"。
//
// ⚠️ 几何由 probe/geom-player.qml 断言（不重叠、不越界）；objectName 是它的锚点，勿改：
//      gdPlayerLeft / gdPlayerCover / gdPlayerSongName / gdPlayerMiddle
//      gdPlayerControls / gdPlayerProgress
Rectangle {
    id: playerPage
    width: 320
    height: 170
    color: Theme.bg

    property var controller: null

    // 信息浮层开关（点封面打开，点任意处关闭）。
    // 做成**同页浮层**而不是独立页面 —— 用户明确要求"不要单独做成一个页面"：
    // 独立页面要占一个 page 值、要进导航栈、还要处理返回键，而这里只是"看一眼信息"，
    // 点掉就该回到原样。浮层不参与导航 ⇒ 也不会与 goPlayerBack 的来处逻辑打架。
    property bool showInfo: false

    // ---------- 栅格（唯一真源）----------
    readonly property int gap: 8                    // 屏幕左右留白、列与列之间
    readonly property int barH: 32                  // 与 TitleBar.height 一致
    readonly property int bottomH: 36               // 底部：时间文字(12) + 进度条(8) + 留白
    readonly property int coverSize: 56             // 封面（左列，2026-10-07 由 72 缩小）
    // 左列宽 = 封面宽 + 两侧留白（封面居中）。
    // 2026-10-07 由 56 加到 68：左列宽直接决定歌名每行能放几个字，
    //   56 时每行仅约 4 个汉字（中文歌名几乎必截断），68 时约 6 个。
    //   代价是歌词列从 240 降到 228 —— 仍比更早的 224 宽，值。
    readonly property int leftW: 68
    readonly property int ctrlBtnW: 36              // 走带键宽
    readonly property int ctrlBtnH: 32              // 走带键高（IconButton 默认，探针依赖）

    Components.TitleBar {
        id: bar
        width: parent.width
        title: "正在播放"
        // 播放页动作移到顶栏（见文件头 ②）
        showActions: true
        downloadTint: {
            if (!playerPage.controller || !playerPage.controller.currentSong) return Theme.textSub
            if (playerPage.controller.isDownloaded(playerPage.controller.currentSong))
                return Theme.accent2
            var s = playerPage.controller.dlStatus(playerPage.controller.currentSong)
            return (s === "run" || s === "wait") ? Theme.accent
                 : (s === "fail") ? Theme.danger : Theme.textSub
        }
        addTint: Theme.accent2
        queueTint: (playerPage.controller && playerPage.controller.queue
                    && playerPage.controller.queue.length > 1) ? Theme.accent : Theme.textSub
        onBackClicked: if (playerPage.controller) playerPage.controller.goPlayerBack()
        onSettingsClicked: if (playerPage.controller) playerPage.controller.openSettings()
        onDownloadClicked: if (playerPage.controller)
                           playerPage.controller.downloadSong(playerPage.controller.currentSong)
        onAddClicked: if (playerPage.controller)
                      playerPage.controller.openAddPick(playerPage.controller.currentSong)
        onQueueClicked: if (playerPage.controller) playerPage.controller.openQueue()
    }

    // ---------- 内容区（顶栏之下、底部之上）----------
    Item {
        id: contentArea
        objectName: "gdPlayerContent"
        x: 0
        y: playerPage.barH
        width: playerPage.width
        height: playerPage.height - playerPage.barH - playerPage.bottomH   // 170-32-36 = 102
    }

    // ---------- 左列：封面 + 两行标题（歌名 / 歌手）----------
    // 整列垂直居中于内容区：封面在上、两行标题在下。
    // 为什么标题放这里而不是中列（2026-10-07 用户要求）：
    //   标题挪出中列后，歌词框就独占了整个内容区高度（71 → 102，多约 2 行），
    //   代价只是左列变宽（56 + 8 间隙），歌词宽度从 224 降到 200 —— 用宽度换高度。
    Item {
        id: leftCol
        objectName: "gdPlayerLeft"
        anchors.left: contentArea.left
        anchors.leftMargin: playerPage.gap
        anchors.verticalCenter: contentArea.verticalCenter
        width: playerPage.leftW
        // 高度由孩子撑开（封面 + 标题两行），不写死 —— 改字号不用回来改这个数
        height: cover.height + 4 + songName.height + songArtist.height

        // 常驻显示（不再"没封面就整块消失"）：占位卡本身就是"这里放封面"的视觉暗示，
        // 而消失会让歌词列突然变宽、歌词位置跳动。
        Rectangle {
            id: cover
            objectName: "gdPlayerCover"
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            width: playerPage.coverSize
            height: playerPage.coverSize
            radius: 5
            color: Theme.card
            border.color: Theme.line
            border.width: 1
            clip: true

            // 点封面 → 打开信息浮层（见文件末尾 infoOverlay）。
            // 用 MouseArea 而不是把 cover 本身做成按钮：cover 是 Rectangle，
            // 加 MouseArea 是 QML 里最直白也最不容易出错的做法。
            MouseArea {
                objectName: "gdPlayerCoverTap"
                anchors.fill: parent
                onClicked: playerPage.showInfo = true
            }

            Image {
                anchors.fill: parent
                anchors.margins: 1
                source: (playerPage.controller && playerPage.controller.coverUrl.length)
                        ? playerPage.controller.coverUrl : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true
                visible: status === Image.Ready
            }

            // 无封面时的占位：用歌名首字。
            // ⚠️ 不用 "♪" 之类的符号 —— 项目吃过缺字形的亏（IconButton 改用 Canvas 就是为此），
            //    而歌名首字一定画得出来（那是歌自己的文本）。
            Text {
                anchors.centerIn: parent
                visible: !(playerPage.controller && playerPage.controller.coverUrl.length > 0)
                text: {
                    var s = playerPage.controller && playerPage.controller.currentSong
                    return (s && s.name) ? String(s.name).substring(0, 1) : ""
                }
                color: Theme.textSub
                font.pixelSize: 22
            }
        }

        // 标题两行：歌名（**最多 2 行，10px 小字号**）+ 歌手。
        // 为什么用 10px 而不是 12px：左列宽度有限（68），12px 时每行仅约 4 个汉字，
        //   中文歌名几乎必被截断；10px 能到约 6 个/行、两行约 12 字，覆盖面大得多。
        //   代价是歌名比歌手（9px）只大一点点，主次没那么分明 —— 用 bold 补偿。
        // 高度预算（内容区 102）：56(封面) + 4 + 24(歌名 2 行@10px) + 11(歌手) = 95，余 7。
        //   ⚠️ 改字号/行数/封面尺寸都要重算这个预算；左列是 verticalCenter 锚定的，
        //   撑高会**上下同时**溢出，而源码里完全看不出来（geom-player.qml 有溢出断言）。
        Text {
            id: songName
            objectName: "gdPlayerSongName"
            anchors.top: cover.bottom
            anchors.topMargin: 4
            anchors.left: parent.left
            anchors.right: parent.right
            text: (playerPage.controller && playerPage.controller.currentSong
                   && playerPage.controller.currentSong.name)
                  ? playerPage.controller.currentSong.name : "未在播放"
            color: Theme.text
            font.pixelSize: Theme.pxSmall
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }

        Text {
            id: songArtist
            objectName: "gdPlayerSongArtist"
            anchors.top: songName.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            text: playerPage.controller && playerPage.controller.currentSong
                  ? ("" + (playerPage.controller.currentSong.artist || "")).replace(/,/g, " / ")
                  : ""
            color: Theme.textSub
            font.pixelSize: 9
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }
    }

    // ---------- 中列：歌词（独占整个内容区高度）----------
    // 🔴 右边界锚到**屏幕右边**，不是锚到底部播控 —— 这一条是 A1 布局的关键。
    //    底部播控只占最下一条（bottomH 高），它不该约束**上方**的内容区宽度。
    //    第一版误锚到 bottomControls.left，算出中列只有 100px 宽（≈9 汉字/行），
    //    比旧版 29 字差得多 —— 而且源码里完全看不出来，只有把坐标算出来才发现。
    Item {
        id: middle
        objectName: "gdPlayerMiddle"
        anchors.left: leftCol.right
        anchors.leftMargin: playerPage.gap
        anchors.right: contentArea.right
        anchors.rightMargin: playerPage.gap
        anchors.top: contentArea.top
        anchors.bottom: contentArea.bottom

        Rectangle {
            id: lyricBox
            objectName: "gdPlayerLyricBox"
            anchors.fill: parent
            radius: Theme.radius
            color: Theme.card
            clip: true

            Column {
                anchors.centerIn: parent
                width: parent.width - 12
                spacing: 2

                // 🔴 歌词渲染（2026-10-07 支持翻译）：
                //    数据形状是 {time, text, trans} —— 翻译挂在原文上，**不是**独立条目。
                //    （旧实现把原文与翻译当两组并列条目，索引被翻译抢走、与原文错位一句。）
                //    所以这里按"原文 + 其翻译"成对渲染：
                //      当前句原文（亮、12px）
                //      当前句翻译（暗、10px，无翻译时不占位）
                //      下一句原文（暗、10px，预览用）
                //      下一句翻译（更暗、9px，无翻译时不占位）
                //    visible 绑到 text.length ⇒ 没翻译的歌自动只剩两行，不留空行。

                // 当前句 · 原文
                Text {
                    objectName: "gdLyricCurOrig"
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: {
                        if (!playerPage.controller) return ""
                        if (playerPage.controller.statusText.length) return playerPage.controller.statusText
                        if (playerPage.controller.lyricLines.length === 0) return "暂无歌词"
                        var i = playerPage.controller.lyricIndex
                        return i >= 0 && i < playerPage.controller.lyricLines.length
                               ? playerPage.controller.lyricLines[i].text : ""
                    }
                    color: (playerPage.controller && playerPage.controller.lyricLines.length > 0
                            && !playerPage.controller.statusText.length) ? Theme.text : Theme.textSub
                    font.pixelSize: Theme.pxNormal
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }

                // 当前句 · 翻译
                Text {
                    objectName: "gdLyricCurTrans"
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    visible: text.length > 0
                    text: {
                        if (!playerPage.controller || playerPage.controller.statusText.length) return ""
                        var i = playerPage.controller.lyricIndex
                        if (i < 0 || i >= playerPage.controller.lyricLines.length) return ""
                        var t = playerPage.controller.lyricLines[i].trans
                        return t ? String(t) : ""
                    }
                    color: Theme.textSub
                    font.pixelSize: Theme.pxSmall
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }

                // 下一句 · 原文（预览）
                Text {
                    objectName: "gdLyricNextOrig"
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    visible: playerPage.controller && playerPage.controller.lyricLines.length > 0
                             && !playerPage.controller.statusText.length
                    text: {
                        if (!playerPage.controller) return ""
                        var i = playerPage.controller.lyricIndex + 1
                        return (i >= 0 && i < playerPage.controller.lyricLines.length)
                               ? playerPage.controller.lyricLines[i].text : ""
                    }
                    color: Theme.textSub
                    font.pixelSize: Theme.pxSmall
                    elide: Text.ElideRight
                }

                // 下一句 · 翻译（预览）—— 比上一行更暗，形成层次
                Text {
                    objectName: "gdLyricNextTrans"
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    visible: text.length > 0
                    text: {
                        if (!playerPage.controller || playerPage.controller.statusText.length) return ""
                        var i = playerPage.controller.lyricIndex + 1
                        if (i < 0 || i >= playerPage.controller.lyricLines.length) return ""
                        var t = playerPage.controller.lyricLines[i].trans
                        return t ? String(t) : ""
                    }
                    color: Theme.line
                    font.pixelSize: 9
                    elide: Text.ElideRight
                }
            }
        }
    }

    // ---------- 底部：进度条（左） + 播控（右）----------
    // 两者同处一条：进度条贴左、播控贴右。这是 A1 布局的核心取舍，
    // 换来歌词列宽约 224px（对比"播控竖排在右"的 188px）。
    Item {
        id: bottomArea
        objectName: "gdPlayerProgress"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: playerPage.bottomH

        // ---- 播控（右，三键横排）----
        // 横排而不是竖排：竖排要占 3×32+2×4 = 104 高，而这一条只有 36 高，塞不下。
        Row {
            id: bottomControls
            objectName: "gdPlayerControls"
            anchors.right: parent.right
            anchors.rightMargin: playerPage.gap
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            Components.IconButton {
                width: playerPage.ctrlBtnW
                height: playerPage.ctrlBtnH
                kind: "prev"
                onClicked: if (playerPage.controller) playerPage.controller.prev()
            }
            Components.IconButton {
                width: playerPage.ctrlBtnW
                height: playerPage.ctrlBtnH
                kind: (playerPage.controller && !playerPage.controller.paused) ? "pause" : "play"
                tint: Theme.accent
                onClicked: if (playerPage.controller) playerPage.controller.togglePause()
            }
            Components.IconButton {
                width: playerPage.ctrlBtnW
                height: playerPage.ctrlBtnH
                kind: "next"
                onClicked: if (playerPage.controller) playerPage.controller.next()
            }
        }

        // ---- 进度条（左，占据播控左边的全部剩余宽度）----
        Item {
            id: progArea
            anchors.left: parent.left
            anchors.leftMargin: playerPage.gap
            anchors.right: bottomControls.left
            anchors.rightMargin: playerPage.gap
            anchors.top: parent.top
            anchors.bottom: parent.bottom

            // 时间文字**贴着进度条上沿**（2026-10-07 用户反馈"时间有点靠上"）。
            // 旧写法把两个 Text 都锚到 parent.top —— 那是这一条的最顶端，
            // 而进度条锚在 bottom（bottomMargin 8），中间就空出一大块，看着像"飘着"。
            // 改成锚到**进度条自己的 top**（再往上留 1px），两者的间距就与
            // progressH/bottomMargin 无关了：以后改这两个数，时间会自己跟着走。
            Text {
                id: posText
                objectName: "gdPlayerPosText"
                anchors.left: parent.left
                anchors.bottom: progBg.top
                anchors.bottomMargin: 1
                text: playerPage.controller ? playerPage.controller.fmtTime(playerPage.controller.timePos) : "00:00"
                color: Theme.textSub
                font.pixelSize: 9
            }

            Text {
                id: durText
                objectName: "gdPlayerDurText"
                anchors.right: parent.right
                anchors.bottom: progBg.top
                anchors.bottomMargin: 1
                text: playerPage.controller ? playerPage.controller.fmtTime(playerPage.controller.duration) : "00:00"
                color: Theme.textSub
                font.pixelSize: 9
            }

            Rectangle {
                id: progBg
                objectName: "gdPlayerProgBar"
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 8
                height: 8
                radius: 4
                color: Theme.card

                Rectangle {
                    width: parent.width * (playerPage.controller ? playerPage.controller.progress : 0)
                    height: parent.height
                    radius: 4
                    color: Theme.accent
                }

                Rectangle {
                    // 拖动手柄
                    visible: playerPage.controller && playerPage.controller.duration > 0
                    x: Math.max(0, Math.min(parent.width - 10,
                         parent.width * (playerPage.controller ? playerPage.controller.progress : 0) - 5))
                    y: -2
                    width: 10; height: 12
                    radius: 5
                    color: Theme.text
                }

                MouseArea {
                    anchors.fill: parent
                    // 上下各放宽 6px：进度条只有 8px 高，手指点不准 —— 视觉不变但可点区更大。
                    anchors.topMargin: -6
                    anchors.bottomMargin: -6
                    onClicked: {
                        if (!playerPage.controller) return
                        playerPage.controller.seekRatio(mouse.x / width)
                    }
                }
            }
        }
    }

    // ---------- （原音量条位置：已移除）----------
    // 音量不再由插件控制 —— mpv 保持默认 100 不衰减，交给系统的音量键统一管。
    // 插件里再叠一层衰减，会让「系统音量拉满声音还是小」变成一个说不清的 bug。

    // ============================================================
    // 信息浮层（点封面打开）
    // ============================================================
    // 半透明黑底 + 左侧大封面 + 右侧歌曲信息，**点任意处关闭**。
    //
    // 为什么放在文件最后：QML 里后声明的兄弟节点在**上层**（z 序按声明顺序），
    //   所以浮层写在最后才能盖住底下的播放页内容。放前面会被盖住 ——
    //   这种"代码全对但看不见"的问题很难查，写在这里当备忘。
    //
    // ⚠️ 它必须覆盖**整屏**（anchors.fill: parent），不只是内容区：
    //   否则顶部标题栏和底部播控会露在浮层外面，用户点它们会触发播控/返回，
    //   而不是"点一下关闭"。铺满全屏才能保证"点任意地方都关闭"。
    Rectangle {
        id: infoOverlay
        objectName: "gdPlayerInfoOverlay"
        anchors.fill: parent
        visible: playerPage.showInfo
        // 🔴 半透明底必须用**带 alpha 的颜色**，不能用 `opacity`。
        //    `opacity` 会作用到**所有子节点**（大封面、文字一起变半透明 ⇒ 糊成一片）；
        //    Qt.rgba 只影响这一层自己的底色。这是 QML 里很常见的坑：
        //    两个写法在源码里看着都像"半透明"，效果差很远。
        color: Qt.rgba(0, 0, 0, 0.88)

        // 点任意处关闭。⚠️ 用 MouseArea 铺满，且**不**放在 children 里最后 ——
        //   它要能收到点击，就必须在内容之上；这里靠声明顺序（它先声明、内容后声明）
        //   ⇒ 内容在上层。所以关闭用的 MouseArea 要**最后**声明（见下面 closeArea）。
        //   （第一版把它写在最前，结果点封面图区域无法关闭 —— 被内容挡住了。）

        // ---- 左侧：大封面 ----
        Rectangle {
            id: bigCover
            objectName: "gdPlayerBigCover"
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            width: 118
            height: 118
            radius: 6
            color: Theme.card
            border.color: Theme.line
            border.width: 1
            clip: true

            Image {
                anchors.fill: parent
                anchors.margins: 1
                source: (playerPage.controller && playerPage.controller.coverUrl.length)
                        ? playerPage.controller.coverUrl : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true
                visible: status === Image.Ready
            }

            // 无封面时显示歌名首字（与左下角小封面一致的处理）
            Text {
                anchors.centerIn: parent
                visible: !(playerPage.controller && playerPage.controller.coverUrl.length > 0)
                text: {
                    var s = playerPage.controller && playerPage.controller.currentSong
                    return (s && s.name) ? String(s.name).substring(0, 1) : ""
                }
                color: Theme.textSub
                font.pixelSize: 44
            }
        }

        // ---- 右侧：歌曲信息 ----
        // 宽度锚到大封面的右边到屏幕右边之间，自动吃掉剩余宽度。
        //
        // 🔴 信息区有自己的**不透明底块**（2026-10-07 方案 C）。
        //    为什么需要：浮层整体是 0.88 半透明（保住"看得出底下是播放页"的语义），
        //    但在 320×170 这种小屏上，12% 的透光足以让底下的**歌词文字**透上来，
        //    与这里的「音源/音质/队列…」叠在一起，看着像串行。
        //    给内容一块实底 ⇒ 文字干净，而浮层外围仍是半透明（语义不丢）。
        Rectangle {
            id: infoPanel
            objectName: "gdPlayerInfoPanel"
            anchors.left: bigCover.right
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            // 高度 = 内容高 + 上下内边距（12/12），保证底块始终包住内容
            height: infoRows.height + 24
            radius: Theme.radius
            color: Theme.bg          // 实底：与页面同色，看着像"一块面板"
            border.color: Theme.line
            border.width: 1

            Item {
                id: infoCol
                objectName: "gdPlayerInfoCol"
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 12
                height: infoRows.height

                Column {
                    id: infoRows
                    width: parent.width
                    spacing: 5

                    // 歌名（可能较长，允许 2 行）
                    Text {
                        width: parent.width
                        text: (playerPage.controller && playerPage.controller.currentSong
                               && playerPage.controller.currentSong.name)
                              ? playerPage.controller.currentSong.name : "未在播放"
                        color: "#FFFFFF"
                        font.pixelSize: 14
                        font.bold: true
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }

                    // 歌手
                    Text {
                        width: parent.width
                        visible: text.length > 0
                        text: (playerPage.controller && playerPage.controller.currentSong)
                              ? ("" + (playerPage.controller.currentSong.artist || "")).replace(/,/g, " / ")
                              : ""
                        color: Theme.textSub
                        font.pixelSize: 10
                        elide: Text.ElideRight
                    }

                    // 分隔线
                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Theme.line
                    }

                    // 信息行：标签 + 值。用 Repeater 而不是手写四行 —— 加一行只改数据。
                    Repeater {
                        model: playerPage.infoRows()
                        delegate: Row {
                            width: infoRows.width
                            spacing: 6
                            Text {
                                text: modelData.k
                                color: Theme.textSub
                                font.pixelSize: 9
                                width: 34
                            }
                            Text {
                                // 剩余宽度给值；过长省略，不让它顶破右边界
                                width: infoRows.width - 34 - 6
                                text: modelData.v
                                color: "#FFFFFF"
                                font.pixelSize: 9
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }

        // ---- 关闭热区（**最后声明** ⇒ 在最上层，保证点哪都能关）----
        // ⚠️ 它必须声明在内容之后，否则会被封面/文字挡住、点上去没反应。
        //    这是本浮层唯一的"关闭"入口 —— 用户要求"点一下任意地方就可以回到正常播放页"。
        MouseArea {
            id: closeArea
            objectName: "gdPlayerInfoClose"
            anchors.fill: parent
            onClicked: playerPage.showInfo = false
        }
    }

    // 浮层右侧的「标签: 值」数据。纯函数，便于探针直接断言。
    // 数据源全部来自 controller 的公开属性/函数 —— 不自己算，避免与播放页显示不一致。
    function infoRows() {
        var c = playerPage.controller
        if (!c) return []
        var s = c.currentSong
        var rows = []
        if (!s) return [{ k: "状态", v: "未在播放" }]

        // 音源
        rows.push({ k: "音源", v: c.sourceLabel ? c.sourceLabel() : String(s.source || "") })
        // 音质
        if (c.qualityLabel) rows.push({ k: "音质", v: c.qualityLabel() })
        // 队列位置（"第 3 / 100 首"）—— 用户最常想知道"还有多少首"
        if (c.queue && c.queue.length) {
            var n = (c.queueIndex >= 0 && c.queueIndex < c.queue.length) ? (c.queueIndex + 1) : 1
            rows.push({ k: "队列", v: "第 " + n + " / " + c.queue.length + " 首" })
        }
        // 时长
        if (c.duration > 0) rows.push({ k: "时长", v: c.fmtTime(c.duration) })
        // 本地状态：已下载 / 未下载 / 下载中
        var dl = "未下载"
        if (c.isDownloaded && c.isDownloaded(s)) dl = "已下载"
        else if (c.dlStatus) {
            var st = c.dlStatus(s)
            if (st === "run" || st === "wait") dl = "下载中"
            else if (st === "fail") dl = "下载失败"
        }
        rows.push({ k: "本地", v: dl })
        // 曲目 id：出问题时方便对着日志查
        if (s.id) rows.push({ k: "ID", v: String(s.id) })
        return rows
    }
}
