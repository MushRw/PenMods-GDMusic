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

            Item {
                width: parent.width
                height: 46

                Text {
                    x: 10
                    y: 8
                    width: parent.width - 20
                    wrapMode: Text.Wrap
                    color: Theme.textSub
                    font.pixelSize: 9
                    lineHeight: 1.35
                    text: "音源数据来自 GD音乐台(music.gdstudio.xyz)，仅供个人学习使用，请勿用于商业用途。"
                          + "\n本插件不存储任何音乐内容，仅做接口转发。"
                }
            }
        }
    }
}
