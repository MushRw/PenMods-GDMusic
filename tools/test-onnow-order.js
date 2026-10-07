#!/usr/bin/env node
// 钉住 onNow 的**分支顺序**与坏读容忍语义。
//
// 为什么需要这个测试：2026-10-07 加坏读容忍时，第一版把容忍写在分支①
// （「播放器已死」回收）**之前**，于是造出一个新 bug：
//   「now.json 读不到 **且** mpv 已死」⇒ 两个判据都够不到 ⇒ owns 永不释放。
// 这类错误的特征是**读代码很难看出来**（两段代码各自都对），只有把
// 「顺序」本身当成断言对象才能钉住。
//
// 手法：从 MediaBridge.qml **真源码**抽出 onNow 的函数体，按行号顺序
// 定位各分支，断言它们的相对次序；再按真实取值求值，验证行为。
'use strict'
const fs = require('fs')
const path = require('path')

const SRC = process.env.GD_BRIDGE_SRC
  || path.join(__dirname, '..', 'plugin', 'qml', 'MediaBridge.qml')
const src = fs.readFileSync(SRC, 'utf8')

function extractFn(name) {
  const re = new RegExp('^\\s*function ' + name + '\\s*\\(', 'm')
  const m = re.exec(src)
  if (!m) throw new Error('找不到 ' + name)
  const open = src.indexOf('{', m.index)
  let d = 0, i = open, st = 'code', prev = ''
  const rx = (c) => c === '' || '(,=:[!&|?{};+-*%<>~^'.indexOf(c) >= 0
  for (; i < src.length; i++) {
    const c = src[i], n = src[i + 1]
    if (st === 'code') {
      if (c === '\n') continue
      if (c === '/' && n === '/') { st = 'lc'; i++; continue }
      if (c === '/' && n === '*') { st = 'bc'; i++; continue }
      if (c === "'") { st = 'sq'; continue }
      if (c === '"') { st = 'dq'; continue }
      if (c === '/' && rx(prev)) {
        let j = i + 1, inC = false
        for (; j < src.length; j++) { const dd = src[j]
          if (dd === '\\') { j++; continue }
          if (dd === '\n') break
          if (dd === '[') inC = true; else if (dd === ']') inC = false
          else if (dd === '/' && !inC) break }
        i = j; prev = 'x'; continue
      }
      if (c === '{') d++; else if (c === '}') { d--; if (d === 0) break }
      if (!/\s/.test(c)) prev = c
      continue
    }
    if (st === 'lc') { if (c === '\n') st = 'code'; continue }
    if (st === 'bc') { if (c === '*' && n === '/') { st = 'code'; i++ }; continue }
    if (c === '\\') { i++; continue }
    if ((st === 'sq' && c === "'") || (st === 'dq' && c === '"')) { st = 'code'; prev = c }
  }
  return src.slice(m.index, i + 1)
}

const onNow = extractFn('onNow')
// 用函数体内的**行号**（相对整个文件）定位各分支
const baseLine = src.slice(0, src.indexOf(onNow)).split('\n').length
const bodyLines = onNow.split('\n')

function findLine(re) {
  for (let i = 0; i < bodyLines.length; i++) if (re.test(bodyLines[i])) return baseLine + i
  return -1
}

const L_branch1 = findLine(/if \(owns && !mpvAlive && !holdTimer\.running\)/)
const L_readTol = findLine(/if \(readOk === false\)/)
const L_branch2 = findLine(/if \(!o \|\| st === "" \|\| st === "stopped" \|\| st === "idle"\)/)
const L_resetBad = findLine(/^\s*badReads = 0\s*$/)

let pass = 0, bad = 0
const ok = (c, label) => { if (c) { pass++; console.log('  [OK] ' + label) } else { bad++; console.log('  [XX] ' + label) } }

console.log('=== 1. 分支存在性（行号取自真源码）===')
ok(L_branch1 > 0, '分支①「播放器已退出」存在  @' + L_branch1)
ok(L_readTol > 0, '坏读容忍 readOk===false 存在  @' + L_readTol)
ok(L_branch2 > 0, '分支②「没在放」存在  @' + L_branch2)
ok(L_resetBad > 0, 'badReads 复位存在  @' + L_resetBad)

console.log('')
console.log('=== 2. 🔴 顺序断言：分支① 必须在坏读容忍**之前** ===')
console.log(`  实测顺序：分支① @${L_branch1}  →  坏读容忍 @${L_readTol}  →  分支② @${L_branch2}`)
ok(L_branch1 < L_readTol,
   '分支① 早于坏读容忍（否则「now.json 读不到 + mpv 已死」会漏回收）')
ok(L_readTol < L_branch2,
   '坏读容忍早于分支②（否则坏读会被当成「没在放」而 release+killMpv）')
ok(L_resetBad > L_readTol,
   'badReads=0 在容忍判断之后（即"读到好数据才复位"）')

console.log('')
console.log('=== 3. 按真实取值求值：四种场景 ===')
// 复刻真实控制流（顺序与源码一致）
function simulate(env) {
  const acts = []
  if (!env.session) { acts.push('status=宿主无 mediaSession'); return acts }
  if (env.owns && !env.mpvAlive && !env.holdTimerRunning) { acts.push('release(播放器已退出)'); return acts }
  if (env.readOk === false) { acts.push('badReads++/return(沿用上一拍)'); return acts }
  const o = env.o
  const st = o ? String(o.status || '') : ''
  if (!o || st === '' || st === 'stopped' || st === 'idle') {
    acts.push('holdSession(' + (env.holdOnStop ? '保留期' : 'release+killMpv') + ')')
    return acts
  }
  acts.push('cancelHold/playing')
  return acts
}

const cases = [
  ['① 正在放 + 读到坏数据（P1 的主场景）',
   { session: {}, owns: true, mpvAlive: true, holdTimerRunning: false, readOk: false, o: null, holdOnStop: false },
   ['badReads++/return(沿用上一拍)'],
   '不 release、不 killMpv —— 歌继续放'],
  ['② now.json 读不到 **且** mpv 已死（我第一版引入的回归）',
   { session: {}, owns: true, mpvAlive: false, holdTimerRunning: false, readOk: false, o: null, holdOnStop: false },
   ['release(播放器已退出)'],
   '必须回收会话（分支① 优先于坏读容忍）'],
  ['③ 正常停播（stopped，默认配置）',
   { session: {}, owns: true, mpvAlive: true, holdTimerRunning: false, readOk: true,
     o: { status: 'stopped', reason: 'user' }, holdOnStop: false },
   ['holdSession(release+killMpv)'],
   '停播照旧走 holdSession'],
  ['④ 保留期里 socket 不在（预期状态）',
   { session: {}, owns: true, mpvAlive: false, holdTimerRunning: true, readOk: false, o: null, holdOnStop: true },
   ['badReads++/return(沿用上一拍)'],
   'holdTimer.running ⇒ 分支① 不触发，正确（保留期里 socket 不在是预期）'],
]

for (const [label, env, want, note] of cases) {
  const got = simulate(env)
  const same = JSON.stringify(got) === JSON.stringify(want)
  ok(same, label + '  ⇒ ' + got.join(',') + '   [' + note + ']')
  if (!same) console.log('       期望: ' + want.join(','))
}

console.log('')
if (bad) { console.log('  ' + pass + ' 项通过, bad=' + bad); process.exit(1) }
console.log('  ' + pass + ' 项通过')
