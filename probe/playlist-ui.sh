#!/bin/bash
# 验证「歌单页（列表页 + 详情页）」—— 静态结构断言 + 把真源码抠出来求值的行为断言。
#
# 沿用 preferlocal.sh / filemap.sh / playlists.sh 的套路：**不喂假数据，而是把真源码抠出来求值**。
# 这类"页面 + 接线"的改动最容易坏的形态，纯静态检查一种都测不出来：
#   ① 函数/页面写好了但没接上线（文件都在、逻辑也对，就是点不到）
#   ② 详情页直接读 playlistById(id).songs ⇒ 写操作后歌单对象仍是同一引用，
#      songs 绑定不重算 ⇒ 「数据变了、列表不刷新」（最难查的一类）
# 所以这里的主体是**接线断言**（查源文本）+ **值重建断言**（求值 plView）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
QML="$ROOT/plugin/qml/main.qml"
PL="$ROOT/plugin/qml/pages/PlaylistPage.qml"
DT="$ROOT/plugin/qml/pages/PlaylistDetailPage.qml"
DIR="$ROOT/plugin/qml/qmldir"
NODE="${NODE:-}"
[ -x "$NODE" ] || NODE=$(command -v node)
for f in "$QML" "$PL" "$DT" "$DIR"; do
    [ -f "$f" ] || { echo "找不到 $f"; exit 1; }
done

"$NODE" - "$QML" "$PL" "$DT" "$DIR" "$ROOT/plugin/qml/pages" <<'JS'
'use strict'
const fs = require('fs'), path = require('path')
const [qmlPath, plPath, dtPath, dirPath, pagesDir] = process.argv.slice(2)

const src = fs.readFileSync(qmlPath, 'utf8')
const pl  = fs.readFileSync(plPath,  'utf8')
const dt  = fs.readFileSync(dtPath,  'utf8')
const dir = fs.readFileSync(dirPath, 'utf8')

// 去掉整行注释：注释里的花括号会把「括号配平」截取法带偏，
// 注释里提到的函数名也会让"接线断言"假阳性（本文件的注释就大量提到函数名）。
const clean = s => s.replace(/^[ \t]*\/\/.*$/gm, '')
const qmlC = clean(src), plC = clean(pl), dtC = clean(dt)

let pass = 0
const fails = []
function check(cond, msg) {
    if (cond) { pass++; return true }
    fails.push(msg); return false
}

function grab(text, name) {
    const i = text.indexOf('function ' + name + '(')
    if (i < 0) throw new Error('找不到 function ' + name)
    let depth = 0, k = text.indexOf('{', i)
    for (; k < text.length; k++) {
        const c = text[k]
        if (c === '{') depth++
        else if (c === '}') { depth--; if (depth === 0) break }
    }
    if (depth !== 0) throw new Error(name + ' 花括号未配平')
    return text.slice(i, k + 1)
}

// 抠 `property ... name: { ... }` 绑定体，转成 function _bound() { ... }
function grabBinding(text, decl) {
    const i = text.indexOf(decl)
    if (i < 0) throw new Error('找不到 ' + decl)
    let depth = 0, k = text.indexOf('{', i)
    for (; k < text.length; k++) {
        const c = text[k]
        if (c === '{') depth++
        else if (c === '}') { depth--; if (depth === 0) break }
    }
    if (depth !== 0) throw new Error(decl + ' 花括号未配平')
    return 'function _bound() ' + text.slice(text.indexOf('{', i), k + 1)
}

const md = src.match(/readonly property string downloadDir:\s*"([^"]+)"/)
if (!md) { console.error('读不到 downloadDir'); process.exit(1) }
const D = md[1]

// ============================================================
// A. 文件与 qmldir 注册
// ============================================================
check(/PlaylistPage 1\.0 pages\/PlaylistPage\.qml/.test(dir), 'A1 qmldir 未注册 PlaylistPage')
check(/PlaylistDetailPage 1\.0 pages\/PlaylistDetailPage\.qml/.test(dir), 'A2 qmldir 未注册 PlaylistDetailPage')

// ============================================================
// B. main.qml 接线
// ============================================================
check(/Pages\.PlaylistPage\s*\{/.test(qmlC), 'B1 main.qml 未实例化 Pages.PlaylistPage')
check(/Pages\.PlaylistDetailPage\s*\{/.test(qmlC), 'B2 main.qml 未实例化 Pages.PlaylistDetailPage')
check(/page\s*===\s*"playlists"/.test(qmlC), 'B3 歌单列表页没有 visible 绑定 page === "playlists"')
check(/page\s*===\s*"playlist"/.test(qmlC), 'B4 详情页没有 visible 绑定 page === "playlist"')

const iPl  = qmlC.indexOf('Pages.PlaylistPage')
const iDt  = qmlC.indexOf('Pages.PlaylistDetailPage')
const iMat = qmlC.indexOf('Pages.MatchPage')
check(iPl > 0 && iDt > iPl, 'B5 详情页必须声明在列表页之后（否则盖不住列表页）')
check(iMat > iDt,           'B6 MatchPage 必须仍是最晚声明（它要盖在所有页面之上）')

const goPl = grab(qmlC, 'goPlaylists')
check(/page\s*=\s*"playlists"/.test(goPl), 'B7 goPlaylists 没有把 page 设成 "playlists"')

const opPl = grab(qmlC, 'openPlaylist')
check(/plCurId\s*=\s*id/.test(opPl),           'B8 openPlaylist 没有设 plCurId')
check(/backPage\s*=\s*"playlists"/.test(opPl), 'B9 openPlaylist 没把 backPage 设成歌单页（返回会回到意外的地方）')
check(/playlistById\(id\)/.test(opPl),         'B10 openPlaylist 没校验歌单是否存在')

const clPl = grab(qmlC, 'closePlaylistDetail')
check(/plCurId\s*=\s*""/.test(clPl),       'B11 closePlaylistDetail 没清 plCurId（下次进来会拿到旧歌单）')
check(/page\s*=\s*"playlists"/.test(clPl), 'B12 closePlaylistDetail 没有回到歌单列表')

// ============================================================
// C. 把 plView / plStat 抠出来求值
// ============================================================
const plViewSrc = grabBinding(qmlC, 'readonly property var plView:')
const plStatSrc = grabBinding(qmlC, 'readonly property string plStat:')

check(/pl\.songs\.slice\(0\)/.test(plViewSrc), 'C1 plView 没有拷贝 songs（slice(0)）—— 页面会拿到真数据')

// 自由变量与桩：与 main.qml 同名同形，函数闭包才能读到。
const PRELUDE = [
    'var downloadDir = ' + JSON.stringify(D),
    'var preferLocal = true, minLocalBytes = 65536',
    'var localList = [], fileMap = ({})',
    'var playlists = [], plCurId = "", plNewType = ""',
    'var playlistMax = 20, playlistSongMax = 300, playlistNameMax = 24',
    'var source = "netease"',
    'var queue = [], page = "", idxHit = -1, saveCalls = 0, warns = []',
    'var toast = { last: "", show: function (m) { this.last = String(m) } }',
    'var editTarget = ""',
    'var keyboard = { opened: null, calls: 0, open: function (t) { this.opened = t; this.calls++ } }',
    'var console = { warn: function (m) { warns.push(String(m)) }, log: function () {}, error: function () {} }',
    'var __v',
    'function startAt(i) { idxHit = i }',
    'function savePlaylists() { saveCalls++ }',
    grab(qmlC, 'playlistIndexById'),
    grab(qmlC, 'playlistById'),
    grab(qmlC, 'plKeyOf'),
    grab(qmlC, 'songKeyOf'),
    grab(qmlC, 'sanitizeName'),
    grab(qmlC, 'localNameFor'),
    grab(qmlC, 'localPathFor'),
    grab(qmlC, 'mappedPathFor'),
    grab(qmlC, 'findLocal'),
    grab(qmlC, 'resolveEntry'),
    grab(qmlC, 'plErrText'),
    grab(qmlC, 'copySong'),
    grab(qmlC, 'playlistTypeText'),
    grab(qmlC, 'localFileOf'),
    grab(qmlC, 'plToast'),
    grab(qmlC, 'playPlaylist'),
    grab(qmlC, 'playPlaylistUI'),
    grab(qmlC, 'removeSongFromPlaylist'),
    grab(qmlC, 'removeSongAt'),
    grab(qmlC, 'removeSongAtUI'),
    grab(qmlC, 'createPlaylist'),
    grab(qmlC, 'clonePlaylists'),
    grab(qmlC, 'cleanPlaylistName'),
    grab(qmlC, 'sanitizeSong'),
    grab(qmlC, 'beginCreatePlaylist')
].join('\n')

function makeScope(bindingSrc) {
    // 只暴露 gp/sp：eval 在函数体内执行，只能看见**局部变量名**，
    // 看不见 return 对象的属性名（写 view: fn 再 eval('view') 会 ReferenceError）。
    // 所以绑定体先落成局部变量 __viewFn，外部用 gp('__viewFn')() 取回来调用。
    const body = PRELUDE + '\n' + bindingSrc + '\n' + [
        'var __viewFn = function () { return _bound() }',
        'return {',
        '  gp:   function (n) { return eval(n) },',
        '  sp:   function (n, v) { __v = v; eval(n + " = __v") },',
        '  warns: warns,',
        '  saves: function () { return saveCalls }',
        '}'
    ].join('\n')
    return new Function(body)()
}

const vs = makeScope(plViewSrc)   // plView 作用域
const ss = makeScope(plStatSrc)   // plStat 作用域

// ---- plView：值重建 ----
vs.sp('playlists', [{ id: 'pl_a', name: '我喜欢的', type: 'online', created: 1,
                      songs: [{ id: '1', source: 'netease', name: '歌一', artist: '甲' },
                              { id: '2', source: 'netease', name: '歌二', artist: '乙' }] }])
vs.sp('plCurId', 'pl_a')

const v1 = vs.gp('__viewFn')()
check(!!v1, 'C2 plView 在 id 有效时返回了空')
check(v1 && v1.id === 'pl_a' && v1.count === 2, 'C3 plView 的 id/count 不对')
check(v1 && v1.songs && v1.songs.length === 2, 'C4 plView.songs 条数不对')
check(!!(v1 && v1.songs) && v1.songs !== vs.gp('playlists')[0].songs,
      'C5 plView.songs 不是拷贝（与真数据同一个数组）')

v1.songs.push({ id: '9', source: 'netease', name: '伪造' })
check(vs.gp('playlists')[0].songs.length === 2, 'C6 改 plView.songs 竟然改到了真数据（没隔离）')

// ❗核心断言：外层数组整体重新赋值（歌单对象**同一个引用**）后，
//   plView 必须返回**值不同**的新对象 —— 否则界面拿到的还是旧引用，绑定不重算，
//   症状就是「数据对了、列表不刷新」。
vs.sp('playlists', vs.gp('playlists').slice(0))   // 外层新数组、元素同一引用
const v2 = vs.gp('__viewFn')()
check(v2 !== v1, 'C7 外层数组重新赋值后 plView 返回了同一个对象 ⇒ 列表不会刷新（这正是要防的坑）')
check(v2.songs !== v1.songs, 'C8 两次 plView 的 songs 是同一个数组 ⇒ 变化不会被看见')

// 写操作真的改了内容 ⇒ 视图能反映
vs.sp('playlists', [{ id: 'pl_a', name: '我喜欢的', type: 'online', created: 1,
                      songs: [{ id: '1', source: 'netease', name: '歌一', artist: '甲' }] }])
check(vs.gp('__viewFn')().count === 1, 'C9 歌单内容变少后 plView.count 没跟上')

vs.sp('plCurId', '')
check(vs.gp('__viewFn')() === null, 'C10 plCurId 为空时 plView 应返回 null')
vs.sp('plCurId', 'pl_nope')
check(vs.gp('__viewFn')() === null, 'C11 plCurId 指向不存在的歌单时 plView 应返回 null')

// ---- plStat ----
ss.sp('playlists', [])
check(ss.gp('__viewFn')() === '0 个歌单 · 共 0 首', 'C12 空歌单时 plStat 文案不对：' + ss.gp('__viewFn')())
ss.sp('playlists', [{ id: 'a', name: 'A', type: 'online', songs: [{ id: '1' }, { id: '2' }] },
                    { id: 'b', name: 'B', type: 'local',  songs: [{ file: '/x.mp3' }] }])
check(ss.gp('__viewFn')() === '2 个歌单 · 共 3 首', 'C13 plStat 统计不对：' + ss.gp('__viewFn')())

// ============================================================
// D. localFileOf —— 徽标判据必须与"实际会不会走本地"一致
// ============================================================
const DD = D
vs.sp('localList', [{ file: DD + '/命中-甲.mp3', size: 9000000, name: '命中', artist: '甲' },
                    { file: DD + '/半截-乙.mp3', size: 1024,   name: '半截', artist: '乙' }])
vs.sp('fileMap', ({}))

check(vs.gp('localFileOf')({ id: '1', source: 'netease', name: '命中', artist: '甲' }) === DD + '/命中-甲.mp3',
      'D1 在线歌能精确命中本地时 localFileOf 没返回路径')
check(vs.gp('localFileOf')({ id: '2', source: 'netease', name: '没有', artist: '无' }) === '',
      'D2 未命中时 localFileOf 应返回空串')
check(vs.gp('localFileOf')({ file: '/x/y.mp3', name: 'n', artist: 'a' }) === '/x/y.mp3',
      'D3 本地条目应返回自己的文件')
check(vs.gp('localFileOf')(null) === '', 'D4 null 入参应变空串而不是抛')

// 半截文件：resolveEntry 不认（< minLocalBytes）⇒ 徽标不该亮。
// 但 findLocal 认得 —— 这正是"徽标不能用 findLocal"的证据，把差别钉住。
const stubSong = { id: '3', source: 'netease', name: '半截', artist: '乙' }
check(vs.gp('localFileOf')(stubSong) === '',
      'D5 半截文件（< 64KB）不该亮本地命中徽标（否则显示 ✓ 却仍在联网取流）')
check(vs.gp('findLocal')(stubSong) !== null,
      'D6 findLocal 与 localFileOf 的判据差异消失了 —— 注释里那句"两者判据不同"已不成立')

// 登记表反查也要生效（改过名的文件）
vs.sp('fileMap', ({}))
const mapped = { id: '4', source: 'netease', name: '改名了', artist: '丙' }
vs.sp('localList', [{ file: DD + '/改过名的文件.mp3', size: 5000000, name: '改过名的文件', artist: '' }])
vs.gp('localFileOf')(mapped)
// 登记表键是文件绝对路径
vs.sp('fileMap', JSON.parse('{"' + DD + '/改过名的文件.mp3": {"id":"4","source":"netease"}}'))
check(vs.gp('localFileOf')(mapped) === DD + '/改过名的文件.mp3',
      'D7 登记表反查没生效（手动匹配过的文件徽标不亮）')

// ============================================================
// E. plToast / playPlaylistUI / removeSongAtUI —— 结果码 → 提示
// ============================================================
vs.sp('toast', { last: 'X', show: function (m) { this.last = String(m) } })
check(vs.gp('plToast')({ ok: true, err: '' }) === true,  'E1 plToast 对成功应返回 true')
check(vs.gp('toast').last === 'X',                           'E2 plToast 对成功不该弹提示')
check(vs.gp('plToast')({ ok: false, err: 'E_FULL' }) === false, 'E3 plToast 对失败应返回 false')
check(vs.gp('toast').last === '单个歌单最多 300 首', 'E4 plToast 失败时没弹对应文案：' + vs.gp('toast').last)
check(vs.gp('plToast')(null) === true, 'E5 plToast 收到 null 应宽容返回 true')

// playPlaylistUI：转发并携带歌单
vs.sp('playlists', [{ id: 'pl_a', name: 'A', type: 'online',
                      songs: [{ id: '1', source: 'netease', name: 'x', artist: 'y' }] }])
vs.sp('queue', []); vs.sp('page', 'playlists'); vs.sp('idxHit', -1)
vs.gp('playPlaylistUI')('pl_a', 0)
check(vs.gp('queue').length === 1 && vs.gp('page') === 'player' && vs.gp('idxHit') === 0,
      'E6 playPlaylistUI 没有把队列/页面/起播位设对')
check(vs.gp('queue')[0] !== vs.gp('playlists')[0].songs[0],
      'E7 playPlaylistUI 把歌单里的条目**同一个引用**放进了队列 ⇒ 之后编辑歌单会当场改掉正在播的队列')

vs.sp('queue', []); vs.sp('page', 'playlists')
vs.gp('playPlaylistUI')('pl_nope', 0)
// 歌单不存在 → playPlaylist 返回 E_EMPTY（它把"没有"和"空歌单"归为同一支）
check(vs.gp('page') === 'playlists' && vs.gp('toast').last === '歌单是空的',
      'E8 播不存在的歌单时应弹错误且不切页（实际：' + vs.gp('toast').last + '）')

// removeSongAtUI
vs.sp('toast', { last: '', show: function (m) { this.last = String(m) } })
vs.sp('playlists', [{ id: 'pl_a', name: 'A', type: 'online',
                      songs: [{ id: '1', source: 'netease', name: '一', artist: '' },
                              { id: '2', source: 'netease', name: '二', artist: '' }] }])
check(vs.gp('removeSongAtUI')('pl_a', 0) === true, 'E9 removeSongAtUI 成功应返回 true')
check(vs.gp('playlists')[0].songs.length === 1, 'E10 removeSongAtUI 没真的移除')
check(vs.gp('playlists')[0].songs[0].id === '2', 'E11 removeSongAtUI 移错了行')
check(vs.gp('toast').last === '已从歌单移除', 'E12 removeSongAtUI 成功后没提示')
vs.sp('toast', { last: '', show: function (m) { this.last = String(m) } })
check(vs.gp('removeSongAtUI')('pl_a', 99) === false, 'E13 越界移除应返回 false')
check(vs.gp('toast').last === '操作失败', 'E14 越界移除不该提示"已移除"：' + vs.gp('toast').last)

// ============================================================
// F. 新建歌单流程
// ============================================================
const bc = grab(qmlC, 'beginCreatePlaylist')
check(/type !== "online" && type !== "local"/.test(bc), 'F1 beginCreatePlaylist 没校验类型')
check(/playlists\.length\s*>=\s*playlistMax/.test(bc),  'F2 beginCreatePlaylist 没先拦上限')
check(/plNewType\s*=\s*type/.test(bc),                  'F3 beginCreatePlaylist 没记下类型')
check(/keyboard\.open\(/.test(bc),                      'F4 beginCreatePlaylist 没唤起输入页')
check(/editTarget\s*=\s*"plName"/.test(bc),             'F5 beginCreatePlaylist 没设置 editTarget="plName"')

// 类型必须在开键盘之前定下来（键盘弹出来就盖住浮层，用户没法再选一次）
check(bc.indexOf('plNewType = type') < bc.indexOf('keyboard.open('),
      'F6 plNewType 必须在键盘弹出之前设好，否则用户没法再选类型')

vs.sp('toast', { last: '', show: function (m) { this.last = String(m) } })
vs.sp('keyboard', { opened: null, calls: 0, open: function (t) { this.opened = t; this.calls++ } })
vs.sp('editTarget', '')
vs.sp('playlists', [])
vs.gp('beginCreatePlaylist')('bogus', 'bogus')
check(vs.gp('keyboard').calls === 0, 'F7 非法类型不该唤起键盘')

vs.sp('playlists', new Array(20).fill({ id: 'x', name: 'x', type: 'online', songs: [] }))
vs.gp('beginCreatePlaylist')('online', 'online')
check(vs.gp('keyboard').calls === 0 && vs.gp('toast').last === '最多 20 个歌单',
      'F8 歌单已满时不该唤起键盘（应在打字前就告诉用户）')

vs.sp('playlists', [])
vs.gp('beginCreatePlaylist')('local', 'local')
check(vs.gp('keyboard').calls === 1 && vs.gp('keyboard').opened === '',
      'F9 正常新建应唤起键盘且预填空串')
check(vs.gp('plNewType') === 'local' && vs.gp('editTarget') === 'plName',
      'F10 正常新建没把类型/编辑目标设对')

// onKeyboardAccepted 的 plName 分支
const acc = grab(qmlC, 'onKeyboardAccepted')
check(/t === "plName"/.test(acc), 'F11 onKeyboardAccepted 没有 plName 分支（新建歌单走不通）')
const b = acc.indexOf('t === "plName"')
let depth = 0, k = acc.indexOf('{', b), end = k
for (; k < acc.length; k++) {
    if (acc[k] === '{') depth++
    else if (acc[k] === '}') { depth--; if (depth === 0) { end = k; break } }
}
const branch = acc.slice(b, end + 1)
check(/createPlaylist\(content,\s*plNewType\)/.test(branch), 'F12 plName 分支没用 createPlaylist(content, plNewType)')
check(/plErrText\(res\.err\)/.test(branch),                  'F13 plName 分支失败时没弹错误文案')
check(!/!\s*content/.test(branch) && !/content\.length/.test(branch),
      'F14 plName 分支自己判了空 —— 空名判定应只留在 createPlaylist 里（两处判断迟早不一致）')

// ============================================================
// G. 页面结构：objectName 与声明顺序
// ============================================================
for (const n of ['gdPlaylistList', 'gdPlRowTapArea', 'gdPlPlayBtn', 'gdPlNewBtn',
                 'gdPlTypePopup', 'gdPlTypeTag'])
    check(plC.indexOf('"' + n + '"') > 0, 'G1 PlaylistPage 缺 objectName ' + n)

check(plC.indexOf('gdPlRowTapArea') < plC.indexOf('gdPlPlayBtn'),
      'G2 PlaylistPage：整行点击区必须声明在 ▶ 之前（否则 ▶ 点不动 —— 本地页栽过同一个坑）')
check(/tabIndex:\s*2/.test(plC), 'G3 PlaylistPage 的 tabIndex 不是 2')
check(/tabLabels:\s*\[.*"歌单"\s*\]/.test(plC), 'G4 PlaylistPage 的 tabLabels 没含"歌单"')
check(/index\s*===\s*0[\s\S]{0,80}goSearch\(\)/.test(plC) &&
      /index\s*===\s*1[\s\S]{0,80}goLocal\(\)/.test(plC),
      'G5 PlaylistPage 的 tab 分支没覆盖去搜索页/本地页')
check(/beginCreatePlaylist\(modelData\.t\)/.test(plC), 'G6 新建浮层没走 beginCreatePlaylist')
check(/exitPlugin\(\)/.test(plC), 'G7 歌单页返回键没接 exitPlugin（根页面约定）')

for (const n of ['gdPlDetailList', 'gdPlSongTapArea', 'gdPlSongDelBtn', 'gdPlPlayAllBtn',
                 'gdPlDetailHitSlot', 'gdPlDetailHitTag'])
    check(dtC.indexOf('"' + n + '"') > 0, 'G8 PlaylistDetailPage 缺 objectName ' + n)

check(dtC.indexOf('gdPlSongTapArea') < dtC.indexOf('gdPlSongDelBtn'),
      'G9 PlaylistDetailPage：整行点击区必须声明在 × 之前（否则 × 点不动）')
check(/closePlaylistDetail\(\)/.test(dtC), 'G10 详情页返回键没接 closePlaylistDetail')
check(/playPlaylistUI\(detailPage\.pl\.id,\s*0\)/.test(dtC), 'G11 「播放全部」没接 playPlaylistUI')
check(/removeSongAtUI\(detailPage\.pl\.id,\s*index\)/.test(dtC), 'G12 行内移除没接 removeSongAtUI')

// ============================================================
// H. 禁止项
// ============================================================
// 页面必须走 plView，不能直接索引真数据
check(!/controller\.playlists\s*\[/.test(plC) && !/controller\.playlists\s*\[/.test(dtC),
      'H1 页面直接索引 controller.playlists —— 必须走 plView（否则刷新不可靠）')
check(/controller\.plView/.test(dtC), 'H2 详情页根本没读 plView')

// "▶" 等 U+25xx 字形在设备字体里基本没有，会显示成豆腐块
for (const [name, text] of [['PlaylistPage', plC], ['PlaylistDetailPage', dtC]]) {
    const bad = text.match(/[\u25B6\u25B7\u25C0\u2605\u2606\u2714\u2716]/g)
    check(!bad, 'H3 ' + name + ' 里用了可能缺字形的符号：' + (bad ? bad.join(' ') : ''))
}

// 严格布尔：`a && b` 直接赋给 bool 属性时，中间项为 null/undefined 会让整个表达式
// 返回 undefined ⇒ 设备每帧刷一条 "Unable to assign [undefined] to bool"，日志写 flash。
// （LocalPage 的 matchedFlag / MatchPage 的 hasMatch 都是为此加的 !!，这里防回归。）
for (const [name, text] of [['PlaylistPage', plC], ['PlaylistDetailPage', dtC]]) {
    const bad = []
    for (const line of text.split('\n')) {
        const m = line.match(/^\s*(visible|enabled|clip|asynchronous|font\.bold)\s*:\s*(.+)$/)
        if (!m) continue
        const expr = m[2].trim()
        // 三元表达式不受影响（条件为假时返回另一支，不会漏出 undefined）
        if (expr.includes('&&') && !expr.includes('!!') && !/\?/.test(expr))
            bad.push(line.trim())
    }
    check(bad.length === 0, 'H4 ' + name + ' 里 bool 属性可能收到 undefined（缺 !! 收敛）：' + bad.join(' | '))
}

// ============================================================
// I. 三个 tab 页的一致性
// ============================================================
const pagesDirFiles = fs.readdirSync(pagesDir).filter(f => f.endsWith('.qml'))
const SP = fs.readFileSync(path.join(pagesDir, 'SearchPage.qml'), 'utf8')
const LP = fs.readFileSync(path.join(pagesDir, 'LocalPage.qml'), 'utf8')
const SPc = clean(SP), LPc = clean(LP)

check(/tabLabels:\s*\[[^\]]*"歌单"\s*\]/.test(SPc), 'I1 SearchPage 的 tabLabels 没加"歌单"')
check(/tabLabels:\s*\[[^\]]*"歌单"\s*\]/.test(LPc), 'I2 LocalPage 的 tabLabels 没加"歌单"')
check(/index\s*===\s*2[\s\S]{0,80}goPlaylists\(\)/.test(SPc), 'I3 SearchPage 的 tab2 没接 goPlaylists')
check(/index\s*===\s*2[\s\S]{0,80}goPlaylists\(\)/.test(LPc), 'I4 LocalPage 的 tab2 没接 goPlaylists')
check(/tabIndex:\s*0/.test(SPc), 'I5 SearchPage 的 tabIndex 不是 0')
check(/tabIndex:\s*1/.test(LPc), 'I6 LocalPage 的 tabIndex 不是 1')

// 页面调用的 controller 成员必须真的存在（拼错只有在运行时才暴露，而且往往只是"点了没反应"）
const mainMembers = new Set()
for (const m of qmlC.matchAll(/function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g)) mainMembers.add(m[1])
for (const m of qmlC.matchAll(/property\s+(?:var|string|int|bool|double|color)\s+([A-Za-z_][A-Za-z0-9_]*)/g))
    mainMembers.add(m[1])
for (const m of qmlC.matchAll(/readonly\s+property\s+(?:var|string|int|bool|double|color)\s+([A-Za-z_][A-Za-z0-9_]*)/g))
    mainMembers.add(m[1])
for (const m of qmlC.matchAll(/signal\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g)) mainMembers.add(m[1])

const missing = {}
for (const f of pagesDirFiles) {
    const t = clean(fs.readFileSync(path.join(pagesDir, f), 'utf8'))
    for (const m of t.matchAll(/controller\.([A-Za-z_][A-Za-z0-9_]*)/g)) {
        if (!mainMembers.has(m[1])) (missing[f] = missing[f] || []).push(m[1])
    }
}
const missList = Object.keys(missing).map(f => f + ': ' + [...new Set(missing[f])].join(','))
check(missList.length === 0, 'I7 页面调用了 main.qml 里不存在的 controller 成员 → ' + missList.join(' ; '))

// ============================================================
// J. 括号配平（本地没有 Qt，这是最便宜的"能不能解析"替代品）
// ============================================================
// ⚠️ 必须**剥掉字符串、注释、正则字面量**再数：main.qml 的 shell 命令、JSON 模板、
//    正则里散落着大量括号（实测未剥离时花括号多出 3 个，是字符串里的，不是真错）。
//    正则字面量尤其阴险：sanitizeName 的 `/[\/\\:\*\?"<>\|]/g` 里的 `"` 会把不认
//    正则的剥离器带进"字符串模式"、吞掉后续全部括号 ⇒ 正确代码报"差 2 个"。
//    识别正则的规则刻意保守：仅当前一非空白字符是 = ( , : ; ! & | ? { } [ 换行、
//    或前文是 return/case/typeof/instanceof/throw/void 时才按正则跳过；除法（a / b）
//    的前一字符是标识符/数字，不会被误判。
function countPairs(text, open, close) {
    let d = 0, inS = null, esc = false
    for (let i = 0; i < text.length; i++) {
        const c = text[i]
        if (inS) {
            if (esc) { esc = false; continue }
            if (c === '\\') { esc = true; continue }
            if (c === inS) inS = null
            continue
        }
        if (c === '"' || c === "'" || c === '`') { inS = c; continue }
        if (c === '/' && text[i + 1] === '/') { while (i < text.length && text[i] !== '\n') i++; continue }
        if (c === '/' && text[i + 1] === '*') {
            i += 2
            while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i++
            i++
            continue
        }
        if (c === '/') {
            const prev = text.slice(Math.max(0, i - 12), i)
            const afterKw = /(return|case|typeof|instanceof|throw|void)\s*$/.test(prev)
            const pm = prev.match(/[^\s]$/)
            const afterPunct = pm && /[=(,:;!&|?{}[\n]/.test(pm[0])
            if (afterKw || afterPunct) {
                let j = i + 1, inCls = false, ok = true
                while (j < text.length) {
                    if (text[j] === '\\') { j += 2; continue }
                    if (text[j] === '[') inCls = true
                    else if (text[j] === ']') inCls = false
                    else if (text[j] === '/' && !inCls) break
                    else if (text[j] === '\n') { ok = false; break }   // 换行=不是正则
                    j++
                }
                if (ok) { i = j; continue }                             // 整个正则跳过
            }
        }
        if (c === open) d++
        else if (c === close) { d--; if (d < 0) return -1 }   // 提前闭合
    }
    if (inS) return -2                                          // 引号忘了收尾
    return d                                                    // 0 = 配平
}

for (const [name, t] of [['main.qml', src],
                         ['PlaylistPage.qml', pl],
                         ['PlaylistDetailPage.qml', dt]]) {
    for (const [o, c, label] of [['{', '}', '花括号'], ['(', ')', '圆括号']]) {
        const r = countPairs(t, o, c)
        check(r === 0, 'J1 ' + name + ' ' + label + '不配平（' +
              (r === -1 ? '提前闭合' : r === -2 ? '引号未闭合' : '差 ' + r + ' 个') + '）')
    }
}
// 方括号：剥离器现在认正则字面量（sanitizeName 的 `"` 不再带偏），
// main.qml 也可以一起查了。
for (const [name, t] of [['main.qml', src], ['PlaylistPage.qml', plC], ['PlaylistDetailPage.qml', dtC]]) {
    const r = countPairs(t, '[', ']')
    check(r === 0, 'J1 ' + name + ' 方括号不配平（' + (r === -1 ? '提前闭合' : '差 ' + r + ' 个') + '）')
}

// 页面尺寸写错会让页面只画一部分（或右下角留白），而 QML 不会报任何错
for (const [name, t] of [['PlaylistPage', plC], ['PlaylistDetailPage', dtC]]) {
    check(/width:\s*320/.test(t) && /height:\s*170/.test(t), 'J2 ' + name + ' 尺寸不是 320×170')
}

// ============================================================
// ============ 来源标记：网易云导入的歌单要看得出来 ============
console.log('=== 歌单来源标记（网易云）===')
check(/pl\.source === "netease"/.test(plC), '列表行按 source 判来源')
check(/fromNc[\s\S]{0,200}?"网易云"/.test(plC) || /网易云/.test(plC), '列表页副标题带「网易云」标记')
check(/pl\.source === "netease"/.test(dtC), '详情页按 source 判来源')
check(/"网易云"/.test(dtC), '详情页有「网易云」来源徽标')
// 徽标用网易云品牌红，跟「在线蓝 / 离线绿」不撞色
check(/#E60026/.test(dtC), '来源徽标用网易云红（与在线/离线徽标不同色，语义不混）')
{
  const ap = clean(fs.readFileSync(path.join(pagesDir, 'AddToPlaylistPage.qml'), 'utf8'))
  check(/entry\.source === "netease"/.test(ap), '「加入歌单」页也标出网易云来源（知道加到了哪类歌单）')
}

console.log('')
if (fails.length) {
    console.log('FAIL ❌ ' + fails.length + ' 项未通过（pass=' + pass + '）')
    for (const f of fails) console.log('   - ' + f)
    process.exit(1)
}
console.log('PASS ✅ 歌单 UI 层 · ' + pass + ' 项断言全过')
JS
