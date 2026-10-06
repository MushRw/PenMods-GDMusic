import QtQuick 2.12
import ".."

// 播放控制按钮（Canvas 绘制，避免依赖字体里的特殊符号）
Rectangle {
    id: btn
    // 36×32（原 34×30）。播放页背景是纯色 bg，按钮原来完全没有背景 ——
    // 用户看不出可点范围的边界，只能凭感觉落指；补上底色 + 描边把边界画出来。
    width: 36
    height: 32
    radius: Theme.radius
    color: area.pressed ? Theme.line : Theme.card
    border.color: Theme.line
    border.width: 1

    property string kind: "play"        // play | pause | prev | next | download | queue | plus
    property color tint: Theme.text
    signal clicked()

    Canvas {
        id: cv
        anchors.centerIn: parent
        width: 20
        height: 20

        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.fillStyle = btn.tint;
            ctx.strokeStyle = btn.tint;
            ctx.lineWidth = 2;
            ctx.lineCap = "round";

            var k = btn.kind;
            if (k === "play") {
                ctx.beginPath();
                ctx.moveTo(6, 3.5);
                ctx.lineTo(16, 10);
                ctx.lineTo(6, 16.5);
                ctx.closePath();
                ctx.fill();
            } else if (k === "pause") {
                ctx.fillRect(6, 3.5, 3.2, 13);
                ctx.fillRect(11, 3.5, 3.2, 13);
            } else if (k === "prev") {
                ctx.fillRect(4.5, 3.5, 2.6, 13);
                ctx.beginPath();
                ctx.moveTo(16, 3.5);
                ctx.lineTo(8, 10);
                ctx.lineTo(16, 16.5);
                ctx.closePath();
                ctx.fill();
            } else if (k === "next") {
                ctx.beginPath();
                ctx.moveTo(4, 3.5);
                ctx.lineTo(12, 10);
                ctx.lineTo(4, 16.5);
                ctx.closePath();
                ctx.fill();
                ctx.fillRect(12.9, 3.5, 2.6, 13);
            } else if (k === "download") {
                // 向下箭头 + 一条承接线（表示落到本地存储）
                ctx.strokeStyle = btn.tint;
                ctx.beginPath();
                ctx.moveTo(10, 3.5); ctx.lineTo(10, 12);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(6, 8.5); ctx.lineTo(10, 12.5); ctx.lineTo(14, 8.5);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(4.5, 15.5); ctx.lineTo(15.5, 15.5);
                ctx.stroke();
            } else if (k === "queue") {
                // 三条横线 = 播放队列。放在 y=5.5/10/14.5 而不是更密：20px 的画布上
                // 三条线若挤得太近，在 320×170 的小屏上会糊成一坨看不出是列表。
                ctx.strokeStyle = btn.tint;
                ctx.beginPath();
                ctx.moveTo(4.5, 5.5);  ctx.lineTo(15.5, 5.5);
                ctx.moveTo(4.5, 10);   ctx.lineTo(15.5, 10);
                ctx.moveTo(4.5, 14.5); ctx.lineTo(15.5, 14.5);
                ctx.stroke();
            } else if (k === "plus") {
                // 十字（加入歌单）。用 Canvas 而不是 Text "＋"：设备字体里全角符号
                // 不一定有字形，缺字形就是一块豆腐；图形则永远画得出来。
                ctx.strokeStyle = btn.tint;
                ctx.beginPath();
                ctx.moveTo(10, 4.5); ctx.lineTo(10, 15.5);
                ctx.moveTo(4.5, 10); ctx.lineTo(15.5, 10);
                ctx.stroke();
            }
        }
    }

    // kind / tint 变化时重绘
    onKindChanged: cv.requestPaint()
    onTintChanged: cv.requestPaint()
    Component.onCompleted: cv.requestPaint()

    MouseArea {
        id: area
        anchors.fill: parent
        onClicked: btn.clicked()
    }
}
