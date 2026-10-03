#!/bin/bash
# 验证 P4「歌单重命名 / 删除 / 排序」—— 拿 main.qml 的真源码求值再断言。
#
# 覆盖三组：
#   A 纯函数：movePlaylist（边界 + 交换）、renamePlaylist、deletePlaylist、cleanPlaylistName
#   B 接线断言：beginRenamePlaylist 设 plRenameId + editTarget + 预填名；
#               onKeyboardAccepted 的 "plRename" 分支真的调 renamePlaylist
#   C 页面接线：PlaylistPage 长按开菜单、菜单项分别调 controller 的对应方法
#
# 为什么排序/重命名/删除的「真机交互」不在这里测：
#   长按、浮层、二次确认这类触摸行为，源码求值测不到「手真的点了」，只能测「接线对」。
#   真机交互交给 probe/playlist-edit-device.qml（离屏探针，直接调 handler）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
QML="$ROOT/plugin/qml/main.qml"
PAGE="$ROOT/plugin/qml/pages/PlaylistPage.qml"
NODE="${NODE:-}"
[ -x "$NODE" ] || NODE=$(command -v node)
[ -f "$QML" ] || { echo "找不到 $QML"; exit 1; }

"$NODE" - "$QML" "$PAGE" <<'JS'
'use strict'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8')
const pageSrc = fs.readFileSync(process.argv[3], 'utf8')

const clean = src.replace(/^[ \t]*\/\/.*$/gm, '')
const pageClean = pageSrc.replace(/^[ \t]*\/\/.*$/gm, '')
let pass = 0, bad = 0
function die(m) { console.error('FAIL ❌ ' + m); process.exit(1) }
function ok(c, m) { if (c) { pass++; console.log('  ok  ' + m) } else { bad++; console.log('  BAD ' + m) } }

// —— 与 sidecar.sh 同款：等长遮蔽 + 花括号配平截取 ——
function stripLiterals(s) {
    const out = s.split('')
    const mask = (a, b) => { for (let k = a; k < b && k < out.length; k++) out[k] = 'x' }
    let i = 0, n = s.length, prev = ''
    while (i < n) {
        const c = s[i]
        if (c === '"' || c === "'") {
            const q = c, st = i; i++
            while (i < n && s[i] !== q) { if (s[i] === '\\') i++; i++ }
            if (i >= n) return -2
            i++; mask(st, i); prev = 'x'; continue
        }
        if (c === '/' && s[i + 1] === '/') { const st = i; while (i < n && s[i] !== '\n') i++; mask(st, i); continue }
        if (c === '/' && s[i + 1] === '*') { const st = i; i += 2; while (i < n && !(s[i] === '*' && s[i + 1] === '/')) i++; i += 2; mask(st, i); prev = 'x'; continue }
        if (c === '/' && (prev === '' || '(,=:[!&|?{};+-*%~^'.indexOf(prev) >= 0)) {
            let j = i + 1, inCls = false, okk = false
            while (j < n && s[j] !== '\n') {
                if (s[j] === '\\') { j += 2; continue }
                if (s[j] === '[') inCls = true
                else if (s[j] === ']') inCls = false
                else if (s[j] === '/' && !inCls) { okk = true; break }
                j++
            }
            if (okk) { let k = j + 1; if (s[k] === 'g' || s[k] === 'i' || s[k] === 'm') k++; mask(i, k); i = k; prev = 'x'; continue }
        }
        if (!/\s/.test(c)) prev = c
        i++
    }
    return out
}
function grabIn(text, name) {
    const i = text.indexOf('function ' + name)
    if (i < 0) die('找不到 function ' + name)
    let k = text.indexOf('{', i)
    if (k < 0) die(name + ' 找不到函数体')
    const st = stripLiterals(text.slice(i))
    if (st === -2) die(name + ' 引号未闭合')
    let depth = 0
    for (let j = k; j < text.length; j++) {
        const c = st[j - i]
        if (c === '{') depth++
        else if (c === '}') { depth--; if (depth === 0) { k = j; break } }
    }
    if (depth !== 0) die(name + ' 花括号未配平')
    return text.slice(i, k + 1)
}
function grab(name) { return grabIn(clean, name) }

// ============================================================
// A. 纯函数求值
// ============================================================
console.log('--- A. 数据层纯函数 ---')

// 抠出 4 个纯函数 + 依赖的 playlistIndexById / clonePlaylists
const pureBody = [
  'playlistIndexById', 'clonePlaylists', 'cleanPlaylistName',
  'movePlaylist', 'renamePlaylist', 'deletePlaylist'
].map(n => grab(n)).join('\n\n')

function makeEnv(seed) {
  // seed = 初始歌单数组（[{id,name,type,songs}]）
  const api = new Function('seed', `
    var playlists = seed.slice(0)
    var savePlaylists = function () { saveCount++ }
    var saveCount = 0
    var playlistNameMax = 24
    ${pureBody}
    return {
      playlists: function(){ return playlists },
      saveCount: function(){ return saveCount },
      move: movePlaylist, rename: renamePlaylist, del: deletePlaylist,
      clean: cleanPlaylistName
    }
  `)
  return api(seed)
}

// cleanPlaylistName：截断 + 压空白
const e0 = makeEnv([])
ok(e0.clean('') === '', 'cleanPlaylistName 空串 → 空串')
ok(e0.clean('   ') === '', 'cleanPlaylistName 纯空白 → 空串')
ok(e0.clean('  我的  歌单  ') === '我的 歌单', 'cleanPlaylistName 压连续空白 + trim')
ok(e0.clean('a\nb\tc') === 'a b c', 'cleanPlaylistName 换行/制表 → 空格')
const longName = 'x'.repeat(30)
ok(e0.clean(longName).length === 24, 'cleanPlaylistName 超长截断到 24')

// movePlaylist：交换正确 + 边界 no-op + id 不存在
const seed = [
  { id: 'a', name: 'A', type: 'online', songs: [] },
  { id: 'b', name: 'B', type: 'local',  songs: [] },
  { id: 'c', name: 'C', type: 'online', songs: [] }
]
const e1 = makeEnv(seed)
const r1 = e1.move('b', -1)   // b 上移 → [b,a,c]
ok(r1.ok && e1.playlists()[0].id === 'b' && e1.playlists()[1].id === 'a',
   'movePlaylist 上移：b 从第 2 到第 1（交换而非覆盖）')
ok(e1.playlists()[2].id === 'c', 'movePlaylist 上移不碰第三项')

const e2 = makeEnv(seed)
const r2 = e2.move('a', -1)   // 首行再上移 → no-op
ok(r2.ok && e2.playlists()[0].id === 'a', 'movePlaylist 首行上移 = 静默 no-op（ok 但不移位）')

const e3 = makeEnv(seed)
const r3 = e3.move('c', 1)    // 末行再下移 → no-op
ok(r3.ok && e3.playlists()[2].id === 'c', 'movePlaylist 末行下移 = 静默 no-op')

const e4 = makeEnv(seed)
const r4 = e4.move('zzz', 1)
ok(!r4.ok, 'movePlaylist id 不存在 → ok=false')

const e5 = makeEnv(seed)
ok(e5.saveCount() === 0, 'movePlaylist 边界 no-op 不落盘（saveCount 保持 0）')
const e5b = makeEnv(seed)
e5b.move('b', -1)
ok(e5b.saveCount() === 1, 'movePlaylist 真移位时落盘一次')

// renamePlaylist
const e6 = makeEnv(seed)
ok(e6.rename('b', '新名字').ok && e6.playlists()[1].name === '新名字', 'renamePlaylist 改名生效')
const e7 = makeEnv(seed)
ok(!e7.rename('b', '   ').ok, 'renamePlaylist 空名 → ok=false（E_NAME）')
const e8 = makeEnv(seed)
ok(!e8.rename('zzz', 'x').ok, 'renamePlaylist id 不存在 → ok=false')

// deletePlaylist
const e9 = makeEnv(seed)
const r9 = e9.del('b')
ok(r9.ok && e9.playlists().length === 2 && e9.playlists().every(p => p.id !== 'b'),
   'deletePlaylist 删除后数组变短且不含目标')
const e10 = makeEnv(seed)
ok(!e10.del('zzz').ok, 'deletePlaylist id 不存在 → ok=false')

// ============================================================
// B. 接线断言
// ============================================================
console.log('--- B. 重命名接线 ---')

// beginRenamePlaylist：设 plRenameId + editTarget="plRename" + 预填当前名
ok(/function beginRenamePlaylist\(id\)/.test(clean), 'beginRenamePlaylist 存在')
ok(clean.indexOf('beginRenamePlaylist') < clean.indexOf('deletePlaylistUI'),
   'beginRenamePlaylist 定义在 deletePlaylistUI 之前（都是 controller 方法）')

// 抠 beginRenamePlaylist 验证其体内三件套
const beginRen = grab('beginRenamePlaylist')
ok(beginRen.indexOf('plRenameId = id') >= 0, 'beginRenamePlaylist 存 plRenameId = id')
ok(beginRen.indexOf('editTarget = "plRename"') >= 0, 'beginRenamePlaylist 设 editTarget="plRename"')
ok(beginRen.indexOf('keyboard.open(pl.name)') >= 0, 'beginRenamePlaylist 用当前名预填键盘')

// onKeyboardAccepted 的 plRename 分支：真的调 renamePlaylist
const kbdFn = grab('onKeyboardAccepted')
ok(kbdFn.indexOf('plRename') >= 0, 'onKeyboardAccepted 有 plRename 分支')
// 分支体：取 plRenameId → 清空 → 调 renamePlaylist(rid, content)
ok(/plRenameId/.test(kbdFn) && /renamePlaylist\(/.test(kbdFn),
   'plRename 分支调 renamePlaylist')
ok(kbdFn.indexOf('plRenameId = ""') >= 0, 'plRename 分支用后清空 plRenameId')

// deletePlaylistUI / movePlaylistUI 存在且转发到数据层
const delUI = grab('deletePlaylistUI')
ok(delUI.indexOf('deletePlaylist(id)') >= 0, 'deletePlaylistUI 转发到 deletePlaylist')
const movUI = grab('movePlaylistUI')
ok(movUI.indexOf('movePlaylist(id, dir)') >= 0, 'movePlaylistUI 转发到 movePlaylist(id, dir)')

// ============================================================
// C. 页面接线（PlaylistPage.qml）
// ============================================================
console.log('--- C. 页面接线 ---')

ok(/onPressAndHold/.test(pageClean) && /openMenu\(pl, index\)/.test(pageClean),
   'PlaylistPage 长按行 → 调 openMenu(pl, index)')
ok(/function menuAct\(act\)/.test(pageClean), 'PlaylistPage 有 menuAct(act) 分发')
ok(/beginRenamePlaylist\(/.test(pageClean), '菜单「重命名」→ controller.beginRenamePlaylist')
ok(/movePlaylistUI\(menuPl\.id, -1\)/.test(pageClean), '菜单「上移」→ movePlaylistUI(id, -1)')
ok(/movePlaylistUI\(menuPl\.id, 1\)/.test(pageClean), '菜单「下移」→ movePlaylistUI(id, 1)')
ok(/deletePlaylistUI\(menuPl\.id\)/.test(pageClean), '菜单「删除」→ deletePlaylistUI(id)')
ok(/menuConfirmDelete/.test(pageClean), '删除二次确认（menuConfirmDelete）存在')

// 上移/下移边界置灰：首行禁上移、末行禁下移
ok(/menuIndex <= 0/.test(pageClean), '上移在首行（menuIndex<=0）置灰')
ok(/menuIndex >= plPage\.controller\.playlists\.length - 1/.test(pageClean),
   '下移在末行（menuIndex>=len-1）置灰')

console.log('')
console.log('pass=' + pass + '  bad=' + bad)
process.exit(bad ? 1 : 0)
JS
