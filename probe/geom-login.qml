import QtQuick 2.12

// LoginPage 几何检查：320×170 屏上跑一遍，抓「元件越界」与「文字超出容器」。
// 用法（设备上）：
//   XDG_RUNTIME_DIR=/var/run qmlscene -platform offscreen /tmp/geom-login.qml
// LoginPage 用 Loader 挂载并注入假 controller —— 这样能同时验「未登录(expired)」
// 与「已登录(长昵称)」两种形态的布局，纯离线不碰 shell。
Item {
    id: root
    width: 320
    height: 170

    property int scenario: 0   // 0=未登录/有码 1=已登录(超长昵称) 2=已登录(同步中) 3=限频冷却中(无码)

    function fakeController() {
        if (scenario === 0)
            return { ncUid: "", ncNick: "", ncPhase: "expired", ncSyncing: false,
                     ncSyncMsg: "", ncQrStamp: 1, ncStarting: false, ncQrFile: "/tmp/gdmusic_ncqr_deadbeef.png", ncCooldown: 0, ncRiskMsg: "" }
        if (scenario === 1)
            return { ncUid: "1234567890", ncNick: "一个非常非常长的网易云昵称测试用例",
                     ncPhase: "done", ncSyncing: false, ncSyncMsg: "", ncQrStamp: 1, ncStarting: false, ncQrFile: "/tmp/gdmusic_ncqr_deadbeef.png", ncCooldown: 0, ncRiskMsg: "" }
        if (scenario === 3)
            return { ncUid: "", ncNick: "", ncPhase: "risk", ncSyncing: false,
                     ncSyncMsg: "", ncQrStamp: 1, ncStarting: false, ncQrFile: "",
                     ncCooldown: 42, ncRiskMsg: "网易云限频（8821），请稍后再试" }
        return { ncUid: "1234567890", ncNick: "短昵称", ncPhase: "done", ncSyncing: true,
                 ncSyncMsg: "歌单 3/12「我喜欢的音乐」…", ncQrStamp: 1, ncStarting: false, ncQrFile: "/tmp/gdmusic_ncqr_deadbeef.png", ncCooldown: 0, ncRiskMsg: "" }
    }

    Loader {
        id: ld
        anchors.fill: parent
        source: "file:///userdisk/PenMods/plugins/gdmusic/qml/pages/LoginPage.qml"
        onLoaded: {
            ld.item.controller = root.fakeController()
            Qt.callLater(function() { root.check() })
        }
    }

    function check() {
        var bad = 0
        function walk(o, path, depth) {
            if (depth > 10 || !o) return
            for (var n = 0; n < o.children.length; n++) {
                var c = o.children[n]
                if (c.width !== undefined && c.height !== undefined) {
                    var p = c.mapToItem(root, 0, 0)
                    var x0 = p.x, y0 = p.y, x1 = x0 + c.width, y1 = y0 + c.height
                    if (c.visible !== false && (x1 > 320.5 || y1 > 170.5 || x0 < -0.5 || y0 < -0.5)) {
                        console.log("OVERFLOW " + (c.objectName || c.type || "?")
                                    + " [" + path + "] x=" + x0.toFixed(1) + " y=" + y0.toFixed(1)
                                    + " w=" + c.width.toFixed(1) + " h=" + c.height.toFixed(1)
                                    + " right=" + x1.toFixed(1) + " bottom=" + y1.toFixed(1))
                        bad++
                    }
                    // 文字裁切：内容比容器宽且没开 wrapMode/没设 elide，就是肉眼可见的溢出
                    if (c instanceof Text && c.contentWidth > c.width + 0.5
                            && c.wrapMode === Text.NoWrap && c.elide === Text.ElideNone) {
                        console.log("TEXT_CLIP [" + path + "] contentW=" + c.contentWidth.toFixed(1)
                                    + " w=" + c.width.toFixed(1) + " text=\"" + c.text + "\"")
                        bad++
                    }
                    // 竖排 Column 溢出：内容总高超过自身 height（Column 不会自动裁，要靠自身高度）
                    if (c instanceof Column && c.children.length > 0) {
                        var need = 0
                        for (var m = 0; m < c.children.length; m++) {
                            var ch = c.children[m]
                            if (ch.visible !== false && ch.height !== undefined) need += ch.height
                        }
                        need += c.spacing * Math.max(0, c.children.length - 1)
                        if (need > c.height + 0.5) {
                            console.log("COLUMN_OVERFLOW [" + path + "] need=" + need.toFixed(1)
                                        + " h=" + c.height.toFixed(1) + " kids=" + c.children.length)
                            bad++
                        }
                    }
                }
                walk(c, path + ">" + (c.objectName || c.type || "?"), depth + 1)
            }
        }
        walk(ld.item, "LoginPage", 0)
        console.log("SCENARIO=" + root.scenario + " GEOM_BAD=" + bad)
        Qt.quit()
    }
}
