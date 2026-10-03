import QtQuick 2.12

Item {
    id: root
    width: 320
    height: 170

    Rectangle { anchors.fill: parent; color: "#3366cc" }

    Component.onCompleted: {
        var w = root.window
        console.log("GT window=" + w)
        if (w) console.log("GT visibility=" + w.visibility + " contentVisible=" + w.contentItem.visible
                           + " w=" + w.width + "x" + w.height + " exposed=" + w.isExposed)
        root.grabToImage(function(res) {
            console.log("GT grab ok=" + res.saveToFile("/tmp/rt.png") + " " + res.width + "x" + res.height)
            Qt.quit()
        }, Qt.size(320, 170))
        console.log("GT grabToImage() returned")
    }

    Timer {
        interval: 6000
        running: true
        onTriggered: { console.log("GT TIMEOUT: no grab callback"); Qt.quit() }
    }
}
