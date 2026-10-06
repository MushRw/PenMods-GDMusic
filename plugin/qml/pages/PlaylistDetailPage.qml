import QtQuick 2.12
import ".."
import "../components" as Components

// 歌单详情页（列表页里点一行进来）。
//
// 数据来源一律走 controller.plView —— 它每次都返回**新建的对象 + slice 出来的新数组**，
// 所以歌单内容一变，这里的列表必然重建。为什么不能直接读 playlistById().songs 见
// main.qml 里 plView 的注释（外层数组拷贝、歌单对象仍是同一引用 ⇒ 绑定可能不重算）。
Rectangle {
    id: detailPage
    width: 320
    height: 170
    color: Theme.bg

    property var controller: null

    // null = 歌单已被删/没打开（当作空处理，不能让它一路 undefined 传下去）
    readonly property var pl: detailPage.controller ? detailPage.controller.plView : null
    readonly property var songs: pl ? pl.songs : []
    readonly property int  count: pl ? pl.count : 0
    readonly property bool offline: !!(pl && pl.type === "local")
    // 来源：网易云同步来的歌单（详情页给一个红色「网易云」徽标）
    readonly property bool fromNc: !!(pl && pl.source === "netease")

    Components.TitleBar {
        id: bar
        width: parent.width
        title: pl && pl.name ? pl.name : "歌单"
        showBack: true
        showSettings: false        // 详情是"一条路走到底"的操作面，右上角别留容易误触的入口
        showTabs: false
        // 返回 = 回歌单列表（本页是歌单页的下级），不是退出插件
        onBackClicked: if (detailPage.controller) detailPage.controller.closePlaylistDetail()
        showPlayer: detailPage.controller ? detailPage.controller.hasNowPlaying : false
        onPlayerClicked: if (detailPage.controller) detailPage.controller.gotoPlayer()
    }

    // ---------- 工具行：播放全部 + 类型 ----------
    Rectangle {
        id: actionRow
        objectName: "gdPlDetailActionRow"
        y: 32
        width: parent.width
        height: 28
        color: Theme.bg

        // 「播放全部」= IconButton 的 Canvas 三角 + 一行文字。
        // 不用 "▶" 这种字形：设备字体里 U+25xx 那批基本没字形，会显示成豆腐块
        //（搜索页的时钟是 Canvas 画的、整行播放键用 Canvas 画三角，都是同一个原因）。
        Row {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            Components.IconButton {
                id: playAllBtn
                objectName: "gdPlPlayAllBtn"
                width: 34
                height: 24
                kind: "play"
                // 空歌单时三角灰掉（按钮本色不变）—— 用颜色表达"点了也没用"，
                // 比点了再弹一句「歌单是空的」少一次无效交互。
                tint: detailPage.count ? Theme.accent : Theme.textSub
                onClicked: {
                    if (!detailPage.controller || !detailPage.pl || !detailPage.count) return
                    detailPage.controller.playPlaylistUI(detailPage.pl.id, 0)
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "播放全部"
                color: detailPage.count ? Theme.text : Theme.textSub
                font.pixelSize: Theme.pxSmall
                font.bold: !!detailPage.count
            }
        }

        // 右侧徽标组：来源 + 类型。用 Row 串起来，两个徽标的间距由 spacing 管，
        // 别各自 anchors.right 叠算边距（加第三个时会算错）。
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            // 来源徽标：网易云同步来的歌单。红色是网易云的品牌色，跟「在线/离线」
            // 的蓝/绿（Theme.accent / accent2）不撞色，语义也不混。
            Rectangle {
                objectName: "gdPlDetailSrcTag"
                width: 40; height: 14
                radius: 3
                color: Theme.cardHi
                border.color: "#E60026"
                border.width: 1
                visible: detailPage.fromNc

                Text {
                    anchors.centerIn: parent
                    text: "网易云"
                    color: "#E60026"
                    font.pixelSize: 8
                }
            }

            Rectangle {
                objectName: "gdPlDetailTypeTag"
                width: 34; height: 14
                radius: 3
                color: Theme.cardHi
                border.color: detailPage.offline ? Theme.accent2 : Theme.accent
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: detailPage.offline ? "离线" : "在线"
                    color: detailPage.offline ? Theme.accent2 : Theme.accent
                    font.pixelSize: 8
                }
            }
        }
    }

    // ---------- 曲目列表 ----------
    ListView {
        id: list
        objectName: "gdPlDetailList"
        y: 62
        width: parent.width
        height: parent.height - y - 22
        clip: true
        model: detailPage.songs
        boundsBehavior: Flickable.StopAtBounds
        spacing: 1

        delegate: Rectangle {
            width: list.width
            height: 34
            color: itemArea.pressed ? Theme.cardHi : (index % 2 ? Theme.bg : Theme.card)

            property var song: modelData
            property bool confirming: false
            // 在线条目 + 真的会走本地才亮 ✓。用 controller.localFileOf（= resolveEntry 的判据，
            // 含 minLocalBytes）而不是 isDownloaded：徽标要回答的正是"点下去走不走本地"，
            // 判据不一致就会出现「显示 ✓ 却在联网取流」这种自相矛盾。
            // 本地条目本来就播本地，不给它亮 ✓ —— 整个离线歌单每行都带勾等于没信息。
            readonly property bool localHit: !!(song && !song.file && detailPage.controller
                                                && detailPage.controller.localFileOf(song).length)
            function subText() {
                if (!song) return ""
                var a = song.artist ? String(song.artist).replace(/,/g, " / ") : ""
                if (song.file && detailPage.controller) {
                    var s = detailPage.controller.sizeText(song.size)
                    return (a.length ? a + " · " : "") + s
                }
                return a
            }

            // ❗整行点击区必须【最先声明】（同本地页/搜索页的说明）：同 z 下后声明的在上层，
            //    写在 × 后面就会把移除键的点击吃掉、变成「播这首」。
            MouseArea {
                id: itemArea
                objectName: "gdPlSongTapArea"
                anchors.fill: parent
                // 长按 = 把这歌加进**另一个**歌单（把歌单当"集合"来用时的常见需求）。
                // 守卫见 LocalPage 里 itemArea 的注释。
                property bool longFired: false
                // 显式设值：默认间隔取自 QStyleHints，平台返回 -1（不支持）时长按是死代码。
                // 详见 LocalPage 里 itemArea 的同一处注释。
                pressAndHoldInterval: 700
                onPressedChanged: if (pressed) longFired = false
                onPressAndHold: {
                    longFired = true
                    confirming = false
                    if (detailPage.controller)
                        detailPage.controller.openAddPick(detailPage.songs[index])
                }
                onClicked: {
                    if (longFired) { longFired = false; return }
                    confirming = false
                    if (detailPage.controller && detailPage.pl)
                        detailPage.controller.playPlaylistUI(detailPage.pl.id, index)
                }
            }

            Column {
                anchors.left: parent.left
                anchors.leftMargin: 8
                // 右侧锚到固定占位的 hitSlot（而不是 `hitTag.visible ? hitTag.left : delBox.left`）：
                // 三元两个分支一个返回 Item、一个返回 AnchorLine，类型不同，
                // QML 会在赋值时报 "Unable to assign ..." —— 用容器把宽度固定住最省事。
                anchors.right: hitSlot.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                    width: parent.width
                    text: song && song.name ? song.name : ""
                    color: Theme.text
                    font.pixelSize: Theme.pxSmall
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: subText()
                    color: Theme.textSub
                    font.pixelSize: 9
                    elide: Text.ElideRight
                }
            }

            // 本地命中指示（只读，不是按钮）。固定占位，不亮时也占着那 14px ——
            // 否则文字列宽度会随每行的命中情况跳来跳去，整列左边界看起来是锯齿。
            Item {
                id: hitSlot
                objectName: "gdPlDetailHitSlot"
                anchors.right: delBox.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                width: 14
                height: 26

                Text {
                    id: hitTag
                    objectName: "gdPlDetailHitTag"
                    anchors.centerIn: parent
                    // ⚠️ 过一层 !! 收敛成严格布尔：`song && !song.file && …` 在中间项为
                    //    undefined 时返回的就是 undefined 本身，赋给 visible（bool）会刷
                    //    "Unable to assign [undefined] to bool"，且每帧一条（日志写 flash）。
                    visible: localHit
                    text: "✓"
                    color: Theme.accent2
                    font.pixelSize: 12
                    font.bold: true
                }
            }

            // 从歌单移除。二次确认放在行内而不是弹窗 —— 行内变身只需一次点击，
            // 弹窗在 320×170 上要占掉整屏，而误删一首只是重新加回来，代价不对称。
            Rectangle {
                id: delBox
                objectName: "gdPlSongDelBtn"
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                width: confirming ? 46 : 30
                height: 26
                radius: Theme.radius
                color: confirming ? Theme.danger : (delArea.pressed ? Theme.line : Theme.cardHi)
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
                        if (!detailPage.controller || !detailPage.pl) return
                        if (confirming) {
                            detailPage.controller.removeSongAtUI(detailPage.pl.id, index)
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
            text: detailPage.offline
                  ? "歌单是空的\n离线歌单只收已下载的歌"
                  : "歌单是空的\n从搜索页和本地页把歌加进来"
            color: Theme.textSub
            font.pixelSize: Theme.pxSmall
            lineHeight: 1.4
        }
    }

    // ---------- 底部：统计 + 操作提示 ----------
    Rectangle {
        y: parent.height - 22
        width: parent.width
        height: 22
        color: Theme.card

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: "共 " + detailPage.count + " 首"
            color: Theme.textSub
            font.pixelSize: 9
        }

        Text {
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: "点行播放 · × 移除 · 长按加歌单"
            color: Theme.textSub
            font.pixelSize: 9
        }
    }
}
