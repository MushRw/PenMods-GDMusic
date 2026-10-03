import QtQuick 2.12

Item {
    id: root
    width: 320
    height: 170

    property int imgStatus: -1
    property string imgSize: "?"

    Image {
        id: im
        objectName: "gdImgProbe"
        width: 64; height: 64
        source: "file:///tmp/imgchk/c.jpg"
        asynchronous: false
        cache: false
        onStatusChanged: {
            root.imgStatus = status
            root.imgSize = String(sourceSize.width) + "x" + String(sourceSize.height)
            console.log("IMG status", status, "size", root.imgSize, "err", errorString)
        }
    }

    Timer {
        interval: 2500
        running: true
        repeat: false
        onTriggered: {
            console.log("CHK img status=" + root.imgStatus + " size=" + root.imgSize)
            console.log("CHECK DONE")
            Qt.quit()
        }
    }
}
