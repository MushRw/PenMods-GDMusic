import QtQuick 2.12
import ".."

Rectangle {
    id: toast
    width: Math.min(textItem.implicitWidth + 24, parent ? parent.width - 20 : 240)
    height: 28
    radius: Theme.radius
    color: "#E61F232B"
    border.color: Theme.line
    border.width: 1
    visible: false
    opacity: 0
    z: 100

    property string text: ""
    property int duration: 2200

    anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
    anchors.bottom: parent ? parent.bottom : undefined
    anchors.bottomMargin: 8

    Text {
        id: textItem
        anchors.centerIn: parent
        text: toast.text
        color: Theme.text
        font.pixelSize: Theme.pxSmall
        width: parent.width - 14
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        maximumLineCount: 2
        wrapMode: Text.Wrap
    }

    function show(msg, ms) {
        text = msg
        if (ms) duration = ms
        hideTimer.restart()
        visible = true
        animIn.start()
    }

    NumberAnimation { id: animIn;  target: toast; property: "opacity"; to: 1; duration: 150 }
    Timer { id: hideTimer; interval: toast.duration; onTriggered: animOut.start() }
    NumberAnimation {
        id: animOut
        target: toast; property: "opacity"; to: 0; duration: 200
        onStopped: toast.visible = false
    }
}
