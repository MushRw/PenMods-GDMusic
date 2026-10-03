import QtQuick 2.12

Item {
    width: 10
    height: 10

    Image {
        id: a
        source: "file://userdisk/PenMods/plugins/gdmusic/icon.png"
    }
    Image {
        id: b
        source: "file:///userdisk/PenMods/plugins/gdmusic/icon.png"
    }
    Image {
        id: c
        source: "file:/userdisk/PenMods/plugins/gdmusic/icon.png"
    }

    Timer {
        interval: 1800
        running: true
        onTriggered: {
            // status: 0=Null 1=Ready 2=Loading 3=Error
            console.log("IMG 2slash=" + a.status + " 3slash=" + b.status + " 1slash=" + c.status)
            console.log("URLQ 2slash=" + a.source + " | 3slash=" + b.source)
            Qt.quit()
        }
    }
}
