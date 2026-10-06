import QtQuick 2.12
import ".."
import "../components" as Components

Rectangle {
    id: playerPage
    width: 320
    height: 170
    color: Theme.bg

    property var controller: null

    Components.TitleBar {
        id: bar
        width: parent.width
        title: "正在播放"
        onBackClicked: if (playerPage.controller) playerPage.controller.goPlayerBack()
        onSettingsClicked: if (playerPage.controller) playerPage.controller.openSettings()
    }

    // ---------- 曲目信息 ----------
    Rectangle {
        id: cover
        x: 8; y: 36
        width: 26; height: 26
        radius: 4
        color: Theme.card
        visible: playerPage.controller && playerPage.controller.coverUrl.length > 0

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
    }

    Column {
        x: (cover.visible ? 40 : 8)
        y: 36
        width: parent.width - x - 8
        spacing: 1

        Text {
            width: parent.width
            text: (playerPage.controller && playerPage.controller.currentSong
                   && playerPage.controller.currentSong.name)
                  ? playerPage.controller.currentSong.name : "未在播放"
            color: Theme.text
            font.pixelSize: 13
            font.bold: true
            elide: Text.ElideRight
        }
        Text {
            width: parent.width
            text: playerPage.controller && playerPage.controller.currentSong
                  ? ("" + (playerPage.controller.currentSong.artist || "")).replace(/,/g, " / ")
                  : ""
            color: Theme.textSub
            font.pixelSize: 9
            elide: Text.ElideRight
        }
    }

    // ---------- 进度条 ----------
    Text {
        id: posText
        x: 8; y: 66
        text: playerPage.controller ? playerPage.controller.fmtTime(playerPage.controller.timePos) : "00:00"
        color: Theme.textSub
        font.pixelSize: 9
    }
    Text {
        id: durText
        anchors.right: parent.right
        anchors.rightMargin: 8
        y: 66
        text: playerPage.controller ? playerPage.controller.fmtTime(playerPage.controller.duration) : "00:00"
        color: Theme.textSub
        font.pixelSize: 9
    }

    Rectangle {
        id: progBg
        x: 8
        y: 78
        width: parent.width - 16
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
            anchors.topMargin: -6
            anchors.bottomMargin: -6
            onClicked: {
                if (!playerPage.controller) return
                playerPage.controller.seekRatio(mouse.x / width)
            }
        }
    }

    // ---------- 控制按钮 ----------
    Row {
        x: 8
        y: 92
        spacing: 2

        Components.IconButton {
            kind: "prev"
            onClicked: if (playerPage.controller) playerPage.controller.prev()
        }
        Components.IconButton {
            width: 40
            kind: (playerPage.controller && !playerPage.controller.paused) ? "pause" : "play"
            tint: Theme.accent
            onClicked: if (playerPage.controller) playerPage.controller.togglePause()
        }
        Components.IconButton {
            kind: "next"
            onClicked: if (playerPage.controller) playerPage.controller.next()
        }

        // 下载当前曲目。
        Components.IconButton {
            kind: "download"
            tint: {
                if (!playerPage.controller || !playerPage.controller.currentSong) return Theme.textSub
                if (playerPage.controller.isDownloaded(playerPage.controller.currentSong))
                    return Theme.accent2
                var s = playerPage.controller.dlStatus(playerPage.controller.currentSong)
                return (s === "run" || s === "wait") ? Theme.accent
                     : (s === "fail") ? Theme.danger : Theme.textSub
            }
            onClicked: if (playerPage.controller)
                       playerPage.controller.downloadSong(playerPage.controller.currentSong)
        }

        // 与左侧拉开 8px：视觉上把「播控 / 下载」和「收藏」分成两组。
        // 两个 36 宽的键中心只差 38px，手指落在缝上很容易误触 —— 加歌单要点得准。
        Item { width: 8; height: 1 }

        // 加入歌单。这是**唯一一个不依赖长按的加歌入口** ——
        // 播放页上"正在听的这首"永远有它，不挑当前在哪个列表、也不用记住任何手势。
        Components.IconButton {
            objectName: "gdPlayerAddBtn"
            kind: "plus"
            tint: Theme.accent2
            onClicked: if (playerPage.controller)
                       playerPage.controller.openAddPick(playerPage.controller.currentSong)
        }

        // 播放队列（当前播放列表）—— 整个插件里唯一通往队列页的入口。
        // 放在最末：它是"离开本页去看列表"的出口，与前面的播控/加歌不是同一类动作，
        // 摆在最远端能降低误触。
        Components.IconButton {
            objectName: "gdPlayerQueueBtn"
            kind: "queue"
            // 队列里有多首时才高亮：只有一首的话，点进去既没得看也没处跳。
            tint: (playerPage.controller && playerPage.controller.queue
                   && playerPage.controller.queue.length > 1) ? Theme.accent : Theme.textSub
            onClicked: if (playerPage.controller) playerPage.controller.openQueue()
        }
    }

    // ---------- （原音量条位置：已移除）----------
    // 音量不再由插件控制 —— mpv 保持默认 100 不衰减，交给系统的音量键统一管。
    // 插件里再叠一层衰减，会让「系统音量拉满声音还是小」变成一个说不清的 bug。

    // ---------- 歌词 / 状态 ----------
    Rectangle {
        id: lyricBox
        x: 8
        y: 120
        width: parent.width - 16
        height: parent.height - y - 6
        radius: Theme.radius
        color: Theme.card
        clip: true

        Column {
            anchors.centerIn: parent
            width: parent.width - 12
            spacing: 2

            Text {
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
                font.pixelSize: Theme.pxSmall
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
            Text {
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
                font.pixelSize: 9
                elide: Text.ElideRight
            }
        }
    }
}
