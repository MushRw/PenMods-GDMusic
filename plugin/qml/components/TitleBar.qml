import QtQuick 2.12
import ".."

Rectangle {
    id: bar
    height: 32
    color: "transparent"

    property string title: ""
    property bool showBack: true
    property bool showSettings: true
    property bool showLocal: false

    // 「回到正在播放」：播过歌之后，所有页面都能一步回到播放页。
    // 2026-10-06 补 —— 在此之前播放页**没有任何常驻入口**，离开播放页后只能
    // 「重新点一首歌播一遍」才回得去，主观感受就是"播放页打不开"。
    property bool showPlayer: false

    // 顶部并列标签：搜索页与本地页是平级的两个根页面，用标签直接互切，
    // 不再靠右上角一个像"下载"的图标进去、再按返回键出来。
    // 塞在 TitleBar 里而不是另起一行 —— 320×170 上多一行 22px 就要吃掉半首歌的列表高度。
    property bool showTabs: false
    property var  tabLabels: ["搜索", "本地"]
    property int  tabIndex: 0

    // 「播放页动作」三个键（2026-10-07 A1 布局）：下载 / 加入歌单 / 播放队列。
    // 为什么挪到顶栏：320×170 上歌词区是核心内容，右侧每多一列按钮就吃掉约 40px 歌词宽
    //   （约 4 个汉字/行）。这三个都是低频动作，顶栏正好有空间。
    // ⚠️ 代价（已知并接受）：顶栏键是 30×28，比播放页的 36×32 小 ⇒ 落指精度略降。
    //    probe/addpick-device.qml 原本断言加歌键 36×32，已随本次改动同步为 30×28。
    property bool  showActions: false
    property color downloadTint: Theme.textSub
    property color addTint: Theme.accent2
    property color queueTint: Theme.textSub

    signal backClicked()
    signal settingsClicked()
    signal localClicked()
    signal tabClicked(int index)
    signal playerClicked()
    signal downloadClicked()
    signal addClicked()
    signal queueClicked()

    // 返回
    Rectangle {
        id: backBox
        // 30×28（原 28×26）+ 底色 + 描边：标题栏原来三个图标键全是 transparent，
        // 用户看不出边界，返回键这种"按错就退出"的键尤其需要明确的视觉边界。
        width: 30; height: 28
        anchors.left: parent.left; anchors.leftMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        radius: Theme.radius
        color: backArea.pressed ? Theme.line : Theme.card
        border.color: Theme.line
        border.width: 1
        visible: bar.showBack

        Canvas {
            anchors.centerIn: parent
            width: 16; height: 16
            onPaint: {
                var ctx = getContext("2d");
                ctx.clearRect(0, 0, width, height);
                ctx.strokeStyle = Theme.text;
                ctx.lineWidth = 2;
                ctx.lineCap = "round";
                ctx.lineJoin = "round";
                ctx.beginPath();
                ctx.moveTo(11, 3); ctx.lineTo(5, 8); ctx.lineTo(11, 13);
                ctx.stroke();
            }
        }
        MouseArea { id: backArea; anchors.fill: parent; onClicked: bar.backClicked() }
    }

    // 🔴 标题必须**夹在**返回键与右侧按钮组之间，不能写死 width:200 居中。
    //    原来写死 200 宽、centerIn parent（占 x=60..260）；2026-10-07 右侧从 1 个键
    //    变成 4 个键（占 x=184..316）之后，标题会**压到按钮底下** 76px ——
    //    而这种重叠在源码里完全看不出来，只有把坐标算出来才发现。
    //    改成锚定后，以后再加按钮，标题会自动缩短，永远不会重叠。
    Text {
        id: titleText
        objectName: "gdPlayerTitleText"
        anchors.left: parent.left
        anchors.leftMargin: (bar.showBack ? 34 : 4) + 4
        anchors.right: rightBtns.left
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        text: bar.title
        color: Theme.text
        font.pixelSize: Theme.pxTitle
        font.bold: true
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
        visible: !bar.showTabs
    }

    // 🔴 标签不再是「整条 TitleBar 居中」，而是在【返回键】与【右侧按钮组】之间的
    //    可用区里居中。原先三个 58px 标签居中占 69..251，加一个 ▶ 之后按钮组就从
    //    252 开始 —— 只剩 1px 间隙，看着像粘在一起，再挤一个按钮必然压上去。
    //    anchors 到 left/right 而不是 centerIn parent，以后加减按钮都不必重算任何坐标。
    Item {
        id: tabHost
        anchors.left: parent.left
        anchors.leftMargin: (bar.showBack ? 34 : 4) + 4
        anchors.right: rightBtns.left
        anchors.rightMargin: 4
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        Row {
            id: tabRow
            objectName: "gdTabRow"
            anchors.centerIn: parent
            spacing: 4
            visible: bar.showTabs

            Repeater {
                model: bar.tabLabels
                delegate: Rectangle {
                    width: 58; height: 21
                    radius: Theme.radius
                    color: (index === bar.tabIndex) ? Theme.accent
                                                    : (tArea.pressed ? Theme.cardHi : Theme.card)
                    border.color: (index === bar.tabIndex) ? Theme.accent : Theme.line
                    border.width: 1

                    Text {
                        anchors.centerIn: parent
                        // 限定宽度 + elide：标签文字是外面传进来的，「本地(↓12)」这种
                        // 带角标的会长过 58px 的标签盒，不夹住就会**溢出到相邻标签上**，
                        // 看起来像两个标签的标题串在一起。
                        width: parent.width - 6
                        horizontalAlignment: Text.AlignHCenter
                        text: modelData
                        color: (index === bar.tabIndex) ? "#FFFFFF" : Theme.textSub
                        font.pixelSize: Theme.pxSmall
                        font.bold: (index === bar.tabIndex)
                        elide: Text.ElideRight
                    }
                    MouseArea {
                        id: tArea
                        anchors.fill: parent
                        onClicked: bar.tabClicked(index)
                    }
                }
            }
        }
    }

    // 右上角按钮组：[下载] [加歌单] [队列] [正在播放] [本地/下载] [设置]
    //
    // 🔴 用 Row 而不是各自算 rightMargin：原先 local 的 margin 得按 settings 显不显示
    //    二选一地算（showSettings ? 34 : 4），再加第三个按钮就得把老按钮的偏移全部
    //    手推一遍；更麻烦的是 tabRow 是 anchors.centerIn（三个 58px 标签居中占 182px），
    //    按钮一多就会**悄悄压到标签上** —— 这种重叠在源码里完全看不出来。
    //    Row 会自动跳过 invisible 的项，所以将来加减按钮都不必重算任何坐标。
    //    ⚠️ 顺序刻意排成 [actions…, player, local, settings]：播放页动作排在左边，
    //    这样 player 不显示时剩下两项的相对位置与改之前逐像素一致，
    //    不动用户的肌肉记忆（设置一直在最右）。
    Row {
        id: rightBtns
        objectName: "gdRightBtns"
        anchors.right: parent.right
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4

        // ---------- 播放页动作（仅播放页显示）----------
        // 这三个原来在播放页右侧竖排；2026-10-07 按 A1 布局挪到顶栏，把宽度让给歌词。
        // 尺寸与同排其它顶栏键一致（30×28）—— 顶栏高度只有 32，塞不下 36×32。
        // 图标沿用 IconButton 的 Canvas 绘制（不依赖设备字体，缺字形就是豆腐块）。
        IconButton {
            id: dlBtn
            objectName: "gdPlayerDownloadBtn"
            width: 30; height: 28
            iconSize: 16
            kind: "download"
            tint: bar.downloadTint
            visible: bar.showActions
            onClicked: bar.downloadClicked()
        }

        IconButton {
            id: addBtn
            objectName: "gdPlayerAddBtn"
            width: 30; height: 28
            iconSize: 16
            kind: "plus"
            tint: bar.addTint
            visible: bar.showActions
            onClicked: bar.addClicked()
        }

        IconButton {
            id: queueBtn
            objectName: "gdPlayerQueueBtn"
            width: 30; height: 28
            iconSize: 16
            kind: "queue"
            tint: bar.queueTint
            visible: bar.showActions
            onClicked: bar.queueClicked()
        }

        // 正在播放：一步回到播放页
        Rectangle {
            width: 30; height: 28
            radius: Theme.radius
            color: playArea.pressed ? Theme.line : Theme.card
            // 描边用 accent：它是这里唯一"通往别处"的按钮，得和静态图标区分开
            border.color: Theme.accent
            border.width: 1
            visible: bar.showPlayer

            Canvas {
                anchors.centerIn: parent
                width: 16; height: 16
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    // 实心三角（播放符号）而非线稿 —— 这一排其它图标都是线条，
                    // 只有填色才看得出来它是"能按的播放"，不会和普通设置项混。
                    ctx.fillStyle = Theme.accent;
                    ctx.beginPath();
                    ctx.moveTo(4.5, 2.5); ctx.lineTo(13, 8); ctx.lineTo(4.5, 13.5);
                    ctx.closePath();
                    ctx.fill();
                }
            }
            MouseArea { id: playArea; anchors.fill: parent; onClicked: bar.playerClicked() }
        }

        // 本地音乐（下载按钮）：一张软盘/向下的箭头 + 一条底线
        Rectangle {
            id: localBox
            width: 30; height: 28
            radius: Theme.radius
            color: localArea.pressed ? Theme.line : Theme.card
            border.color: Theme.line
            border.width: 1
            visible: bar.showLocal

        Canvas {
            anchors.centerIn: parent
            width: 16; height: 16
            onPaint: {
                var ctx = getContext("2d");
                ctx.clearRect(0, 0, width, height);
                ctx.strokeStyle = Theme.text;
                ctx.lineWidth = 1.6;
                ctx.lineCap = "round";
                ctx.lineJoin = "round";
                // 向下箭头
                ctx.beginPath();
                ctx.moveTo(8, 2.5); ctx.lineTo(8, 10.5);
                ctx.moveTo(4.5, 7);  ctx.lineTo(8, 10.5); ctx.lineTo(11.5, 7);
                ctx.stroke();
                // 底线（承接线）
                ctx.beginPath();
                ctx.moveTo(3, 13.5); ctx.lineTo(13, 13.5);
                ctx.stroke();
            }
        }
        MouseArea { id: localArea; anchors.fill: parent; onClicked: bar.localClicked() }
        }

        // 设置
        Rectangle {
            id: setBox
            width: 30; height: 28
            radius: Theme.radius
            color: setArea.pressed ? Theme.line : Theme.card
            border.color: Theme.line
            border.width: 1
            visible: bar.showSettings

            Canvas {
                anchors.centerIn: parent
                width: 16; height: 16
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    ctx.strokeStyle = Theme.text;
                    ctx.lineWidth = 1.6;
                    ctx.lineCap = "round";
                    ctx.beginPath(); ctx.arc(8, 8, 2.6, 0, Math.PI * 2); ctx.stroke();
                    ctx.beginPath(); ctx.arc(8, 8, 6.2, -2.2, -0.9); ctx.stroke();
                    ctx.beginPath(); ctx.arc(8, 8, 6.2, 0.94, 1.6);  ctx.stroke();
                    ctx.beginPath(); ctx.arc(8, 8, 6.2, 2.8, 3.5);  ctx.stroke();
                }
            }
            MouseArea { id: setArea; anchors.fill: parent; onClicked: bar.settingsClicked() }
        }
    }
}
