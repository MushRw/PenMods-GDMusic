import QtQuick 2.12
import ".."
import "../components" as Components

// 歌单列表页 —— 与搜索页、本地页平级的第三个根页面（顶部第三个标签）。
//
// 为什么用标签而不是「从本地页钻进去」：三个页面回答的是三个不同的问题
//（搜什么 / 我下过什么 / 我收着什么），互相之间没有层级关系。做成平级标签，
// 各页面之间一步可达，也不会出现「返回键到底回哪一层」的困惑。
//
// 页面职责只到「列出来 + 进去 + 新建」：歌单内的增删歌在详情页，重命名/删除歌单在 P4。
Rectangle {
    id: plPage
    width: 320
    height: 170
    color: Theme.bg

    property var controller: null

    // ---- 歌单操作菜单（长按行弹出）----
    // 菜单针对「哪个歌单」和「在第几行」都由这两个属性记着；menuPl 为 null = 菜单关闭。
    property var    menuPl: null
    property int    menuIndex: -1
    property bool   menuConfirmDelete: false   // 删除项被点过一次 → 变身「确认删除?」

    function openMenu(pl, idx) {
        menuPl = pl
        menuIndex = idx
        menuConfirmDelete = false
        actionPopup.visible = true
    }
    function closeMenu() {
        menuPl = null
        menuIndex = -1
        menuConfirmDelete = false
        actionPopup.visible = false
    }

    Components.TitleBar {
        id: bar
        width: parent.width
        title: "歌单"
        showLocal: false
        showTabs: true
        tabIndex: 2
        // 三个标签固定 58 宽，总宽 58*3+4*2 = 182，居中后占 69..251 ——
        // 返回键（4..34）与设置键（286..316）都碰不到，不会再挤在一起。
        // 「本地」带下载角标：三个页面用**同一个**文案，切页时标签文字才不会跳动。
        tabLabels: ["搜索", plPage.controller ? plPage.controller.dlTabLabel : "本地", "歌单"]
        // 歌单页和搜索页/本地页一样是根页面：返回 = 退出插件。回别的页请用顶部标签。
        onBackClicked: if (plPage.controller) plPage.controller.exitPlugin()
        onSettingsClicked: if (plPage.controller) plPage.controller.openSettings()
        onTabClicked: {
            if (!plPage.controller) return
            if (index === 0)      plPage.controller.goSearch()
            else if (index === 1) plPage.controller.goLocal()
        }
    }

    // ---------- 歌单列表 ----------
    ListView {
        id: list
        objectName: "gdPlaylistList"
        y: 32
        width: parent.width
        height: parent.height - y - 22
        clip: true
        model: plPage.controller ? plPage.controller.playlists : null
        boundsBehavior: Flickable.StopAtBounds
        spacing: 1

        delegate: Rectangle {
            width: list.width
            height: 34
            color: itemArea.pressed ? Theme.cardHi : (index % 2 ? Theme.bg : Theme.card)

            property var pl: modelData
            readonly property bool offline: !!(pl && pl.type === "local")
            readonly property int  count: (pl && pl.songs) ? pl.songs.length : 0
            // 来源标记：网易云同步来的歌单。写进副标题而不是再加一个徽标 ——
            //    行宽 320 上右侧已经有「类型徽标 + 播放键」，再来一个徽标就要吃掉
            //    歌单名的显示宽度（名字才是用户主要看的东西）。
            readonly property bool fromNc: !!(pl && pl.source === "netease")

            // ❗整行点击区必须【最先声明】—— QML 同 z 下后声明的在上层。
            //    它 anchors.fill 覆盖整行，写在 ▶ 按钮后面就会把按钮的点击全吃掉、
            //    变成「进详情页」（本地页/搜索页都栽过同一个坑，见那边的注释）。
            MouseArea {
                id: itemArea
                objectName: "gdPlRowTapArea"
                anchors.fill: parent
                // 长按 = 打开歌单操作菜单（重命名/删除/排序）。间隔显式设值：
                // 默认取自 QStyleHints，平台返回 -1（不支持）时长按是死代码。
                pressAndHoldInterval: 700
                property bool longFired: false
                onPressedChanged: if (pressed) longFired = false
                onPressAndHold: {
                    longFired = true
                    plPage.openMenu(pl, index)
                }
                onClicked: {
                    if (longFired) { longFired = false; return }
                    if (plPage.controller && pl) plPage.controller.openPlaylist(pl.id)
                }
            }

            Column {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: typeTag.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                    width: parent.width
                    text: pl && pl.name ? pl.name : ""
                    color: Theme.text
                    font.pixelSize: Theme.pxSmall
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    // 曲目数为 0 时把「0 首」说成「空歌单」—— 0 首读起来像"加载中"，
                    // 而空歌单是刚建完的常态，得让人一眼看出"它本来就是空的"。
                    // 末尾的「· 网易云」是来源标记（elide 兜底，长名不会顶出屏幕）
                    text: (count ? (count + " 首") : "空歌单")
                          + " · " + (offline ? "离线" : "在线")
                          + (fromNc ? " · 网易云" : "")
                    color: Theme.textSub
                    font.pixelSize: 9
                    elide: Text.ElideRight
                }
            }

            // 类型徽标。颜色即语义：蓝=在线（要联网取流）、绿=离线（只收已下载的）。
            Rectangle {
                id: typeTag
                objectName: "gdPlTypeTag"
                anchors.right: playBtn.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 32; height: 14
                radius: 3
                color: Theme.cardHi
                border.color: offline ? Theme.accent2 : Theme.accent
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: offline ? "离线" : "在线"
                    color: offline ? Theme.accent2 : Theme.accent
                    font.pixelSize: 8
                }
            }

            // 一键播整个歌单 —— 歌单最常见的用法就是"打开就听"，让人必须先进详情页
            // 才能播是白多一步。空歌单不显示：点了也只会弹一句「歌单是空的」。
            Components.IconButton {
                id: playBtn
                objectName: "gdPlPlayBtn"
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                // 行高 34，按钮 26 高正好留出上下 4px 的呼吸位（默认 36×32 会把行撑满）
                width: 34; height: 26
                kind: "play"
                tint: Theme.accent
                visible: count > 0
                onClicked: if (plPage.controller && pl) plPage.controller.playPlaylistUI(pl.id, 0)
            }
        }

        Text {
            anchors.centerIn: parent
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: list.count === 0
            text: "还没有歌单\n点右下角的「+ 新建」建一个\n\n在线歌单＝要联网播的曲目\n离线歌单＝只收已下载的歌"
            color: Theme.textSub
            font.pixelSize: Theme.pxSmall
            lineHeight: 1.4
        }
    }

    // ---------- 底部：统计 + 新建 ----------
    Rectangle {
        y: parent.height - 22
        width: parent.width
        height: 22
        color: Theme.card

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: plPage.controller ? plPage.controller.plStat : ""
            color: Theme.textSub
            font.pixelSize: 9
        }

        Rectangle {
            id: newBtn
            objectName: "gdPlNewBtn"
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 62; height: 20
            radius: 3
            color: newArea.pressed ? Theme.cardHi : Theme.accent

            Text {
                anchors.centerIn: parent
                // 用 ASCII 的 "+" 而不是全角 "＋"：设备字体里全角符号不一定有字形，
                // 缺字形会显示成豆腐块（搜索页那个时钟图标就是为此用 Canvas 画的）。
                text: "+ 新建"
                color: "#FFFFFF"
                font.pixelSize: 9
                font.bold: true
            }
            MouseArea {
                id: newArea
                anchors.fill: parent
                onClicked: typePopup.visible = !typePopup.visible
            }
        }
    }

    // ---------- 新建：先选类型 ----------
    // 类型必须在唤起键盘**之前**选好：键盘是宿主的整屏页，一弹出来这个浮层就被盖住，
    // 用户没法在那边再选一次（类型存进 controller.plNewType）。
    Rectangle {
        id: typePopup
        objectName: "gdPlTypePopup"
        visible: false
        z: 90
        x: 6
        // 贴着底部栏往上放：新建按钮在右下角，用户在那一带落指，
        // 选项出现在同一片视野里，不用满屏找。
        y: parent.height - 22 - height - 2
        width: 152
        height: 18 + 26 * 2 + 6
        radius: Theme.radius
        color: "#F2242833"
        border.color: Theme.line
        border.width: 1

        Text {
            id: typeHead
            x: 8; y: 3
            text: "新建歌单"
            color: Theme.textSub
            font.pixelSize: 9
        }

        Column {
            id: typeCol
            x: 4
            y: 20
            width: parent.width - 8

            Repeater {
                // 顺序 = 推荐顺序：在线歌单是主用法（曲目不占空间、随时能下），排前面。
                model: [
                    { t: "online", label: "在线歌单", hint: "要联网播，可随时下载" },
                    { t: "local",  label: "离线歌单", hint: "只收已下载的歌" }
                ]
                delegate: Rectangle {
                    width: typeCol.width
                    height: 26
                    radius: 3
                    color: tArea.pressed ? Theme.cardHi : "transparent"

                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 0

                        Text {
                            text: modelData.label
                            color: (modelData.t === "local") ? Theme.accent2 : Theme.accent
                            font.pixelSize: Theme.pxSmall
                        }
                        Text {
                            text: modelData.hint
                            color: Theme.textSub
                            font.pixelSize: 8
                        }
                    }
                    MouseArea {
                        id: tArea
                        anchors.fill: parent
                        onClicked: {
                            // 先收浮层再弹键盘：键盘是整屏页，浮层留着也看不见，
                            // 而且回来时若还开着，会挡住刚建好的歌单列表。
                            typePopup.visible = false
                            if (plPage.controller)
                                plPage.controller.beginCreatePlaylist(modelData.t)
                        }
                    }
                }
            }
        }
    }

    // 点空白关浮层。z 固定 80（低于浮层的 90）—— 只有它可见时才有意义，
    // 否则它会把整个列表的点击都吃掉。
    MouseArea {
        anchors.fill: parent
        z: 80
        visible: typePopup.visible
        onClicked: typePopup.visible = false
    }

    // ---------- 歌单操作菜单（长按行弹出）----------
    // 四项：重命名 / 上移 / 下移 / 删除。上移下移在首尾行置灰（点了不动比报错好）。
    // 删除红色，点一次变身「确认删除?」再点才真删 —— 行内二次确认，不占整屏弹窗。
    Rectangle {
        id: actionPopup
        objectName: "gdPlActionPopup"
        visible: false
        z: 90
        width: 132
        height: 18 + 26 * 4 + 6
        radius: Theme.radius
        color: "#F2242833"
        border.color: Theme.line
        border.width: 1
        // 位置：贴着被长按的那行下方弹出；夹取在屏幕内（首行往上弹、末行往下弹）。
        x: 6
        y: {
            var rowTop = 32 + menuIndex * 35
            var below = rowTop + 35 + 2
            var above = rowTop - height - 2
            // 优先弹在行下方；放不下就弹行上方；再不够就贴边
            if (below + height <= plPage.height - 22) return below
            if (above >= 32) return above
            return Math.max(32, plPage.height - 22 - height)
        }

        Text {
            x: 8; y: 3
            text: "歌单操作"
            color: Theme.textSub
            font.pixelSize: 9
        }

        Column {
            id: menuCol
            x: 4
            y: 20
            width: parent.width - 8

            // 每项：label + 是否禁用（上移/下移在边界禁用、删除二次确认时文案变化）
            Repeater {
                model: [
                    { act: "rename", label: "重命名",      danger: false },
                    { act: "up",     label: "上移",        danger: false },
                    { act: "down",   label: "下移",        danger: false },
                    { act: "delete", label: "删除",        danger: true  }
                ]
                delegate: Rectangle {
                    width: menuCol.width
                    height: 26
                    radius: 3
                    // 禁用态：上移在首行、下移在末行 → 灰字 + 无点击
                    property bool disabled:
                        (modelData.act === "up"   && plPage.menuIndex <= 0)
                     || (modelData.act === "down" && plPage.menuIndex >= 0
                         && plPage.controller && plPage.menuIndex >= plPage.controller.playlists.length - 1)
                    // 删除项二次确认时，整行高亮成危险色，文案换成「确认删除?」
                    property bool confirmState:
                        modelData.act === "delete" && plPage.menuConfirmDelete

                    color: menuArea.pressed ? Theme.cardHi : "transparent"

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        text: confirmState ? "确认删除?" : modelData.label
                        color: disabled ? Theme.textSub
                             : (modelData.danger ? Theme.danger : Theme.text)
                        font.pixelSize: Theme.pxSmall
                        font.bold: confirmState
                    }
                    MouseArea {
                        id: menuArea
                        anchors.fill: parent
                        enabled: !disabled
                        onClicked: plPage.menuAct(modelData.act)
                    }
                }
            }
        }
    }

    function menuAct(act) {
        if (!controller || !menuPl) return
        // ⚠️ 先把 id 取出来再关菜单：closeMenu 会把 menuPl 清成 null，
        //    后面再用 menuPl.id 就是 "Cannot read property 'id' of null"。
        var pid = menuPl.id
        if (act === "rename") {
            closeMenu()
            controller.beginRenamePlaylist(pid)
        } else if (act === "up") {
            closeMenu()
            controller.movePlaylistUI(pid, -1)
        } else if (act === "down") {
            closeMenu()
            controller.movePlaylistUI(pid, 1)
        } else if (act === "delete") {
            if (!menuConfirmDelete) { menuConfirmDelete = true; return }
            closeMenu()
            controller.deletePlaylistUI(pid)
        }
    }

    // 关菜单遮罩。z 85（低于菜单 90、高于 typePopup 遮罩 80），只有菜单可见时才有意义。
    MouseArea {
        anchors.fill: parent
        z: 85
        visible: actionPopup.visible
        onClicked: plPage.closeMenu()
    }
}
