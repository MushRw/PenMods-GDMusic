import QtQuick 2.12
import ".."
import "../components" as Components

Rectangle {
    id: searchPage
    width: 320
    height: 170
    color: Theme.bg

    property var controller: null

    Components.TitleBar {
        id: bar
        width: parent.width
        title: "GD 音乐"
        showBack: true
        showLocal: false
        showTabs: true
        tabIndex: 0
        // 第二个标签带下载角标：「本地(↓2)」= 还有 2 个任务在队列里，
        // 让用户在搜索页也能看到下载没被丢下。dlTabLabel 在 controller 里算好。
        // 第三个是歌单页 —— 三者平级，互相一步可达。
        tabLabels: ["搜索", searchPage.controller ? searchPage.controller.dlTabLabel : "本地", "歌单"]
        // 搜索页是本插件的根页面，返回箭头 = 退出插件（框架约定 backButtonClicked）。
        onBackClicked: if (searchPage.controller) searchPage.controller.exitPlugin()
        // ▶ 回到正在播放：播过歌之后任何页面都能一步回去（详见 main.qml 的 hasNowPlaying）
        showPlayer: searchPage.controller ? searchPage.controller.hasNowPlaying : false
        onPlayerClicked: if (searchPage.controller) searchPage.controller.gotoPlayer()
        onSettingsClicked: if (searchPage.controller) searchPage.controller.openSettings()
        onTabClicked: {
            if (!searchPage.controller) return
            if (index === 1)      searchPage.controller.goLocal()
            else if (index === 2) searchPage.controller.goPlaylists()
        }
    }

    // ---------- 音源 + 搜索框 ----------
    Row {
        id: searchRow
        objectName: "gdSearchRow"
        y: 32
        width: parent.width - 12
        x: 6
        spacing: 6

        Rectangle {
            id: sourceBtn
            width: 62; height: 26
            radius: Theme.radius
            color: srcArea.pressed ? Theme.cardHi : Theme.card
            border.color: Theme.line
            border.width: 1

            Text {
                anchors.centerIn: parent
                text: searchPage.controller ? searchPage.controller.sourceLabel() : "音源"
                color: Theme.accent
                font.pixelSize: Theme.pxSmall
                font.bold: true
            }
            MouseArea {
                id: srcArea
                anchors.fill: parent
                onClicked: {
                    if (searchPage.controller) searchPage.controller.historyOpen = false
                    sourcePopup.visible = !sourcePopup.visible
                }
            }
        }

        Rectangle {
            id: inputBox
            objectName: "gdInputBox"
            // Row 里 4 个孩子 = 3 条 spacing，别漏算 —— 少减一条就会把搜索按钮挤出屏幕
            width: searchRow.width - sourceBtn.width - searchRow.spacing * 3 - goBtn.width - histBtn.width
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
                text: (searchPage.controller && searchPage.controller.keyword.length)
                      ? searchPage.controller.keyword : "点这里输入歌名/歌手"
                color: (searchPage.controller && searchPage.controller.keyword.length)
                       ? Theme.text : Theme.textSub
                font.pixelSize: Theme.pxSmall
                elide: Text.ElideRight
            }
            MouseArea {
                anchors.fill: parent
                onClicked: if (searchPage.controller) searchPage.controller.openKeyboard()
            }
        }

        // 历史搜索。用 Canvas 画时钟而不是 Text 放字形：设备字体里 U+1F55x 那批
        // 符号基本没有字形，写了会显示成豆腐块。
        Rectangle {
            id: histBtn
            objectName: "gdBtnHistory"
            width: 24; height: 26
            radius: Theme.radius
            color: histArea.pressed ? Theme.cardHi : Theme.card

            property bool active: !!(searchPage.controller && searchPage.controller.historyOpen)
            border.color: histBtn.active ? Theme.accent : Theme.line
            border.width: 1

            // Canvas 只在 requestPaint() 时重绘，而 historyOpen 是随时变的，
            // 光写绑定不会自己刷新 —— 得显式请求一次。
            onActiveChanged: clock.requestPaint()

            Canvas {
                id: clock
                anchors.centerIn: parent
                width: 14; height: 14
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    ctx.strokeStyle = histBtn.active ? Theme.accent : Theme.textSub;
                    ctx.lineWidth = 1.3;
                    ctx.lineCap = "round";
                    ctx.beginPath(); ctx.arc(7, 7, 5.2, 0, Math.PI * 2); ctx.stroke();
                    ctx.beginPath();
                    ctx.moveTo(7, 7); ctx.lineTo(7, 3.6);
                    ctx.moveTo(7, 7); ctx.lineTo(9.8, 7);
                    ctx.stroke();
                }
            }
            MouseArea {
                id: histArea
                anchors.fill: parent
                onClicked: {
                    if (!searchPage.controller) return
                    // 两个弹层互斥：同时打开时 z 排序会让「点空白」层吃掉音源弹层的点击
                    sourcePopup.visible = false
                    searchPage.controller.historyOpen = !searchPage.controller.historyOpen
                }
            }
        }

        Rectangle {
            id: goBtn
            objectName: "gdBtnGo"
            width: 40; height: 26
            radius: Theme.radius
            color: goArea.pressed ? Theme.cardHi : Theme.accent

            Text {
                id: goBtnIcon
                anchors.centerIn: parent
                text: "搜索"
                color: "#FFFFFF"
                font.pixelSize: Theme.pxSmall
                font.bold: true
            }
            MouseArea {
                id: goArea
                anchors.fill: parent
                onClicked: if (searchPage.controller) searchPage.controller.doSearch()
            }
        }
    }

    // ---------- 结果列表 ----------
    ListView {
        id: list
        objectName: "gdResultList"
        y: 62
        width: parent.width
        height: parent.height - y
        clip: true
        model: searchPage.controller ? searchPage.controller.results : null
        boundsBehavior: Flickable.StopAtBounds
        spacing: 1

        delegate: Rectangle {
            width: list.width
            height: 34
            color: itemArea.pressed ? Theme.cardHi : (index % 2 ? Theme.bg : Theme.card)

            property var song: modelData

            // ❗整行点击区必须【最先声明】（同 LocalPage 里的说明）：后声明的在上层，
            //    它覆盖整行，写在下载按钮后面就会把「↓」的点击吃掉、变成「播放这首」。
            MouseArea {
                id: itemArea
                objectName: "gdRowTapArea"
                anchors.fill: parent
                // 长按 = 加入歌单。守卫的来龙去脉见 LocalPage 里 itemArea 的注释
                //（Qt 长按后一般不再发 clicked，但这一条不该靠"一般"活着）。
                property bool longFired: false
                // 显式设值：默认间隔取自 QStyleHints，平台返回 -1（不支持）时长按是死代码。
                // 详见 LocalPage 里 itemArea 的同一处注释。
                pressAndHoldInterval: 700
                onPressedChanged: if (pressed) longFired = false
                onPressAndHold: {
                    longFired = true
                    if (searchPage.controller)
                        searchPage.controller.openAddPick(searchPage.controller.results[index])
                }
                onClicked: {
                    if (longFired) { longFired = false; return }
                    if (searchPage.controller) searchPage.controller.playFrom(index)
                }
            }

            Row {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: dlBox.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
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
            }

            // 下载按钮。颜色即状态：灰=可下载 / 蓝=进行中 / 绿=已下载 / 红=失败
            Rectangle {
                id: dlBox
                objectName: "gdSearchDlBtn"
                anchors.right: tagBox.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                // 30×26（原 22×22）+ 底色 + 描边：原来背景是 transparent，
                // 用户既看不出这是按钮、也看不出可点范围在哪，只能靠猜着点。
                width: 30; height: 26
                radius: Theme.radius
                visible: searchPage.controller !== null
                color: dlArea.pressed ? Theme.line : Theme.cardHi
                border.color: Theme.line
                border.width: 1

                // 用「字形 + 颜色」表示状态，而不是 Canvas 画图形：
                // Canvas 只有在 requestPaint() 时才重绘，而下载状态是随时间变的，
                // 挂定时器逐行重绘太浪费；Text 的 color/text 是纯绑定，会自动跟着变。
                Text {
                    anchors.centerIn: parent
                    text: dlBox.glyph()
                    color: dlBox.stateColor()
                    font.pixelSize: 15
                    font.bold: true
                }

                // modelData 在 QML 里是 var，直接比较 id 即可判断有没有下过
                function dlStateOf() {
                    if (!searchPage.controller || !song) return ""
                    if (searchPage.controller.isDownloaded(song)) return "ok"
                    var s = searchPage.controller.dlStatus(song)
                    return s.length ? s : ""
                }
                function glyph() {
                    switch (dlStateOf()) {
                    case "ok":    return "✓"
                    case "run":   return "⋯"
                    case "queue":
                    case "wait":  return "⋯"
                    case "fail":  return "!"
                    default:      return "↓"
                    }
                }
                function stateColor() {
                    switch (dlStateOf()) {
                    case "ok":    return Theme.accent2
                    case "run":
                    case "queue":
                    case "wait":  return Theme.accent
                    case "fail":  return Theme.danger
                    default:      return Theme.textSub
                    }
                }

                MouseArea {
                    id: dlArea
                    anchors.fill: parent
                    onClicked: {
                        if (!searchPage.controller || !song) return
                        if (searchPage.controller.isDownloaded(song)) {
                            searchPage.controller.toastMsg("已经下载过了")
                            return
                        }
                        searchPage.controller.downloadSong(song)
                    }
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
        }

        // 空状态
        Text {
            anchors.centerIn: parent
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: list.count === 0
            text: searchPage.controller && searchPage.controller.searching
                  ? "搜索中…"
                  : (searchPage.controller && searchPage.controller.lastMsg
                     ? searchPage.controller.lastMsg
                     : "输入关键词开始搜索\n音源由 GD音乐台 提供")
            color: Theme.textSub
            font.pixelSize: Theme.pxSmall
            lineHeight: 1.4
        }
    }

    // ---------- 搜索历史浮层 ----------
    // 放在列表上方而不是另开一页：屏幕只有 320×170，切页会把搜索框一起藏掉，
    // 而「点历史 → 改词 → 再搜」恰恰需要一直看得见输入框。
    Rectangle {
        id: historyPopup
        objectName: "gdHistoryPopup"
        visible: !!(searchPage.controller && searchPage.controller.historyOpen)
        z: 95
        x: 6
        y: 60
        width: parent.width - 12
        height: Math.min(parent.height - y - 2, 22 + Math.max(1, histList.count) * 24 + 4)
        radius: Theme.radius
        color: "#F2242833"
        border.color: Theme.line
        border.width: 1

        // 标题行：「历史搜索」+ 右侧清空
        Rectangle {
            id: histHead
            x: 3; y: 3
            width: parent.width - 6
            height: 18
            color: "transparent"

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                text: "历史搜索"
                color: Theme.textSub
                font.pixelSize: 9
            }
            Text {
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                text: "清空"
                color: Theme.accent
                font.pixelSize: 9
                visible: histList.count > 0
            }
            MouseArea {
                anchors.right: parent.right
                width: 44; height: parent.height
                onClicked: if (searchPage.controller) searchPage.controller.clearHistory()
            }
        }

        ListView {
            id: histList
            objectName: "gdHistoryList"
            x: 3
            y: 22
            width: parent.width - 6
            height: parent.height - y - 3
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: searchPage.controller ? searchPage.controller.searchHistory : []

            delegate: Rectangle {
                width: histList.width
                height: 24
                radius: 3
                color: hArea.pressed ? Theme.cardHi : "transparent"

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 6
                    anchors.right: hDel.left
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData
                    color: Theme.text
                    font.pixelSize: Theme.pxSmall
                    elide: Text.ElideRight
                }
                // 删除单项。用 Text 画叉而不是图片：插件是纯 QML 免编译的，
                // 不带二进制资源，字形是唯一稳的路子。
                Rectangle {
                    id: hDel
                    objectName: "gdHistDelBtn"
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    width: 26; height: 20
                    radius: Theme.radius
                    color: delArea.pressed ? Theme.line : Theme.cardHi
                    border.color: Theme.line
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        color: Theme.textSub
                        font.pixelSize: 14
                    }
                    // ❗声明在 hArea 之后：同 z 下后声明的先拿事件，
                    // 否则点叉会穿透成「搜索这个词」。
                    MouseArea {
                        id: delArea
                        anchors.fill: parent
                        onClicked: if (searchPage.controller) searchPage.controller.removeHistoryAt(index)
                    }
                }
                MouseArea {
                    id: hArea
                    anchors.fill: parent
                    onClicked: if (searchPage.controller) searchPage.controller.searchWord(modelData)
                }
            }

            Text {
                anchors.centerIn: parent
                width: parent.width - 20
                horizontalAlignment: Text.AlignHCenter
                visible: histList.count === 0
                text: "还没有搜索记录"
                color: Theme.textSub
                font.pixelSize: Theme.pxSmall
            }
        }
    }

    // ---------- 音源弹层 ----------
    Rectangle {
        id: sourcePopup
        visible: false
        z: 90
        x: 6
        y: 60
        width: 96
        height: srcCol.height + 8
        radius: Theme.radius
        color: "#F2242833"
        border.color: Theme.line
        border.width: 1

        Column {
            id: srcCol
            x: 4; y: 4
            width: parent.width - 8

            Repeater {
                model: searchPage.controller ? searchPage.controller.sources : []
                delegate: Rectangle {
                    width: srcCol.width
                    height: 22
                    radius: 3
                    color: sArea.pressed ? Theme.cardHi : "transparent"

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: (searchPage.controller && searchPage.controller.source === modelData.id)
                               ? Theme.accent : Theme.text
                        font.pixelSize: Theme.pxSmall
                    }
                    MouseArea {
                        id: sArea
                        anchors.fill: parent
                        onClicked: {
                            if (searchPage.controller) searchPage.controller.setSource(modelData.id)
                            sourcePopup.visible = false
                        }
                    }
                }
            }
        }
    }

    // 点空白关闭弹层。
    // ❗z 是动态的，不能写成常量：Qt 按 z 从高到低派发，z 最高的「点空白」层会
    // 把点击全吃掉，导致浮在它下面的弹层（音源 z=90 / 历史 z=95）点不动。
    // 所以只有历史打开时才升到 94（刚好低于历史的 95），其余时候留在 80（低于音源的 90）。
    MouseArea {
        anchors.fill: parent
        z: historyPopup.visible ? 94 : 80
        visible: sourcePopup.visible || historyPopup.visible
        onClicked: {
            sourcePopup.visible = false
            if (searchPage.controller) searchPage.controller.historyOpen = false
        }
    }
}
