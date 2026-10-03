import QtQuick 2.12

// 在**真机**上验证 P4「歌单重命名 / 删除 / 排序」。
//
// 与 probe/playlist-edit.sh（读源码结构 + 纯函数求值）互补：
//   这里用真 QML 引擎跑真代码，验证三件静态检查碰不到的事：
//   ① 数据层操作在真引擎里真的改到 playlists（movePlaylist/renamePlaylist/deletePlaylist）
//   ② ★ 重命名链路：beginRenamePlaylist 设状态 → onKeyboardAccepted("plRename") 回填 →
//       名字真的变 —— 这是「键盘是宿主整屏页」这一约束下唯一能离线验证的闭环
//   ③ 页面菜单：openMenu 开浮层、menuAct 分发、上移/下移边界置灰、删除二次确认
//
// 页面实例：main.qml 里 PlaylistPage 的 id 是 playlistPage，探针通过 it.playlistPage 访问。
//
// 用法（设备上）：
//   adb push probe/playlist-edit-device.qml /tmp/
//   adb shell "cd /userdisk/PenMods/plugins/gdmusic/qml && HOME=/tmp \
//              QT_QPA_PLATFORM=offscreen timeout 90 /usr/bin/qmlscene /tmp/playlist-edit-device.qml"
//   跑完必须 grep "Unable to assign" / "TypeError" / "ReferenceError"，要求零输出。
Item {
    id: root
    width: 320
    height: 170

    property int pass: 0
    property int bad: 0
    property var app: null
    property var ids: []

    function ok(cond, label) {
        if (cond) { pass++; console.log("  OK   " + label) }
        else      { bad++;  console.log("  BAD  " + label) }
    }

    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var ch = item.children || []
        for (var i = 0; i < ch.length; i++) {
            var r = findByName(ch[i], name)
            if (r) return r
        }
        return null
    }

    function orderText() {
        var a = root.app
        if (!a) return ""
        return a.playlists.map(function (p) { return p.name }).join(",")
    }

    Loader {
        id: ld
        source: "file:///userdisk/PenMods/plugins/gdmusic/qml/main.qml"

        onLoaded: {
            var it = ld.item
            if (!it) { console.log("CHECK FAIL 加载 main.qml 得到空对象"); Qt.quit(); return }
            root.app = it
            stageTimer.restart()
        }
        onStatusChanged: {
            if (status === Loader.Error) {
                console.log("CHECK FAIL main.qml 加载失败（Loader.Error）")
                Qt.quit()
            }
        }
    }

    property int stage: 0

    Timer {
        id: stageTimer
        interval: 500
        repeat: true

        onTriggered: {
            var it = root.app
            if (!it) return

            if (root.stage === 0) {
                console.log("--- 1. 造 3 个歌单 ---")
                it.playlists = []
                ids = []
                var n = ["甲", "乙", "丙"]
                for (var i = 0; i < 3; i++) {
                    var r = it.createPlaylist(n[i], "online")
                    ok(!!(r && r.ok), "1a 建歌单「" + n[i] + "」")
                    ids.push(r ? r.id : "")
                }
                ok(orderText() === "甲,乙,丙", "1b 初始顺序：" + orderText())
                root.stage = 1

            } else if (root.stage === 1) {
                console.log("--- 2. 排序：movePlaylistUI ---")
                ok(it.movePlaylistUI(ids[1], -1) === true, "2a movePlaylistUI(乙,-1) 返回 true")
                root.stage = 2

            } else if (root.stage === 2) {
                ok(orderText() === "乙,甲,丙", "2b 乙上移后顺序：" + orderText())
                it.movePlaylistUI(ids[1], -1)
                ok(orderText() === "乙,甲,丙", "2c 首行再上移 = no-op：" + orderText())
                it.movePlaylistUI(ids[2], 1)
                ok(orderText() === "乙,甲,丙", "2d 末行再下移 = no-op：" + orderText())
                it.movePlaylistUI(ids[0], 1)
                ok(orderText() === "乙,丙,甲", "2e 甲下移后顺序：" + orderText())
                root.stage = 3

            } else if (root.stage === 3) {
                console.log("--- 3. 重命名：beginRenamePlaylist → onKeyboardAccepted ---")
                it.beginRenamePlaylist(ids[0])   // 甲
                ok(it.plRenameId === ids[0], "3a plRenameId 指向甲")
                ok(it.editTarget === "plRename", "3b editTarget === plRename")
                it.onKeyboardAccepted("甲改名")
                ok(it.plRenameId === "", "3c 回填后 plRenameId 清空")
                root.stage = 4

            } else if (root.stage === 4) {
                ok(orderText() === "乙,丙,甲改名", "3d 重命名生效：" + orderText())
                it.beginRenamePlaylist(ids[1])
                it.onKeyboardAccepted("   ")
                ok(orderText() === "乙,丙,甲改名", "3e 空名重命名被拒：" + orderText())
                root.stage = 5

            } else if (root.stage === 5) {
                console.log("--- 4. 删除：deletePlaylistUI ---")
                // 此刻顺序是 乙,丙,甲改名（甲改名在末位）。删末位的「甲改名」。
                var lastId = it.playlists[2].id
                ok(it.deletePlaylistUI(lastId) === true, "4a deletePlaylistUI(末位) 返回 true")
                root.stage = 6

            } else if (root.stage === 6) {
                ok(orderText() === "乙,丙", "4b 删除后剩 2 个：" + orderText())
                ok(it.deletePlaylistUI("不存在的id") === false, "4c 删不存在的 id → false")
                root.stage = 7

            } else if (root.stage === 7) {
                console.log("--- 5. 页面菜单：openMenu / menuAct / 置灰 / 二次确认 ---")
                it.goPlaylists()
                // ⚠️ QML 的 id 不是对外属性，it.playlistPage 取不到。
                //    正确做法：从 objectName 找到浮层，它的 parent 就是 PlaylistPage 根。
                var popup = findByName(it, "gdPlActionPopup")
                var pg = popup ? popup.parent : null
                ok(!!pg, "5a 通过 gdPlActionPopup.parent 拿到页面根")
                root.stage = 8

            } else if (root.stage === 8) {
                var popup = findByName(it, "gdPlActionPopup")
                var pg = popup ? popup.parent : null
                if (!pg || !popup) { ok(false, "5b 页面根/popup 缺失"); root.stage = 11; return }
                ok(popup.visible === false, "5b 初始浮层不可见")
                pg.openMenu(it.playlists[0], 0)
                ok(popup.visible === true, "5c openMenu 后浮层可见")
                ok(pg.menuIndex === 0, "5d menuIndex === 0")
                ok(pg.menuPl === it.playlists[0], "5e menuPl 指向第一个歌单")
                root.stage = 9

            } else if (root.stage === 9) {
                console.log("--- 6. menuAct 二次确认 ---")
                var popup = findByName(it, "gdPlActionPopup")
                var pg = popup ? popup.parent : null
                if (!pg) { ok(false, "6a 页面根缺失"); root.stage = 11; return }
                pg.menuConfirmDelete = false
                pg.menuAct("delete")          // 第一次：只进确认态
                ok(pg.menuConfirmDelete === true, "6a 第一次点删除只进入确认态")
                ok(it.playlists.length === 2, "6b 确认态尚未真删（仍有 2 个）")
                pg.menuAct("delete")          // 第二次：真删
                ok(it.playlists.length === 1, "6c 第二次点删除真删（剩 " + it.playlists.length + "）")
                ok(pg.menuPl === null, "6d 删除后菜单关闭（menuPl 清空）")
                root.stage = 10

            } else if (root.stage === 10) {
                console.log("--- 7. 菜单重命名入口 ---")
                var popup = findByName(it, "gdPlActionPopup")
                var pg = popup ? popup.parent : null
                if (!pg) { ok(false, "7a 页面根缺失"); root.stage = 11; return }
                pg.openMenu(it.playlists[0], 0)
                pg.menuAct("rename")
                ok(it.plRenameId === it.playlists[0].id, "7a 菜单重命名 → plRenameId 指向该歌单")
                ok(it.editTarget === "plRename", "7b editTarget === plRename")
                ok(pg.menuPl === null, "7c 重命名后菜单关闭")
                it.plRenameId = ""
                it.editTarget = ""
                root.stage = 11

            } else if (root.stage === 11) {
                it.playlists = []
                console.log("")
                console.log("CHECK DONE pass=" + root.pass + " bad=" + root.bad)
                Qt.quit()
            }
        }
    }
}
