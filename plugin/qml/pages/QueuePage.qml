import QtQuick 2.12
import ".."
import "../components" as Components

// 当前播放队列（播放列表）。
//
// 2026-10-06 新增：在此之前 `queue` 这个数据存在，但**一个像素的界面都没有** ——
// 用户看不见队列里有什么，也没法点某一首跳过去，唯一让播放相关界面出现的办法是
// 「重新点一首歌播一遍」。这个页 + TitleBar 上那个 ▶ 一起补上这个缺口。
//
// 设计上刻意做成播放页的**下游页**：返回一律回播放页，不单独记"来处"状态
// （少一个变量就少一处能自污染的地方 —— backPage 那次事故就是变量复用的代价）。
Rectangle {
    id: queuePage
    width: 320
    height: 170
    color: Theme.bg

    property var controller: null

    Components.TitleBar {
        id: bar
        width: parent.width
        title: "播放队列"
        showBack: true
        // 队列页已经是"正在播放"的下游，再显示 ▶ 就成了自己进自己。
        showPlayer: false
        showSettings: false
        showTabs: false
        onBackClicked: if (queuePage.controller) queuePage.controller.goQueueBack()
    }

    ListView {
        id: list
        objectName: "gdQueueList"
        y: 32
        width: parent.width
        // ⚠️ 必须显式减掉 TitleBar：Column/ListView 不会因为父容器就自己算高度，
        //    忘了给就会一路画到屏幕外面（QML 里这是"看不见的最后几项"的头号原因）。
        height: parent.height - y
        clip: true
        model: queuePage.controller ? queuePage.controller.queue : null
        boundsBehavior: Flickable.StopAtBounds
        spacing: 1

        delegate: Rectangle {
            width: list.width
            height: 34
            readonly property var rec: modelData
            readonly property bool isCur: index === (queuePage.controller ? queuePage.controller.queueIndex : -1)

            color: isCur ? Theme.cardHi : (index % 2 ? Theme.bg : Theme.card)

            // 当前正在播的那首：左侧一条 accent 竖条。只用颜色区分不够 ——
            // 320×170 上一行只有 34px 高，深色差比纯色带更容易被一眼看到。
            Rectangle {
                width: 3
                height: parent.height - 8
                anchors.left: parent.left
                anchors.leftMargin: 2
                anchors.verticalCenter: parent.verticalCenter
                radius: 1
                color: Theme.accent
                visible: isCur
            }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 8
                spacing: 6

                Text {
                    width: 22
                    anchors.verticalCenter: parent.verticalCenter
                    // 当前这首显示播放符号，其余显示序号
                    text: isCur ? "▶" : (index + 1)
                    color: isCur ? Theme.accent : Theme.textSub
                    font.pixelSize: Theme.pxSmall
                    horizontalAlignment: Text.AlignLeft
                }

                Column {
                    // ⚠️ Row 里的 Column 必须自己算宽度：Column 既不撑开也不裁剪，
                    //    忘了给 width 就会溢出到右边（QML 里"文字画出界"的常见根因）。
                    width: parent.width - 22 - parent.spacing * 2
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        width: parent.width
                        text: (rec && rec.name) ? rec.name : "(无标题)"
                        color: isCur ? Theme.accent : Theme.text
                        font.pixelSize: Theme.pxSmall
                        font.bold: isCur
                        elide: Text.ElideRight
                    }
                    Text {
                        width: parent.width
                        // 队列里混着在线歌与本地已下载歌，两者的歌手字段可能没有，
                        // 统一兜一手，避免出现一片空白行看着像渲染坏了。
                        text: (rec && rec.artist) ? rec.artist : "未知歌手"
                        color: Theme.textSub
                        font.pixelSize: Theme.pxSmall
                        elide: Text.ElideRight
                    }
                }
            }

            // ⚠️ 整行点击区放在最后声明 —— 但这里 Row/Column **没有交互元素**
            //    （本地页那行的坑是有 ?/× 按钮时被覆盖），所以没有遮挡风险。
            //    真要加删除按钮时，记得把 MouseArea 移到按钮【之前】声明。
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (!queuePage.controller) return
                    // 点当前这首 = 不改变队列内容，只是回到播放页看封面/歌词
                    queuePage.controller.playQueueAt(index)
                }
            }
        }
    }

    Text {
        anchors.centerIn: parent
        text: "队列是空的\n先去搜一首歌播放吧"
        color: Theme.textSub
        font.pixelSize: Theme.pxSmall
        horizontalAlignment: Text.AlignHCenter
        visible: !list.count
    }
}
