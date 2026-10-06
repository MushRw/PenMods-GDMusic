import QtQuick 2.12
import ".."
import "../components" as Components

Rectangle {
    id: settingsPage
    width: 320
    height: 170
    color: Theme.bg

    property var controller: null

    Components.TitleBar {
        id: bar
        width: parent.width
        title: "设置"
        showSettings: false
        onBackClicked: if (settingsPage.controller) settingsPage.controller.goBack()
    }

    Flickable {
        id: flick
        y: 32
        width: parent.width
        height: parent.height - y
        contentHeight: col.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

            Column {
            id: col
            width: parent.width

            Components.SettingRow {
                label: "网易云账号"
                value: settingsPage.controller
                       ? (settingsPage.controller.ncUid
                          ? (settingsPage.controller.ncNick || settingsPage.controller.ncUid)
                          : "未登录") : ""
                onClicked: if (settingsPage.controller) settingsPage.controller.openLogin()
            }
            Rectangle { width: parent.width; height: 1; color: Theme.line }

            Components.SettingRow {
                label: "默认音源"
                value: settingsPage.controller ? settingsPage.controller.sourceLabel() : ""
                onClicked: if (settingsPage.controller) settingsPage.controller.cycleSource()
            }
            Components.SettingRow {
                label: "音质"
                value: settingsPage.controller ? settingsPage.controller.qualityLabel() : ""
                onClicked: if (settingsPage.controller) settingsPage.controller.cycleQuality()
            }
            Rectangle { width: parent.width; height: 1; color: Theme.line }

            Components.SettingRow {
                label: "自动连播"
                isToggle: true
                checked: settingsPage.controller ? settingsPage.controller.autoNext : false
                onClicked: if (settingsPage.controller) settingsPage.controller.toggleAutoNext()
            }
            Components.SettingRow {
                label: "加载歌词与封面"
                isToggle: true
                checked: settingsPage.controller ? settingsPage.controller.loadExtra : false
                onClicked: if (settingsPage.controller) settingsPage.controller.toggleLoadExtra()
            }
            Components.SettingRow {
                label: "下载时附带"
                value: settingsPage.controller
                       ? (settingsPage.controller.dlSidecar ? "歌词+封面" : "仅音频") : ""
                isToggle: true
                checked: settingsPage.controller ? settingsPage.controller.dlSidecar : false
                onClicked: if (settingsPage.controller) settingsPage.controller.toggleDlSidecar()
            }
            Components.SettingRow {
                label: "已下载优先"
                isToggle: true
                checked: settingsPage.controller ? settingsPage.controller.preferLocal : false
                onClicked: if (settingsPage.controller) settingsPage.controller.togglePreferLocal()
            }
            Components.SettingRow {
                label: "网络优化（优选 CF IP）"
                isToggle: true
                checked: settingsPage.controller ? settingsPage.controller.usePreferredIp : false
                onClicked: if (settingsPage.controller) settingsPage.controller.togglePreferredIp()
            }
            Components.SettingRow {
                label: "优选 IP 列表"
                value: settingsPage.controller ? settingsPage.controller.cfIpText : ""
                onClicked: if (settingsPage.controller) settingsPage.controller.editCfIps()
            }
            Components.SettingRow {
                label: "自定义中转地址"
                value: (settingsPage.controller && settingsPage.controller.apiBase.length)
                       ? settingsPage.controller.apiBase : "未设置（直连官方 API）"
                onClicked: if (settingsPage.controller) settingsPage.controller.editApiBase()
            }
            Components.SettingRow {
                label: "自动优选 IP"
                value: settingsPage.controller ? settingsPage.controller.netState : "扫描并保存可用节点"
                onClicked: if (settingsPage.controller) settingsPage.controller.startIpScan()
            }
            Components.SettingRow {
                label: "测试连通性"
                value: settingsPage.controller ? settingsPage.controller.netState : "点此测试"
                onClicked: if (settingsPage.controller) settingsPage.controller.testNetwork()
            }
            Rectangle { width: parent.width; height: 1; color: Theme.line }

            Components.SettingRow {
                label: "系统媒体控制"
                isToggle: true
                checked: settingsPage.controller ? settingsPage.controller.sysMedia : false
                onClicked: if (settingsPage.controller) settingsPage.controller.toggleSysMedia()
            }
            Components.SettingRow {
                label: "系统媒体接口"
                value: settingsPage.controller ? settingsPage.controller.sysMediaState : "未探测"
                onClicked: if (settingsPage.controller) settingsPage.controller.onProbeSysMedia()
            }
            Components.SettingRow {
                label: "停播后保留控制条"
                isToggle: true
                checked: settingsPage.controller ? settingsPage.controller.holdOnStop : false
                onClicked: if (settingsPage.controller) settingsPage.controller.toggleHoldOnStop()
            }

            Components.SettingRow {
                label: "停止播放并重置"
                value: "播放器"
                onClicked: if (settingsPage.controller) settingsPage.controller.restartMpv()
            }
            Components.SettingRow {
                label: "清空缓存与设置"
                value: ""
                onClicked: if (settingsPage.controller) settingsPage.controller.resetAll()
            }

            // ============================================================
            // 数据与隐私说明（默认折叠，点标题行展开）
            //
            // 为什么折叠：原来这块是 46px 常驻，下面这 6 条按 9px 字号、
            // 行高 1.35 在 300px 宽里要折到 13 行以上（约 150px）——
            // 320×170 的屏上会吃掉大半可视区，把上面的设置项顶出屏幕。
            // 折成一行入口后只在用户点开时才占地方；展开后的高度由外层
            // Flickable（:21-28，contentHeight: col.height）负责滚动，
            // **没有新增任何滚动容器**，所以不引入新的滚动嵌套。
            //
            // ⚠️ 文案纪律（改这段之前先读）：
            //  1. 每条声明都必须能被指到 main.qml 的具体行号 —— 行号写在本注释里，
            //     用户看到的是事实本身，不塞行号。
            //  2. **不确定的必须写成不确定**：cookie 进 argv 那条取决于系统
            //     /proc hidepid 设置，我们没有设备、**未确证**能不能真被读到。
            //  3. **不许暗示凭据已加密**：D2 的加密方案是*故意*没做的
            //     （QML/JS 侧没有可用加密原语，选型未决），
            //     见 gdmusic-p0-drafts/README.md 第四节 D。
            //  4. 旧文案「本插件不存储任何音乐内容」是**事实错误** ——
            //     下载会把完整音频写到 /userdisk/Music/GDMusic，已改正。
            //
            // 取证（main.qml，行号随时会漂，改文案时请重新核对）：
            //   :71        downloadDir = "/userdisk/Music/GDMusic"
            //   :2309/:2640 mkdir -p downloadDir，完整文件落盘
            //   :79-82     sidecar（同名 .jpg / .lrc）与 mp3 同目录
            //   :195       属性注释自承 cookie 是 MUSIC_U 等长期凭证
            //   :3057      INSERT OR REPLACE INTO kv VALUES(?,?) ["ncookie", ncCookie]
            //   :2949-2950 LocalStorage.openDatabaseSync("gdmusic", ...) —— 持久库
            //   :1716      cookie jar 路径 /tmp/gdmusic_nc_cookie.jar（:622 -c/-b 明文落盘）
            //   :598       cookie 经 -H 'Cookie: …' 进入 curl 命令行参数
            //   :643-645   二维码内容 = https://music.163.com/login?codekey=<unikey>
            //   :648       上面的内容整体拼进 api.pwmqr.com 的 URL（第三方）
            //   :213-224   桌面浏览器 UA + Referer，注释自承目的是绕风控
            //   :1826-1834 ncLogout() **只**清数据库那份（清字段 + ncSaveCookie 回写）；
            //   ⚠️ 它**不删 /tmp/gdmusic_nc_cookie.jar** —— ncJarPath() 的三个调用点
            //   （:1673 播种 / :1722 轮询 / :1716 定义）没有一处 rm -f，
            //   jar 要留到下次重启 / tmpfs 清空才消失。**所以文案里不能写
            //   「退出登录会彻底清除凭据」**，只能说清的是数据库那一份。
            // ============================================================
            Item {
                id: privacyBox
                width: parent.width
                height: 14 + (privacyOpen ? body.height + 14 : 0)

                property bool privacyOpen: false

                // 常驻一行：即使不展开，也必须说清最要紧的两件事
                //（本机会存音频、凭据明文保存）——不能让人点开才知情。
                Text {
                    id: header
                    x: 10
                    y: 0
                    width: parent.width - 20
                    height: 14
                    wrapMode: Text.Wrap
                    color: Theme.accent
                    font.pixelSize: 9
                    lineHeight: 1.35
                    text: privacyBox.privacyOpen
                        ? "本机存音频 · 登录凭据明文保存 · 隐私说明 ▾"
                        : "本机存音频 · 登录凭据明文保存 · 隐私说明 ›"
                    MouseArea {
                        anchors.fill: parent
                        onClicked: privacyBox.privacyOpen = !privacyBox.privacyOpen
                    }
                }

                Text {
                    id: body
                    x: 10
                    y: header.height + 2
                    width: parent.width - 20
                    visible: privacyBox.privacyOpen
                    wrapMode: Text.Wrap
                    color: Theme.textSub
                    font.pixelSize: 9
                    lineHeight: 1.35
                    text: "音源数据来自 GD音乐台(music.gdstudio.xyz)，仅供个人学习使用，请勿用于商业用途。"
                          + "\n· 下载的音频、歌词、封面会写入本机 /userdisk/Music/GDMusic（与系统播放器共用目录），可在本插件内删除。"
                          + "\n· 登录网易云后，长期登录凭据（MUSIC_U 等）以明文存入插件本地数据库；"
                          + "扫码期间还会明文写入 /tmp/gdmusic_nc_cookie.jar。未加密。"
                          + "\n· 凭据会作为 curl 命令行参数（-H 'Cookie: …'）传递。"
                          + "同机其他程序能否读到，取决于系统 /proc 的 hidepid 设置，未确证。"
                          + "\n· 扫码登录时，登录 unikey 会完整拼进 URL，发送给第三方二维码服务 api.pwmqr.com 生成图片。"
                          + "\n· 对网易云的请求使用桌面浏览器 UA，以绕过其风控。"
                }
            }
        }
    }
}
