import QtQuick 2.12
import ".."
import "../components" as Components

// 手动匹配页：给一个本地文件补上「它是哪首网易云歌」。
//
// 为什么需要它：插件自己下载的文件靠 localPathFor() 的「歌名-歌手.mp3」公式就能精确命中，
// 但被用户在文件管理器里改过名的、以及别的工具（LX-Pen 等）下载的文件命中不了。
// 有了这一页，用户可以「看着搜索结果点一下」把对应关系写进登记表（main.qml 的 fileMap），
// 之后这首歌在搜索页/歌单里点播就会走本地文件。
//
// 搜索词由 controller.openMatch() 用文件名**预填**，所以最常见的情况是：
// 进来直接点「搜索」→ 结果里第一条就对上 → 点一下 → 回本地页，徽标变 ✓。
Rectangle {
    id: matchPage
    width: 320
    height: 170
    color: Theme.bg

    property var controller: null

    // ⚠️ 一律用这两个函数而不是裸写 `a && b && c`：那种表达式在中间项为 null/undefined
    //    时返回的就是 null/undefined 本身，赋给 bool 属性会报
    //    "Unable to assign [undefined] to bool"，且每帧一条 —— 设备日志写 flash，不能留。
    function hasMatch() {
        return !!(matchPage.controller && matchPage.controller.matchRec
                  && matchPage.controller.matchRec.matched)
    }
    function hasRec() {
        return !!(matchPage.controller && matchPage.controller.matchRec)
    }

    Components.TitleBar {
        id: bar
        width: parent.width
        title: "匹配歌曲"
        showBack: true
        showSettings: false        // 匹配是"一条路走到底"的操作，别在右上角留容易误触的入口
        showTabs: false
        // 返回 = 回本地页（不是退出插件）—— 本页是本地页的下级
        onBackClicked: if (matchPage.controller) matchPage.controller.closeMatch()
        showPlayer: matchPage.controller ? matchPage.controller.hasNowPlaying : false
        onPlayerClicked: if (matchPage.controller) matchPage.controller.gotoPlayer()
    }

    // ---------- 搜索行：点输入框唤起键盘（预填的搜索词已在里面） ----------
    Row {
        id: searchRow
        objectName: "gdMatchSearchRow"
        y: 32
        x: 6
        width: parent.width - 12
        spacing: 6

        Rectangle {
            id: inputBox
            objectName: "gdMatchInputBox"
            width: searchRow.width - searchRow.spacing - goBtn.width
            height: 26
            radius: Theme.radius
            color: Theme.card
            border.color: Theme.line
            border.width: 1

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                text: matchPage.controller ? matchPage.controller.matchQuery : ""
                color: (matchPage.controller && matchPage.controller.matchQuery.length)
                       ? Theme.text : Theme.textSub
                font.pixelSize: Theme.pxSmall
                elide: Text.ElideRight
            }
            MouseArea {
                anchors.fill: parent
                onClicked: if (matchPage.controller) matchPage.controller.editMatchQuery()
            }
        }

        Rectangle {
            id: goBtn
            objectName: "gdMatchGoBtn"
            width: 48; height: 26
            radius: Theme.radius
            color: goArea.pressed ? Theme.cardHi : Theme.accent

            Text {
                anchors.centerIn: parent
                text: (matchPage.controller && matchPage.controller.matchBusy) ? "…" : "搜索"
                color: "#FFFFFF"
                font.pixelSize: Theme.pxSmall
                font.bold: true
            }
            MouseArea {
                id: goArea
                anchors.fill: parent
                onClicked: if (matchPage.controller) matchPage.controller.doMatchSearch()
            }
        }
    }

    // ---------- 当前文件 + 匹配状态 ----------
    // 文件名用**从文件名反推**的名字（而不是匹配后的真名），否则"文件"和"匹配到的歌"
    // 两行会显示成同一个字符串，用户看不出自己到底在给哪个文件做匹配。
    Rectangle {
        id: fileRow
        y: 60
        width: parent.width
        height: 18
        color: Theme.card

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.right: stateTag.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: {
                if (!matchPage.controller || !matchPage.controller.matchRec) return ""
                var r = matchPage.controller.matchRec
                return r.file ? String(r.file).replace(/^.*\//, "") : ""
            }
            color: Theme.textSub
            font.pixelSize: 9
            elide: Text.ElideMiddle
        }

        Text {
            id: stateTag
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: matchPage.hasMatch() ? "已匹配" : "未匹配"
            color: matchPage.hasMatch() ? Theme.accent2 : Theme.warn
            font.pixelSize: 9
            font.bold: true
        }
    }

    // ---------- 搜索结果 ----------
    ListView {
        id: list
        objectName: "gdMatchList"
        y: 78
        width: parent.width
        height: parent.height - y - 22
        clip: true
        model: matchPage.controller ? matchPage.controller.matchResults : null
        boundsBehavior: Flickable.StopAtBounds
        spacing: 1

        delegate: Rectangle {
            width: list.width
            height: 34
            color: itemArea.pressed ? Theme.cardHi : (index % 2 ? Theme.bg : Theme.card)

            property var song: modelData

            Column {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: tagBox.left
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
                    text: song && song.artist ? ("" + song.artist).replace(/,/g, " / ")
                          : (song && song.album ? song.album : "")
                    color: Theme.textSub
                    font.pixelSize: 9
                    elide: Text.ElideRight
                }
            }

            Rectangle {
                id: tagBox
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 34; height: 14
                radius: 3
                color: Theme.cardHi

                Text {
                    anchors.centerIn: parent
                    text: song && song.source ? song.source : ""
                    color: Theme.textSub
                    font.pixelSize: 8
                }
            }

            // 点一行 = 绑定。不给二次确认：绑错了再进来重绑一次即可（可逆），
            // 而多一次确认会让"连续给好几首补匹配"变得很烦。
            MouseArea {
                id: itemArea
                anchors.fill: parent
                onClicked: if (matchPage.controller) matchPage.controller.bindMatch(index)
            }
        }

        // 空态 / 搜索中：三个状态互斥，用一个 Text 表达，避免叠好几层
        Text {
            anchors.centerIn: parent
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: list.count === 0
            text: {
                if (!matchPage.controller) return ""
                if (matchPage.controller.matchBusy) return "搜索中…"
                return "点上面的搜索框改关键词\n结果里点一条即完成匹配"
            }
            color: Theme.textSub
            font.pixelSize: Theme.pxSmall
            lineHeight: 1.4
        }
    }

    // ---------- 底部：清除匹配 / 关闭 ----------
    Rectangle {
        y: parent.height - 22
        width: parent.width
        height: 22
        color: Theme.card

        // 清除匹配只在"确实已匹配"时出现 —— 否则会和"关闭"挤在一起，还可能误触
        Rectangle {
            id: clearBtn
            objectName: "gdMatchClearBtn"
            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 62; height: 20
            radius: 3
            visible: matchPage.hasMatch()
            color: clearArea.pressed ? Theme.line : Theme.cardHi
            border.color: Theme.danger
            border.width: 1

            Text {
                anchors.centerIn: parent
                text: "清除匹配"
                color: Theme.danger
                font.pixelSize: 9
            }
            MouseArea {
                id: clearArea
                anchors.fill: parent
                onClicked: if (matchPage.controller) matchPage.controller.clearMatch()
            }
        }

        Rectangle {
            objectName: "gdMatchCloseBtn"
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 48; height: 20
            radius: 3
            color: closeArea.pressed ? Theme.line : Theme.cardHi
            border.color: Theme.line
            border.width: 1

            Text {
                anchors.centerIn: parent
                text: "关闭"
                color: Theme.textSub
                font.pixelSize: 9
            }
            MouseArea {
                id: closeArea
                anchors.fill: parent
                onClicked: if (matchPage.controller) matchPage.controller.closeMatch()
            }
        }
    }
}
