import QtQuick 2.12
import ".."
import "../components" as Components

Rectangle {
    id: localPage
    width: 320
    height: 170
    color: Theme.bg

    property var controller: null

    Components.TitleBar {
        id: bar
        width: parent.width
        title: "本地音乐"
        showLocal: false
        showTabs: true
        tabIndex: 1
        tabLabels: ["搜索", localPage.controller ? localPage.controller.dlTabLabel : "本地", "歌单"]
        // 本地页同样是根页面：返回 = 退出插件，回搜索页请用顶部的「搜索」标签。
        // （两个标签页的返回行为必须一致，否则用户会搞不清自己在哪一层）
        onBackClicked: if (localPage.controller) localPage.controller.exitPlugin()
        showPlayer: localPage.controller ? localPage.controller.hasNowPlaying : false
        onPlayerClicked: if (localPage.controller) localPage.controller.gotoPlayer()
        onSettingsClicked: if (localPage.controller) localPage.controller.openSettings()
        onTabClicked: {
            if (!localPage.controller) return
            if (index === 0)      localPage.controller.goSearch()
            else if (index === 2) localPage.controller.goPlaylists()
        }
    }

    // ---------- 下载队列卡片（有任务才出现，列表向下让位） ----------
    Rectangle {
        id: dlCard
        objectName: "gdDlCard"
        property var view: localPage.controller ? localPage.controller.dlQueueView : []
        property int rows: Math.min(view.length, 3)   // 高度封顶，多出来的交给「…还有 N 个」
        y: 32
        width: parent.width
        height: view.length ? (22 + Math.min(view.length, 3) * 26 + (view.length > 3 ? 12 : 2)) : 0
        visible: view.length > 0
        color: Theme.card

        Column {
            anchors.fill: parent
            anchors.margins: 2

            Text {
                anchors.leftMargin: 6
                text: "下载队列 (" + dlCard.view.length + ")"
                color: Theme.textSub
                font.pixelSize: 9
                height: 18
                verticalAlignment: Text.AlignVCenter
            }

            Repeater {
                model: dlCard.view.slice(0, dlCard.rows)

                Item {
                    width: dlCard.width - 4
                    height: 26
                    property var e: modelData

                    Text {
                        id: qName
                        anchors.left: parent.left
                        anchors.leftMargin: 6
                        anchors.right: qPct.left
                        anchors.rightMargin: 6
                        anchors.top: parent.top
                        height: 14
                        text: e ? e.name : ""
                        color: Theme.text
                        font.pixelSize: Theme.pxSmall
                        elide: Text.ElideRight
                    }

                    // 进度条：pct=-1（拿不到总大小）时条不涨、右侧显示字节数
                    Rectangle {
                        anchors.left: parent.left
                        anchors.leftMargin: 6
                        anchors.right: qPct.left
                        anchors.rightMargin: 6
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 3
                        height: 4
                        radius: 2
                        color: Theme.line
                        Rectangle {
                            width: (e && e.pct > 0) ? parent.width * e.pct / 100 : 0
                            height: parent.height
                            radius: 2
                            color: e && e.running ? Theme.accent : Theme.textSub
                        }
                    }

                    Text {
                        id: qPct
                        anchors.right: qCancel.left
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        width: 44
                        horizontalAlignment: Text.AlignRight
                        text: {
                            if (!e) return ""
                            if (!e.running) return "等待"
                            if (e.pct >= 0) return e.pct + "%"
                            return localPage.controller ? (localPage.controller.sizeText(e.got) || "0 KB") : ""
                        }
                        color: e && e.running ? Theme.accent : Theme.textSub
                        font.pixelSize: 9
                    }

                    // 取消。行内点一下直接取消 —— 排队/下载中误触的代价只是重下，
                    // 不值得像删除本地文件那样上二次确认。
                    Rectangle {
                        id: qCancel
                        objectName: "gdDlCancelBtn"
                        anchors.right: parent.right
                        anchors.rightMargin: 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: 26
                        height: 22
                        radius: Theme.radius
                        color: cArea.pressed ? Theme.line : Theme.cardHi
                        border.color: Theme.line
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "×"
                            color: Theme.textSub
                            font.pixelSize: 14
                        }
                        MouseArea {
                            id: cArea
                            anchors.fill: parent
                            onClicked: if (e && localPage.controller) localPage.controller.dlCancel(e.id)
                        }
                    }
                }
            }

            Text {
                visible: dlCard.view.length > 3
                anchors.leftMargin: 6
                text: "…还有 " + (dlCard.view.length - 3) + " 个"
                color: Theme.textSub
                font.pixelSize: 9
                height: 12
                verticalAlignment: Text.AlignVCenter
            }
        }
    }

    // ---------- 列表 ----------
    ListView {
        id: list
        objectName: "gdLocalList"
        y: 32 + dlCard.height
        width: parent.width
        height: parent.height - y - 22
        clip: true
        model: localPage.controller ? localPage.controller.localList : null
        boundsBehavior: Flickable.StopAtBounds
        spacing: 1

        delegate: Rectangle {
            width: list.width
            height: 34
            color: itemArea.pressed ? Theme.cardHi : (index % 2 ? Theme.bg : Theme.card)

            property var rec: modelData
            property bool confirming: false
            // 严格布尔（见下面 mapBox 里的注释）：matched 缺失时也得是真 false
            readonly property bool matchedFlag: !!(rec && rec.matched)

            // ❗整行点击区必须【最先声明】—— QML 同 z 下后声明的在上层。
            //    它 anchors.fill 覆盖整行，原来写在按钮后面 ⇒ 压在「?」「×」上面，
            //    于是点按钮全被它吃掉、变成「播放这首」（用户感受就是"按钮根本点不到"）。
            //    搜索历史那行的删除键有同一条注释，那边顺序是对的，这里是反的。
            MouseArea {
                id: itemArea
                objectName: "gdRowTapArea"
                anchors.fill: parent
                // 长按 = 加入歌单。
                // ⚠️ longFired 守卫：Qt 的长按触发后一般不再发 clicked，但「一般」不够 ——
                //    万一发了，用户长按一下就会"打开加歌页 + 顺手开始播这首"，
                //    而在真机上这个现象很难复现定位。守卫让两种实现都安全。
                //    重置时机用 onPressedChanged（MouseArea 没有 pressed() 信号，
                //    只有 pressed 属性 + pressedChanged）。
                property bool longFired: false
                // ⚠️ 必须显式设值：默认间隔取自 QStyleHints，而部分平台（含本设备的
                //    offscreen/嵌入式配置）会返回 -1 = "不支持长按" ⇒ 定时器根本不启动，
                //    长按入口会静默变成死代码（不报错，只是永远不触发）。
                pressAndHoldInterval: 700
                onPressedChanged: if (pressed) longFired = false
                onPressAndHold: {
                    longFired = true
                    confirming = false
                    if (localPage.controller)
                        localPage.controller.openAddPick(localPage.controller.localList[index])
                }
                onClicked: {
                    if (longFired) { longFired = false; return }
                    confirming = false
                    if (localPage.controller) localPage.controller.playLocal(index)
                }
            }

            Column {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: mapBox.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                    width: parent.width
                    text: rec && rec.name ? rec.name : ""
                    color: Theme.text
                    font.pixelSize: Theme.pxSmall
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: {
                        if (!rec) return ""
                        var a = rec.artist ? String(rec.artist).replace(/,/g, " / ") : ""
                        var s = localPage.controller
                                ? localPage.controller.sizeText(rec.size) : ""
                        // 「词」= 有同名 .lrc，「图」= 有同名封面。
                        // 两者都是**纯 ASCII**（设备字体没有 U+25xx 之外的图标字形，
                        // 见技能 §3.8 附），且刻意不加图标色块 —— 这一行已经够挤了。
                        var flags = ""
                        if (rec.hasLrc) flags += "词"
                        if (rec.img) flags += (flags.length ? "·图" : "图")
                        if (flags.length) flags = " [" + flags + "]"
                        return (a.length ? a + " · " : "") + s + flags
                    }
                    color: Theme.textSub
                    font.pixelSize: 9
                    elide: Text.ElideRight
                }
            }

            // 匹配徽标 + 手动匹配入口（登记表见 main.qml 的 fileMap）。
            //   ✓ 绿 = 已登记（插件下载时自动登记 / 手动匹配过）
            //   ? 灰 = 未登记 —— 点一下进匹配页（搜索词已按文件名预填）
            // 放这一列而不是新起一行：320×170 上每行 34px 已是两个文字行 + 两个按钮，
            // 再加一行就得砍列表高度。
            Rectangle {
                id: mapBox
                objectName: "gdLocalMatchBtn"
                anchors.right: delBox.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                // 30×26（原 24×22）。原来背景是 transparent：用户看不见可点区域的边界，
                // 只能靠猜，落指自然点不准 —— 底色 + 描边就是把边界"画出来"。
                // 与右侧删除键的间距也从 2 拉到 6，两个键不再贴在一起误触。
                width: 30; height: 26
                radius: Theme.radius
                color: mapArea.pressed ? Theme.line : Theme.cardHi
                border.color: Theme.line
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    // ⚠️ 必须过一层 !! 收敛成**严格布尔**：`rec && rec.matched` 在 matched
                    //    缺失时返回的是 undefined，赋给 font.bold（bool）会报
                    //    "Unable to assign [undefined] to bool" —— 而每行每帧一条，
                    //    设备的日志是写 flash 的，这种刷屏不能留。
                    text: matchedFlag ? "✓" : "?"
                    color: matchedFlag ? Theme.accent2 : Theme.textSub
                    font.pixelSize: matchedFlag ? 13 : 12
                    font.bold: matchedFlag
                }
                MouseArea {
                    id: mapArea
                    anchors.fill: parent
                    onClicked: {
                        confirming = false
                        if (localPage.controller) localPage.controller.openMatch(index)
                    }
                }
            }

            // 删除。二次确认放在行内（而不是弹窗）—— 320x170 上没有弹窗的空间，
            // 而且误删一首歌的代价只是重下一次，不值得占一整屏。
            Rectangle {
                id: delBox
                objectName: "gdLocalDelBtn"
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                width: confirming ? 46 : 30
                height: 26
                radius: Theme.radius
                // 确认态整块变红：底色一换，用户不用读字也知道"这一下会删"
                color: confirming ? Theme.danger
                                  : (delArea.pressed ? Theme.line : Theme.cardHi)
                border.color: confirming ? Theme.danger : Theme.line
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: confirming ? "确认?" : "×"
                    color: confirming ? "#FFFFFF" : Theme.textSub
                    font.pixelSize: confirming ? 10 : 15
                    font.bold: confirming
                }
                MouseArea {
                    id: delArea
                    anchors.fill: parent
                    onClicked: {
                        if (!localPage.controller) return
                        if (confirming) {
                            localPage.controller.deleteLocal(index)
                        } else {
                            confirming = true
                            confirmTimer.restart()
                        }
                    }
                }
                Timer {
                    id: confirmTimer
                    interval: 3000
                    onTriggered: confirming = false
                }
            }
        }

        Text {
            anchors.centerIn: parent
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: list.count === 0
            text: "还没有下载的歌\n在搜索页点右侧的下载箭头\n保存到 " + (localPage.controller
                  ? localPage.controller.downloadDir : "")
            color: Theme.textSub
            font.pixelSize: Theme.pxSmall
            lineHeight: 1.4
        }
    }

    // ---------- 底部：占用 + 下载进度 ----------
    Rectangle {
        y: parent.height - 22
        width: parent.width
        height: 22
        color: Theme.card

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: localPage.controller ? localPage.controller.localStat : ""
            color: Theme.textSub
            font.pixelSize: 9
        }

        // 有任务在下载时，右侧显示「首任务进度 + 队列长度」——
        // 数据源和顶部卡片同一个 dlQueueView，两处永远一致
        Text {
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            visible: localPage.controller && localPage.controller.dlQueueView.length > 0
            text: {
                if (!localPage.controller) return ""
                var v = localPage.controller.dlQueueView
                if (!v.length) return ""
                var e = v[0]
                var p = (e.pct >= 0) ? (e.pct + "%")
                      : (localPage.controller.sizeText(e.got) || "0 KB")
                return "下载中 " + p + (v.length > 1 ? (" · 共 " + v.length + " 首") : "")
            }
            color: Theme.accent
            font.pixelSize: 9
        }

        // 没有下载任务时，这个位置改放**长按提示** —— 长按是没有任何视觉痕迹的手势，
        // 不写出来用户永远不会发现，而底部栏反正是空着的，写着不占任何额外空间。
        Text {
            objectName: "gdLocalLongPressHint"
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            visible: !(localPage.controller && localPage.controller.dlQueueView.length > 0)
            text: "长按歌曲加入歌单"
            color: Theme.textSub
            font.pixelSize: 9
        }
    }
}
