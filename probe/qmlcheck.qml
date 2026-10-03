import QtQuick 2.12

Item {
    width: 10
    height: 10

    Loader {
        id: ld
        source: "file:///userdisk/PenMods/plugins/gdmusic/qml/main.qml"

        onStatusChanged: {
            if (status === Loader.Error) { console.log("CHK LOAD-ERROR"); Qt.quit(); return }
            if (status !== Loader.Ready) return

            var r = ld.item

            // ---- 框架约定 ----
            // 插件根对象必须暴露 backButtonClicked 信号，否则 YDynamicPageStack 不会连接它，
            // 插件内返回箭头就无法关闭插件（只能靠 Home 键）。
            console.log("CHK hasBackSignal=" + r.hasOwnProperty("backButtonClicked"))
            console.log("CHK hasExitPlugin=" + (typeof r.exitPlugin === "function"))

            // ---- 网络层（搜索/歌词/封面仍走 QML，取流已交给 lua）----
            console.log("CHK ips=" + JSON.stringify(r.preferredIps()))
            console.log("CHK lrc=" + JSON.stringify(r.parseLrc("[00:01.50]hello\n[01:02.00]last")))
            console.log("CHK apicmd=" + r.buildApiCmdForIps(
                "types=search&source=netease&name=test&count=1",
                "/tmp/gdtest.out", "GDDONE9Z",
                ["104.18.0.1", "104.17.0.1", ""]))

            // ---- 常驻播放器：命令行生成 ----
            console.log("CHK playerStart=" + r.buildEnsurePlayerCmd())
            console.log("CHK msgLoad=" + r.buildScriptMsgCmd("gd-load"))
            console.log("CHK ipcPause=" + r.buildIpcCmd(["set_property", "pause", "true"]))
            console.log("CHK wakeLockFile=" + r.wakeLockFile)
            console.log("CHK luaScript=" + r.luaScript)

            // ---- 队列文件：JSON 与下标错位（lua 侧从 1 起）----
            // id 用真实可播的曲目，这样下面输出的命令可以在设备上原样执行做端到端验证。
            // 歌名特意带单引号与中文，用来验证 shell 转义。
            r.queue = [
                { id: "5257138",   name: "Don't Stop", artist: "A" },
                { id: "509781655", name: "中文歌名",   artist: "乙" }
            ]
            r.queueIndex = 0
            r.source = "netease"
            r.quality = "320"
            r.autoNext = true
            console.log("CHK queueJson=" + r.queueJsonString(0))
            console.log("CHK queueJsonIdx2=" + r.queueJsonString(1))
            console.log("CHK writeQ=" + r.buildQueueWriteCmd(0))

            // ---- applyNow：状态镜像（这是插件开着时唯一的同步入口）----
            r.applyNow({ status: "playing", index: 1, pos: 5.5, dur: 100 })
            console.log("CHK now/playing playing=" + r.playing + " paused=" + r.paused
                        + " queueIndex=" + r.queueIndex + " pos=" + r.timePos
                        + " dur=" + r.duration + " song=" + (r.currentSong ? r.currentSong.id : "-"))

            // 自动续播：lua 把 index 推到 2，QML 应跟随
            r.applyNow({ status: "playing", index: 2, pos: 1, dur: 200 })
            console.log("CHK now/next    queueIndex=" + r.queueIndex
                        + " song=" + (r.currentSong ? r.currentSong.id : "-")
                        + " (期望 1/509781655)")

            r.applyNow({ status: "paused", index: 2, pos: 9, dur: 200 })
            console.log("CHK now/paused  paused=" + r.paused + " playing=" + r.playing + " (期望 true/false)")

            r.applyNow({ status: "loading", index: 2 })
            console.log("CHK now/loading playing=" + r.playing + " status=" + r.statusText)

            r.applyNow({ status: "stopped", reason: "end", index: -1 })
            console.log("CHK now/stopped playing=" + r.playing + " paused=" + r.paused
                        + " status=" + r.statusText + " (期望 false/true/播放结束)")

            r.applyNow({ status: "stopped", reason: "fail", index: -1 })
            console.log("CHK now/fail    status=" + r.statusText)

            // 系统媒体探测：qmlscene 里没有任何原厂上下文属性，
            // 所以这里必须**优雅降级**（不抛异常、state=不可用），
            // 而 device 上同一段代码应当报 mediaPlayerManager=yes。
            var probe = r.probeSystemMedia()
            console.log("CHK sysmedia state=" + r.sysMediaState + " (qmlscene 期望 不可用)")
            console.log("CHK sysmedia line1=" + String(probe).split("\n")[0])
            console.log("CHK sysmedia hasManagers=" + (String(probe).indexOf("mediaPlayerManager=") >= 0))

            // ============================================================
            // 下载功能
            // ============================================================
            console.log("CHK dlDir=" + r.downloadDir)
            console.log("CHK dlIndex=" + r.localIndexFile)

            // 文件名清洗：/ \: * ? " < > | 都会让 ext4 建出子目录或打断 shell 单引号
            console.log("CHK sanitize a=" + r.sanitizeName("a/b*c:d?e<f>g|h\"i\\j"))
            console.log("CHK sanitize b=" + r.sanitizeName("  Don't Stop  "))
            console.log("CHK sanitize c=" + r.sanitizeName(""))

            // 命名沿用设备已有习惯「歌名-歌手.mp3」，多个歌手用「、」连
            var s1 = { id: "5257138", name: "Don't Stop", artist: "甲,乙", source: "netease" }
            console.log("CHK localName=" + r.localNameFor(s1))
            console.log("CHK localPath=" + r.localPathFor(s1))
            console.log("CHK localLrc=" + r.localLrcFor(r.localPathFor(s1)))
            // 带斜杠的歌名最容易被漏：不清洗就会写出一个子目录
            console.log("CHK localName slash=" + r.localNameFor({ id: "x1", name: "a/b", artist: "c/d" }))

            console.log("CHK sizeText 0=" + r.sizeText(0))
            console.log("CHK sizeText kb=" + r.sizeText(4096))
            console.log("CHK sizeText mb=" + r.sizeText(5242880))

            // 下载的 shell 命令：原样复制出来在设备上跑，是最实在的校验。
            // 要点：-o 写缓存区 .part 再 mv，中断时不会留下一个假的完整文件进歌库。
            console.log("CHK dlCmd=" + r.buildDownloadCmd(
                "https://example.com/a b.mp3", r.localPathFor(s1), "/tmp/gdmusic/parts/1.part", "/tmp/gdmusic/dl/1.st"))
            console.log("CHK scanCmd=" + r.buildScanCmd())

            // 已下载识别：列表是扫文件夹得出的，判断按「预期文件路径」比对
            r.localList = []
            console.log("CHK downloaded(before)=" + r.isDownloaded(s1))
            r.localList = [{ id: r.localPathFor(s1), name: "Don't Stop", artist: "甲、乙",
                             file: r.localPathFor(s1), size: 5242880 }]
            console.log("CHK downloaded(after)=" + r.isDownloaded(s1))
            console.log("CHK findLocal=" + (r.findLocal(s1) ? r.findLocal(s1).size : -1))

            // 文件夹扫描解析：歌名-歌手 反推、含 | 的怪名、非 mp3 忽略
            var sd = r.parseLocalScan(
                "@@GDMUS@@3706924|稻香-周杰伦.mp3\n" +
                "@@GDMUS@@100|没有歌手的歌.mp3\n" +
                "@@GDMUS@@200|歌|名-歌手.mp3\n" +
                "@@GDMUS@@300|cover.jpg\n" +
                "noise line\n")
            console.log("CHK scan n=" + sd.length + " (期望 3)"
                        + " [0]=" + sd[0].name + "/" + sd[0].artist + "/" + sd[0].size
                        + " [1]=" + sd[1].name + "/" + sd[1].artist
                        + " [2]=" + sd[2].name + "/" + sd[2].artist + " (期望 稻香/周杰伦/3706924、没有歌手的歌/、歌|名/歌手)")

            // 本地曲目进队列必须带上 file 字段，lua 才认得出这是本地文件
            // （qmlscene 下 shell 不存在，startAt 里的写文件会是空操作，不影响这里验什么）
            r.playLocal(0)
            console.log("CHK playLocal page=" + r.page + " len=" + r.queue.length
                        + " file=" + (r.queue[0] ? r.queue[0].file : "-"))

            // 【活性判据】僵尸 socket 是个真实发生过的故障：mpv 被 SIGKILL 时不删
            // IPC socket，若判据退化成 "-S 文件存在"，播放器就永远拉不起来了。
            var ec = r.buildEnsurePlayerCmd()
            console.log("CHK aliveProbe=" + (ec.indexOf(" pid > ") >= 0)
                        + " (期望 true：靠要 pid 判活)")
            console.log("CHK notBareExists=" + (ec.indexOf("[ ! -S ") < 0)
                        + " (期望 true：不许只有文件存在判据)")
            console.log("CHK rmStale=" + (ec.indexOf("rm -f " + r.mpvSock) >= 0)
                        + " (期望 true：僵尸先删)")
            console.log("CHK memGuard=" + (ec.indexOf("demuxer-max-bytes") >= 0)
                        + " (期望 true：OOM 防线)")
            // 音量交给系统：mpv 必须保持默认 100 不衰减，否则系统音量 × mpv 音量两级叠乘，
            // 表现为「系统音量拉满声音还是偏小」。
            console.log("CHK noVolumeFlag=" + (ec.indexOf("--volume") < 0)
                        + " (期望 true：音量由系统统一管)")

            // 无 shell 时必须优雅降级，不能抛异常
            var threw = false
            try { r.downloadSong({ id: "none", name: "x" }) } catch (e) { threw = true }
            console.log("CHK downloadSong noShell threw=" + threw + " (期望 false)")

            // ============================================================
            // 搜索历史
            // ============================================================
            console.log("CHK hist api=" + ((typeof r.pushHistory === "function")
                        + "/" + (typeof r.removeHistoryAt === "function")
                        + "/" + (typeof r.clearHistory === "function")
                        + "/" + (typeof r.searchWord === "function"))
                        + " (期望 true×4)")
            console.log("CHK histMax=" + r.historyMax + " (期望 20)")
            // loadHistory() 的结果（Component.onCompleted 里读的）。
            // 上一轮跑到最后会 push 一条「持久化往返」，正常应在这里被读回来。
            console.log("CHK hist loaded=" + JSON.stringify(r.searchHistory))

            r.searchHistory = []
            r.pushHistory("周杰伦")
            r.pushHistory("晴天")
            r.pushHistory("周杰伦")          // 重复词：应提到最前而不是出现两次
            console.log("CHK hist dup=" + JSON.stringify(r.searchHistory)
                        + " (期望 [\"周杰伦\",\"晴天\"]：最后搜的排最前)")

            r.pushHistory("   ")             // 纯空白：不该进历史
            r.pushHistory("")
            console.log("CHK hist blank=" + JSON.stringify(r.searchHistory)
                        + " (期望仍是 2 条)")

            r.removeHistoryAt(0)             // 删掉第 0 条「周杰伦」
            console.log("CHK hist rm=" + JSON.stringify(r.searchHistory)
                        + " (期望 [\"晴天\"])")

            // 点历史 = 填词 + 立刻搜；同时必须把浮层收起来（否则挡住结果列表）
            r.historyOpen = true
            var threw2 = false
            try { r.searchWord("稻香") } catch (e2) { threw2 = true }
            console.log("CHK hist searchWord kw=" + r.keyword
                        + " open=" + r.historyOpen + " threw=" + threw2
                        + " (期望 稻香/false/false)")

            r.clearHistory()
            console.log("CHK hist clear=" + JSON.stringify(r.searchHistory) + " (期望 [])")

            // 超长历史必须被截断，否则列表会无限增长
            for (var h = 0; h < 30; h++) r.pushHistory("w" + h)
            console.log("CHK hist cap len=" + r.searchHistory.length + " (期望 20)"
                        + " head=" + r.searchHistory[0] + " (期望 w29)")

            // ============================================================
            // 音源：只留 API 实际接受的三个（2026-10-01 设备实测）
            // ============================================================
            var ids = []
            for (var si = 0; si < r.sources.length; si++) ids.push(r.sources[si].id)
            console.log("CHK srcList=" + JSON.stringify(ids) + " (期望 3 个)")
            console.log("CHK srcValid ok=" + r.isValidSource("netease")
                        + "/" + r.isValidSource("joox")
                        + "/" + r.isValidSource("bilibili") + " (期望 true×3)")
            // 已下线的音源必须判为无效，否则老存档会让插件每次开机都固定搜不到歌
            console.log("CHK srcValid dead=" + r.isValidSource("tencent")
                        + "/" + r.isValidSource("kuwo")
                        + "/" + r.isValidSource("kugou") + " (期望 false×3)")
            console.log("CHK srcCur=" + r.source + " (期望 netease)")

            // ============================================================
            // 顶部标签：搜索 ↔ 本地 两个平级页面，点标签必须真的翻转 page
            // ============================================================
            r.goLocal()
            console.log("CHK tab goLocal page=" + r.page + " (期望 local)")
            r.goSearch()
            console.log("CHK tab goSearch page=" + r.page + " (期望 search)")

            // 持久化往返：留一条在库里，下一轮跑 qmlscene 时 CHK hist loaded 应读回它。
            // （qmlscene 与主程序的 XDG_DATA_HOME 不同，用的是独立库文件，不会污染真机历史）
            r.clearHistory()
            r.pushHistory("持久化往返")
            console.log("CHK hist persist=" + JSON.stringify(r.searchHistory))

            // ============================================================
            // 下载队列：串行、视图快照、百分比、取消、角标
            // （不碰 shell：downloadSong 有 shell 守卫会直接 return，
            //   所以直接调 dlEnqueue / refreshQueueView 这些内部纯逻辑）
            // ============================================================
            var mk = function(i) { return { id: "q" + i, name: "队列歌" + i, artist: "", source: "netease" } }
            var k1 = r.dlEnqueue(mk(1), "/tmp/a1.mp3", "/tmp/p1.part", "/tmp/s1.st", "/tmp/s1.meta")
            var k2 = r.dlEnqueue(mk(2), "/tmp/a2.mp3", "/tmp/p2.part", "/tmp/s2.st", "/tmp/s2.meta")
            var k3 = r.dlEnqueue(mk(3), "/tmp/a3.mp3", "/tmp/p3.part", "/tmp/s3.st", "/tmp/s3.meta")
            console.log("CHK dlq order=" + JSON.stringify(r.dlQueue)
                        + " (期望 [" + k1 + "," + k2 + "," + k3 + "])")
            // 模拟调度器取走队首（dlKick 会碰 apiGet/shell，探针环境绕开它）
            r.dlQueue.shift(); r.dlQueue = r.dlQueue.slice(); r.dlRunning = k1
            r.dlPending[k1].got = 512; r.dlPending[k1].total = 1024
            r.refreshQueueView()
            console.log("CHK dlq view len=" + r.dlQueueView.length + " (期望 3)"
                        + " head=" + r.dlQueueView[0].name + " run=" + r.dlQueueView[0].running
                        + " pct=" + r.dlQueueView[0].pct + " (期望 50)")
            console.log("CHK dlq pctNoTotal=" + r.pctOf({ got: 512, total: -1 }) + " (期望 -1)")
            console.log("CHK dlq pctZero=" + r.pctOf({ got: 0, total: 1024 }) + " (期望 0)")
            console.log("CHK dlq pctClamp=" + r.pctOf({ got: 2048, total: 1024 }) + " (期望 100)")
            console.log("CHK dlq tab=" + r.dlTabLabel + " (期望 本地(↓3))")
            // 取消排队的第 2 个：从 dlQueue/dlPending 摘除且不抛异常（探针环境无 shell）
            var threw = false
            try { r.dlCancel("q2") } catch (e) { threw = true }
            console.log("CHK dlq cancel threw=" + threw + " (期望 false)"
                        + " queue=" + JSON.stringify(r.dlQueue) + " (期望 [" + k3 + "])"
                        + " tabAfter=" + r.dlTabLabel + " (期望 本地(↓2))")
            // buildDownloadCmd 必须包含 total: 行（Content-Length → 百分比的源头）
            // 注意 sed 写的是 [Cc]ontent-[Ll]ength（首字母大小写都容），断言要跟着它找
            var dc = r.buildDownloadCmd("http://x/y.mp3", "/userdisk/Music/GDMusic/a.mp3", "/tmp/parts/1.part", "/tmp/a.st")
            console.log("CHK dlq cmdTotal=" + (dc.indexOf("total:%s") >= 0 && dc.indexOf("[Ll]ength") >= 0)
                        + " (期望 true)")
            // ⚠️ 完整文件绝不半截进歌库：curl -o 必须指向缓存 part，成功才 mv 进歌库
            //（shellQuote 会对路径加单引号，断言别裸写路径）
            console.log("CHK dlq cmdStage=" + (dc.indexOf("-o '/tmp/parts/1.part'") >= 0
                        && dc.indexOf("-o '" + r.downloadDir) < 0
                        && dc.indexOf("mv '/tmp/parts/1.part'") >= 0)
                        + " (期望 true：part 落缓存区、mv 才进歌库)")
            // 空队列时 kick 不该崩、视图清空
            r.dlRunning = ""; r.dlQueue = []; r.dlPending = {}
            r.refreshQueueView()
            console.log("CHK dlq empty len=" + r.dlQueueView.length + " tab=" + r.dlTabLabel
                        + " (期望 0 / 本地)")

            // ---- parseDlDump：轮询输出解析（0% 事故的根因就在这）----
            // 格式 A：st 无尾部换行（ok:/fail: 和旧 total: 写法）
            var dA = r.parseDlDump("@@GDDL1@@\nok:9706605\n-\n")
            console.log("CHK dlparse A st=" + dA[0].st + " sz=" + dA[0].sz + " (期望 ok:9706605 / -)")
            // 格式 B：st 带尾部换行（曾经 total:%s\n 的写法）—— 中间多一个空行
            var dB = r.parseDlDump("@@GDDL2@@\ntotal:3706924\n\n486532\n")
            console.log("CHK dlparse B st=" + dB[0].st + " sz=" + dB[0].sz
                        + " (期望 total:3706924 / 486532 —— 修复前 sz 会是空)")
            // 状态完成 + part 还在的混合
            var dC = r.parseDlDump("@@GDDL3@@\ntotal:1000\n512\n@@GDDL4@@\n\n-\n")
            console.log("CHK dlparse C n=" + dC.length + " st3=" + dC[0].st + " sz3=" + dC[0].sz
                        + " st4=" + dC[1].st + " sz4=" + dC[1].sz
                        + " (期望 2 / total:1000 / 512 / '' / -)")
            // 空输出
            var dD = r.parseDlDump("")
            console.log("CHK dlparse D n=" + dD.length + " (期望 0)")

            Qt.quit()
        }
    }
}
