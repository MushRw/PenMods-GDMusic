import QtQuick 2.12
import ".."

// 设置项行：左标签 + 右值 / 开关
Rectangle {
    id: row
    width: 320
    height: 28
    color: area.pressed ? Theme.cardHi : "transparent"

    property string label: ""
    property string value: ""
    property bool isToggle: false
    property bool checked: false
    signal clicked()

    Text {
        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        text: row.label
        color: Theme.text
        font.pixelSize: Theme.pxSmall
    }

    // 值文本模式
    Text {
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        visible: !row.isToggle
        text: row.value
        color: Theme.textSub
        font.pixelSize: Theme.pxSmall
        elide: Text.ElideRight
        width: 180
        horizontalAlignment: Text.AlignRight
    }

    // 开关模式
    Rectangle {
        visible: row.isToggle
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        width: 30; height: 16
        radius: 8
        color: row.checked ? Theme.accent : Theme.cardHi
        border.color: Theme.line
        border.width: 1

        Rectangle {
            width: 12; height: 12
            radius: 6
            y: 1
            x: row.checked ? parent.width - width - 1 : 1
            color: "#FFFFFF"
            Behavior on x { NumberAnimation { duration: 110 } }
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        onClicked: row.clicked()
    }
}
