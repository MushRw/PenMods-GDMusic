import QtQuick 2.12
import ".."
import "../components" as Components

// 「加入歌单」页 —— 把一首歌放进某个歌单。
//
// 为什么单独一页而不是浮层：320×170 上叠两层浮层后，下层被盖住的部分既看不见也
// 点不到，用户会以为界面卡住了；而且歌单最多 20 个，浮层那点高度根本滚不动。
// 页面形态与匹配页一致（返回回原页），代码也就能照着同一套模式写。
//
// 页内两态（controller.addPickStep）：
//   "list" —— 列歌单，点可加的那一行即完成
//   "type" —— 新建歌单时选类型（键盘是宿主整屏页，必须先定类型再弹）
Rectangle {
    id: pickPage
    width: 320
    height: 170
    color: Theme.bg

    property var controller: null

    readonly property var entries: pickPage.controller ? pickPage.controller.addPickEntries : []
    readonly property var song:    pickPage.controller ? pickPage.controller.addPickSong    : null
    readonly property string step: pickPage.controller ? pickPage.controller.addPickStep    : "list"

    // 载体带不带某种形态 —— 决定 type 态里哪一项可选、也决定第二行的形态标签。
    // 一律过一层 !! 收敛成严格布尔：`a && b` 在缺项时返回的是 undefined 本身，
    // 赋给 bool 属性会刷 "Unable to assign [undefined] to bool"（设备日志写 flash）。
    readonly property bool canOnline: !!(pickPage.song && pickPage.song.id)
    readonly property bool canLocal:  !!(pickPage.song && pickPage.song.file)

    function shapeText() {
        if (pickPage.canOnline && pickPage.canLocal) return "在线 · 已下载"
        if (pickPage.canLocal)  return "已下载"
        if (pickPage.canOnline) return "在线"
        return ""
    }

    function songName() {
        if (!pickPage.song) return ""
        var n = pickPage.song.name   ? String(pickPage.song.name) : ""
        var a = pickPage.song.artist ? String(pickPage.song.artist).replace(/,/g, " / ") : ""
        if (a.length) return n.length ? (n + " · " + a) : a
        return n
    }

    Components.TitleBar {
        id: bar
        width: parent.width
        title: (pickPage.step === "type") ? "新建歌单" : "加入歌单"
        showBack: true
        showSettings: false
        showTabs: false
        // 返回键在页内两态间回退：type → list，list → 来处。
        // 直接退出会让"类型点错了"变成一次彻底离开再重进。
        onBackClicked: {
            if (!pickPage.controller) return
            if (pickPage.step === "type") pickPage.controller.addPickStep = "list"
            else                          pickPage.controller.closeAddPick()
        }
    }

    // ---------- 来源行：这是哪首歌 ----------
    // 二手信息但必须留：用户在列表里长按一行之后，需要一眼确认"加的是不是这一首"。
    Rectangle {
        id: srcRow
        objectName: "gdAddPickSrcRow"
        y: 32
        width: parent.width
        height: 17
        color: Theme.card
        visible: pickPage.step === "list"

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.right: shapeTag.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: pickPage.songName()
            color: Theme.text
            font.pixelSize: Theme.pxSmall
            elide: Text.ElideRight
        }

        // 形态标签：在线 / 已下载 / 在线 · 已下载。
        // 它解释的是"下面为什么有灰掉的行"——不给这行字，用户遇到灰行只能猜。
        Text {
            id: shapeTag
            objectName: "gdAddPickShapeTag"
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: pickPage.shapeText()
            color: Theme.textSub
            font.pixelSize: 9
        }
    }

    // ---------- list 态：歌单列表 ----------
    ListView {
        id: list
        objectName: "gdAddPickList"
        y: 49
        width: parent.width
        height: parent.height - y - 22
        clip: true
        visible: pickPage.step === "list"
        model: pickPage.entries
        boundsBehavior: Flickable.StopAtBounds
        spacing: 1

        delegate: Rectangle {
            width: list.width
            // 30（不是别处的 34）：本页多出「来源行 + 底部栏」两条，行高压一压才够看 3 行
            height: 30
            color: (addable && rowArea.pressed) ? Theme.cardHi : (index % 2 ? Theme.bg : Theme.card)

            property var entry: modelData
            readonly property bool addable: !!(entry && entry.state === "ok")

            function badgeText() {
                var s = entry ? entry.state : ""
                if (s === "ok")   return "加入"
                if (s === "dup")  return "已在"
                if (s === "type") return "不符"
                if (s === "full") return "已满"
                return ""
            }

            // 灰行点下去必须说明**为什么**：不给原因，用户只会以为界面卡了，
            // 然后一遍遍地点同一行。
            function stateHint() {
                if (!entry) return ""
                if (entry.state === "dup")  return "「" + entry.name + "」里已经有这首了"
                if (entry.state === "type")
                    return entry.typeText + "歌单只收" + (entry.type === "local" ? "已下载的" : "在线曲")
                if (entry.state === "full")
                    return "「" + entry.name + "」已满 "
                         + (pickPage.controller ? pickPage.controller.playlistSongMax : "") + " 首"
                return ""
            }

            // ❗整行点击区必须【最先声明】—— QML 同 z 下后声明的在上层。
            //    写在徽标后面就会把徽标压住（本地页/搜索页都栽过这个坑）。
            MouseArea {
                id: rowArea
                objectName: "gdAddPickRowTapArea"
                anchors.fill: parent
                onClicked: {
                    if (!pickPage.controller || !entry) return
                    if (addable) pickPage.controller.doAddPick(entry.id)
                    else         pickPage.controller.toastMsg(stateHint())
                }
            }

            Column {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: badge.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                    width: parent.width
                    text: entry && entry.name ? entry.name : ""
                    // 不可加的行整行降亮度：颜色比任何文字说明都先被看到
                    color: addable ? Theme.text : Theme.textSub
                    font.pixelSize: Theme.pxSmall
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: {
                        if (!entry) return ""
                        var c = entry.count ? (entry.count + " 首") : "空歌单"
                        // 来源标记：让用户知道这首加进去是落在网易云同步来的歌单里
                        return c + " · " + entry.typeText
                             + (entry.source === "netease" ? " · 网易云" : "")
                    }
                    color: Theme.textSub
                    font.pixelSize: 9
                    elide: Text.ElideRight
                }
            }

            Rectangle {
                id: badge
                objectName: "gdAddPickBadge"
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 40; height: 18
                radius: 3
                color: addable ? (rowArea.pressed ? Theme.cardHi : Theme.accent) : Theme.cardHi
                border.color: addable ? Theme.accent : Theme.line
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: badgeText()
                    color: addable ? "#FFFFFF" : Theme.textSub
                    font.pixelSize: 9
                }
            }
        }

        Text {
            anchors.centerIn: parent
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: list.count === 0
            text: "还没有歌单\n点右下角「+ 新建歌单」建一个\n\n在线歌单＝要联网播的曲目\n离线歌单＝只收已下载的歌"
            color: Theme.textSub
            font.pixelSize: Theme.pxSmall
            lineHeight: 1.4
        }
    }

    // ---------- list 态底部：统计 + 新建 ----------
    Rectangle {
        y: parent.height - 22
        width: parent.width
        height: 22
        color: Theme.card
        visible: pickPage.step === "list"

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: pickPage.controller ? pickPage.controller.addPickStat : ""
            color: Theme.textSub
            font.pixelSize: 9
        }

        Rectangle {
            id: newBtn
            objectName: "gdAddPickNewBtn"
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 74; height: 20
            radius: 3
            color: newArea.pressed ? Theme.cardHi : Theme.accent

            Text {
                anchors.centerIn: parent
                // ASCII 的 "+"（不是全角 ＋）：设备字体里全角符号不一定有字形，
                // 缺字形会显示成豆腐块。
                text: "+ 新建歌单"
                color: "#FFFFFF"
                font.pixelSize: 9
                font.bold: true
            }
            MouseArea {
                id: newArea
                anchors.fill: parent
                onClicked: if (pickPage.controller) pickPage.controller.addPickStep = "type"
            }
        }
    }

    // ---------- type 态：新建哪一类 ----------
    Column {
        id: typeCol
        objectName: "gdAddPickTypeCol"
        y: 32
        x: 8
        width: parent.width - 16
        spacing: 4
        visible: pickPage.step === "type"

        Text {
            width: parent.width
            height: 14
            text: "这首歌加入哪种歌单？"
            color: Theme.textSub
            font.pixelSize: 9
            verticalAlignment: Text.AlignVCenter
        }

        Repeater {
            // 顺序 = 推荐顺序（与歌单页的新建浮层一致）：在线歌单是主用法。
            model: [
                { t: "online", label: "在线歌单", hint: "要联网播，可随时下载" },
                { t: "local",  label: "离线歌单", hint: "只收已下载的歌" }
            ]

            delegate: Rectangle {
                id: typeRow
                objectName: (modelData.t === "online") ? "gdAddPickTypeOnline" : "gdAddPickTypeOffline"
                width: typeCol.width
                height: 42
                radius: Theme.radius
                // 载体没有对应形态就灰掉：让"这首进不了这类歌单"在**点之前**看得出来，
                // 而不是等点完再弹一句拒绝。
                readonly property bool fits: !!(pickPage.controller
                                                && pickPage.controller.addTargetFits(pickPage.song, modelData.t))
                color: fits ? (tArea.pressed ? Theme.cardHi : Theme.card) : Theme.bg
                border.color: Theme.line
                border.width: 1

                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1

                    Text {
                        text: modelData.label
                        color: typeRow.fits
                               ? ((modelData.t === "local") ? Theme.accent2 : Theme.accent)
                               : Theme.textSub
                        font.pixelSize: Theme.pxSmall
                    }
                    Text {
                        text: typeRow.fits ? modelData.hint : "这首歌没有可加入的形态"
                        color: Theme.textSub
                        font.pixelSize: 9
                    }
                }

                MouseArea {
                    id: tArea
                    anchors.fill: parent
                    onClicked: {
                        if (!pickPage.controller) return
                        if (!typeRow.fits) {
                            pickPage.controller.toastMsg("这首歌不适合该类型")
                            return
                        }
                        // 类型已定，接下来由 controller 弹键盘；建成后会自动把这首加进去。
                        pickPage.controller.beginCreateFromPick(modelData.t)
                    }
                }
            }
        }
    }

    // ---------- type 态底部：退回选歌单 ----------
    Rectangle {
        y: parent.height - 22
        width: parent.width
        height: 22
        color: Theme.card
        visible: pickPage.step === "type"

        Rectangle {
            objectName: "gdAddPickTypeBack"
            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 94; height: 20
            radius: 3
            color: tbackArea.pressed ? Theme.line : Theme.cardHi
            border.color: Theme.line
            border.width: 1

            Text {
                anchors.centerIn: parent
                // 不用 "←"（U+2190）：设备字体里那批箭头多半没字形，会显示成豆腐块。
                text: "返回选择歌单"
                color: Theme.textSub
                font.pixelSize: 9
            }
            MouseArea {
                id: tbackArea
                anchors.fill: parent
                onClicked: if (pickPage.controller) pickPage.controller.addPickStep = "list"
            }
        }
    }
}
