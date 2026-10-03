import QtQuick 2.12
import ".."
import "../components" as Components

// 网易云账号页：扫码登录 + 歌单同步。
//
// 登录三段（都在 main.qml 的 nc* 函数里）：申请 unikey → 第三方 QR 生成二维码 →
// 轮询 check 状态。
//
// ⚠️ 二维码 source 只能读 controller.ncQrFile，**不要在这里拼路径、不要加 cache-bust
//    时间戳**。二维码是**异步下载**的：换 source 的那一刻新码往往还没落盘，于是读到
//    上一次的旧图；文件名固定时 QML Image 还会命中缓存，之后再无 source 变化 ⇒
//    屏上永远显示旧码，手机扫了提示"已失效"，而服务端那个 unikey 一直是 801（好的）——
//    症状与"码过期"几乎无法区分。现在文件名带 unikey 前缀（天然每次都是新路径），
//    且 ncQrFile 只在新码确认落盘后才写。
Rectangle {
    id: loginPage
    width: 320
    height: 170
    color: Theme.bg

    property var controller: null

    // 用函数包一层，避免裸 `a && b && c` 在中间项为 null 时把 undefined 赋给 bool
    // 属性（每帧刷一条 "Unable to assign [undefined] to bool"，写 flash 的日志不能留）。
    function loggedIn() {
        return !!(loginPage.controller && loginPage.controller.ncUid)
    }
    function busy() {
        return !!(loginPage.controller && loginPage.controller.ncSyncing)
    }
    function phaseText() {
        var c = loginPage.controller
        if (!c) return ""
        // ⚠️ busy() 必须排在 loggedIn() **前面**：同步只在已登录时发生，若先判
        //    loggedIn 就永远返回"已登录：xxx"，进度被整段吃掉。
        if (busy()) return c.ncSyncMsg || "同步中…"
        if (loggedIn()) return "已登录：" + (c.ncNick || c.ncUid)
        switch (c.ncPhase) {
            case "waiting": return "请用手机网易云 App 扫码"
            case "scanned": return "已扫码，请在手机上确认"
            case "expired":  return "二维码已过期，点下方刷新"
            case "error":    return "登录失败，点下方重试"
            // 🔴 限频风控必须**明确说出来**。以前这类 code 被当成"等下一拍重试"，
            //    界面照旧显示"请用手机…扫码"，用户扫码后毫无反应且不知道为什么。
            case "risk":     return c.ncCooldown > 0
                                    ? ("触发限频，" + c.ncCooldown + " 秒后可重试")
                                    : c.ncRiskMsg || "触发限频，请稍后重试"
            default:         return "准备登录…"
        }
    }

    Components.TitleBar {
        id: bar
        width: parent.width
        title: "网易云账号"
        showBack: true
        showSettings: false
        onBackClicked: if (loginPage.controller) loginPage.controller.goBack()
    }

    // ---------- 未登录：左侧二维码 + 右侧状态与按钮（左右分置） ----------
    //
    // ⚠️ 为什么不用 Column 竖排：320×170 减掉 TitleBar(32) 只剩 138px，
    //    竖排要放 二维码(120) + 状态文字 + 按钮(26) + 两个 spacing(12) = 170+ ⇒ 溢出屏幕。
    //    改成左右分置后高度只需 max(二维码 116, 文字+按钮 ≈ 70) = 116，稳稳落在 138 内，
    //    而且右侧文字有 ~180px 宽度，"二维码已过期，点下方刷新"这类长句不会截断。
    Item {
        id: qrCol
        x: 0
        y: 33
        width: parent.width
        height: parent.height - 33
        visible: !loggedIn()

        // 左：二维码
        Rectangle {
            id: qrBox
            x: 8
            y: (qrCol.height - height) / 2
            width: 116
            height: 116
            radius: 6
            color: "#FFFFFF"
            border.color: Theme.line
            border.width: 1

            Image {
                id: qrImg
                objectName: "gdNcQrImg"
                anchors.fill: parent
                anchors.margins: 5
                fillMode: Image.PreserveAspectFit
                smooth: true
                // ⚠️ 路径由 controller 在**新码确认落盘后**才写进 ncQrFile，且文件名带
                //    unikey 前缀 ⇒ 每次天然是新路径，不需要 cache-bust 时间戳。
                //    之前这里读固定路径 + ?t=，而下载是异步的：换 source 时新码还没落盘，
                //    读到的是上一张旧码，界面此后纹丝不动 ⇒ 手机扫了永远提示"已失效"。
                source: loginPage.controller && loginPage.controller.ncQrFile
                        ? "file://" + loginPage.controller.ncQrFile
                        : ""
            }

            // 出码要 2~3 秒（申请 unikey → 下载图片 → 确认落盘，三步串行）。
            // 没有这个占位时框里一片空白，用户会以为卡住而连点刷新 —— 而连点
            // 正是触发网易云限频（8821）的原因。
            Text {
                anchors.centerIn: parent
                visible: !(loginPage.controller && loginPage.controller.ncQrFile)
                text: (loginPage.controller && loginPage.controller.ncPhase === "risk")
                      ? "已暂停" : "正在获取…"
                color: Theme.textSub
                font.pixelSize: Theme.pxSmall
            }
        }

        // 右：状态文字 + 刷新按钮
        Column {
            x: qrBox.width + 20
            // ⚠️ 高度必须给足：Column **不会**因为子项超出而自动撑开（本项目的几何检查
            //    专门盯这条，COLUMN_OVERFLOW）。文字三行(≈36) + spacing 10 + 按钮 28 = 74。
            width: qrCol.width - x - 8
            height: 78
            y: (qrCol.height - height) / 2
            spacing: 10

            Text {
                width: parent.width
                text: phaseText()
                color: (loginPage.controller
                        && (loginPage.controller.ncPhase === "expired"
                            || loginPage.controller.ncPhase === "error"
                            || loginPage.controller.ncPhase === "risk"))
                       ? Theme.danger : Theme.text
                font.pixelSize: Theme.pxSmall
                // 状态句可能有长尾（"二维码已过期，点下方刷新"），最多两行，超出省略
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
            }

            // 刷新 / 重试按钮。冷却期间置灰并倒计时 —— 否则用户看不到为什么点了没反应，
            // 只会继续连点，而连点正是触发限频的原因（恶性循环）。
            Rectangle {
                width: 92
                height: 28
                radius: Theme.radius
                property bool cooling: loginPage.controller
                                       ? loginPage.controller.ncCooldown > 0 : false
                property bool failed: loginPage.controller
                                      ? (loginPage.controller.ncPhase === "expired"
                                         || loginPage.controller.ncPhase === "error"
                                         || loginPage.controller.ncPhase === "risk")
                                      : false
                color: cooling ? Theme.cardHi
                               : (refreshArea.pressed ? Theme.cardHi : Theme.accent)
                border.color: Theme.line
                border.width: 1

                Text {
                    anchors.centerIn: parent
                    text: parent.cooling
                          ? (loginPage.controller.ncCooldown + " 秒后可重试")
                          : (parent.failed ? "重新登录" : "刷新二维码")
                    color: parent.cooling ? Theme.textSub : "#FFFFFF"
                    font.pixelSize: Theme.pxSmall
                    font.bold: true
                }
                MouseArea {
                    id: refreshArea
                    anchors.fill: parent
                    onClicked: if (loginPage.controller) loginPage.controller.ncStartLogin()
                }
            }
        }
    }

    // ---------- 已登录：昵称 + 操作 ----------
    Column {
        id: acctCol
        x: 0
        y: 33
        width: parent.width
        height: parent.height - 33
        visible: loggedIn()
        // ⚠️ spacing=4 时加进同步进度行后 need=139 > h=137（几何检查 COLUMN_OVERFLOW）。
        //    Column 不会自动裁也不自动撑，超出的 2px 就是肉眼可见的下边缘溢出。
        spacing: 2

        Text {
            width: parent.width - 16
            x: 8
            horizontalAlignment: Text.AlignHCenter
            text: (loginPage.controller && loginPage.controller.ncNick)
                  ? loginPage.controller.ncNick : "已登录"
            color: Theme.text
            // 昵称可能很长（十几个字），限一行宽度并省略，别顶出屏幕
            elide: Text.ElideRight
            font.pixelSize: Theme.pxTitle
            font.bold: true
        }
        Text {
            width: parent.width - 16
            x: 8
            horizontalAlignment: Text.AlignHCenter
            text: (loginPage.controller && loginPage.controller.ncUid)
                  ? ("网易云 ID: " + loginPage.controller.ncUid) : ""
            color: Theme.textSub
            // uid 是 10 位左右数字 + 前缀 8 字，pxSmall(10) 下约 130px，留够余量再省略
            elide: Text.ElideRight
            font.pixelSize: Theme.pxSmall
        }

        // 同步歌单按钮
        Rectangle {
            width: 160
            height: 32
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: 6
            radius: Theme.radius
            // 同步中这个键变成「取消同步」：进度文字已经在上方 phaseText 里显示，
            // 这里再显示一遍反而挤。旧实现 busy 时直接 enabled:false ⇒ 用户除了
            // 干等没有任何出口，配合主线程被大响应轮询卡住，就成了"卡死退不出去"。
            color: busy() ? Theme.danger
                          : (syncArea.pressed ? Theme.cardHi : Theme.accent)
            border.color: Theme.line
            border.width: 1
            enabled: true

            Text {
                anchors.centerIn: parent
                text: busy() ? "取消同步" : "同步我的歌单"
                color: "#FFFFFF"
                font.pixelSize: Theme.pxSmall
                font.bold: true
            }
            MouseArea {
                id: syncArea
                anchors.fill: parent
                onClicked: {
                    if (!loginPage.controller) return
                    if (busy()) loginPage.controller.ncCancelSync()
                    else loginPage.controller.ncSyncPlaylists()
                }
            }
        }

        // 同步进度 / 结果 —— 已登录区**唯一**一处（2026-10-03 一度加了两处，
        //    屏上同时出现两行一样的进度，就是这里）。
        // ⚠️ 这一行不能省：按钮文案已经让给「取消同步」，而 ncSyncMsg 的另一个显示点
        //    （phaseText）在**未登录区**，同步只可能发生在已登录状态 ⇒ 那里永远看不见。
        //    · 文本直接取 ncSyncMsg，不限 busy()：同步完成后还要显示结果
        //      （"已同步 12 个歌单" / "已取消（已入库 5 个）"），否则用户只看到进度消失。
        //    · 固定占位（visible 恒真、内容为空）而不是 visible: busy()：
        //      Column 在子项可见性变化时会重排，"退出登录"会跟着上下跳，点着点着就点错。
        Text {
            width: parent.width - 16
            x: 8
            height: 14
            horizontalAlignment: Text.AlignHCenter
            text: (loginPage.controller && loginPage.controller.ncSyncMsg)
                  ? loginPage.controller.ncSyncMsg : ""
            color: busy() ? Theme.accent : Theme.textSub
            elide: Text.ElideRight
            font.pixelSize: Theme.pxSmall
        }

        // 退出登录
        Rectangle {
            width: 160
            height: 28
            anchors.horizontalCenter: parent.horizontalCenter
            radius: Theme.radius
            color: logoutArea.pressed ? Theme.cardHi : "transparent"
            border.color: Theme.danger
            border.width: 1

            Text {
                anchors.centerIn: parent
                text: "退出登录"
                color: Theme.danger
                font.pixelSize: Theme.pxSmall
            }
            MouseArea {
                id: logoutArea
                anchors.fill: parent
                onClicked: if (loginPage.controller) loginPage.controller.ncLogout()
            }
        }
    }

    // 进页时未登录则自动发起登录；离页（不可见）时停轮询。
    onVisibleChanged: {
        if (!visible) {
            if (loginPage.controller) loginPage.controller.ncStopPoll()
            return
        }
        if (loginPage.controller && !loggedIn()
            && loginPage.controller.ncPhase !== "waiting"
            && loginPage.controller.ncPhase !== "scanned") {
            loginPage.controller.ncStartLogin()
        }
    }
}
