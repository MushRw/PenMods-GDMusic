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

    // 顶部并列标签：搜索页与本地页是平级的两个根页面，用标签直接互切，
    // 不再靠右上角一个像"下载"的图标进去、再按返回键出来。
    // 塞在 TitleBar 里而不是另起一行 —— 320×170 上多一行 22px 就要吃掉半首歌的列表高度。
    property bool showTabs: false
    property var  tabLabels: ["搜索", "本地"]
    property int  tabIndex: 0

    signal backClicked()
    signal settingsClicked()
    signal localClicked()
    signal tabClicked(int index)

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

    Text {
        anchors.centerIn: parent
        text: bar.title
        color: Theme.text
        font.pixelSize: Theme.pxTitle
        font.bold: true
        elide: Text.ElideRight
        width: 200
        horizontalAlignment: Text.AlignHCenter
        visible: !bar.showTabs
    }

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

    // 本地音乐（下载按钮）：一张软盘/向下的箭头 + 一条底线
    Rectangle {
        id: localBox
        width: 30; height: 28
        anchors.right: parent.right
        anchors.rightMargin: (bar.showSettings ? 34 : 4)
        anchors.verticalCenter: parent.verticalCenter
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
        anchors.right: parent.right; anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
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
