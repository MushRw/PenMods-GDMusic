import QtQuick 2.12

// 在设备上用 offscreen + 软件渲染把插件三个页面真实渲染并抓成 PNG。
// 目的：不依赖真机屏幕（weston 未开 --debug，screenshooter 不可用）也能确认 UI 版式。
Item {
    id: root
    width: 320
    height: 170

    Loader {
        id: ld
        source: "file:///userdisk/PenMods/plugins/gdmusic/qml/main.qml"

        onStatusChanged: {
            if (status === Loader.Error) { console.log("GRAB LOAD-ERROR"); Qt.quit(); return }
            if (status !== Loader.Ready) return
            root.step(0)
        }
        onLoaded: console.log("GRAB loaded w=" + item.width + " h=" + item.height)
    }

    property var r: ld.item

    function step(i) {
        if (i === 0) {
            r.keyword = "周杰伦"
            r.results = [
                { name: "七里香", artist: "周杰伦", album: "七里香", source: "netease" },
                { name: "晴天", artist: "周杰伦", album: "叶惠美", source: "netease" },
                { name: "稻香", artist: "周杰伦", album: "魔杰座", source: "netease" },
                { name: "夜曲", artist: "周杰伦", album: "十一月的萧邦", source: "netease" }
            ]
            r.page = "search"
        } else if (i === 1) {
            r.currentSong = { name: "七里香", artist: "周杰伦", source: "netease" }
            r.duration = 299
            r.timePos = 42
            r.lyricLines = [
                { time: 0, text: "七里香 - 周杰伦" },
                { time: 40, text: "窗外的麻雀 在电线杆上多嘴" },
                { time: 45, text: "你说这一句 很有夏天的感觉" }
            ]
            r.lyricIndex = 1
            r.playing = true
            r.paused = false
            r.page = "player"
        } else if (i === 2) {
            r.statusText = ""
            r.page = "settings"
        } else {
            console.log("GRAB done")
            Qt.quit()
            return
        }
        grab(i)
    }

    function grab(i) {
        var names = ["/tmp/gd_1_search.png", "/tmp/gd_2_player.png", "/tmp/gd_3_settings.png"]
        r.grabToImage(function(res) {
            console.log("GRAB i=" + i + " saved=" + res.saveToFile(names[i])
                        + " size=" + res.width + "x" + res.height)
            step(i + 1)
        })
    }
}
