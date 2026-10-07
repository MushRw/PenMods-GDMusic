#!/usr/bin/env node
// 从**真实源码**里抠出 MediaBridge 的 reason 消费逻辑求值，验证：
//   1. fail 首次转入时弹一次 toast（默认配置下唯一可见通道）
//   2. 同一失败态持续多拍**不能重复弹**（poll 每秒一拍，否则是骚扰）
//   3. 正常播过再失败 → 能重新弹（连续取流失败是常态，lua MAX_SKIP=3）
//   4. user / end 不弹（用户按停、正常播完不该被报成错误）
//
// 手法与 probe/login.sh 一致：不复制逻辑，从源码读到函数体再求值 ——
// 复制一份逻辑来测等于测了个赝品。
'use strict'
const fs = require('fs')
const path = require('path')

const SRC = process.env.GD_BRIDGE_SRC
  || path.join(__dirname, '..', 'plugin', 'qml', 'MediaBridge.qml')
const src = fs.readFileSync(SRC, 'utf8')

// 抠函数体：从 `function NAME(` 到与之配对的 `}`（括号配对，跳过字符串）
function extractFn(name) {
  const re = new RegExp('^\\s*function ' + name + '\\s*\\(', 'm')
  const m = re.exec(src)
  if (!m) throw new Error('找不到函数 ' + name)
  const start = m.index
  const open = src.indexOf('{', start)
  let depth = 0
  let i = open
  let state = 'code'
  for (; i < src.length; i++) {
    const c = src[i], n = src[i + 1]
    if (state === 'code') {
      if (c === '/' && n === '/') { state = 'line'; i++; continue }
      if (c === "'") { state = 'sq'; continue }
      if (c === '"') { state = 'dq'; continue }
      if (c === '{') depth++
      else if (c === '}') { depth--; if (depth === 0) break }
    } else if (state === 'line') {
      if (c === '\n') state = 'code'
    } else {
      if (c === '\\') { i++; continue }
      if ((state === 'sq' && c === "'") || (state === 'dq' && c === '"')) state = 'code'
    }
  }
  return src.slice(start, i + 1)
}

let pass = 0, bad = 0
function ok(c, label) {
  if (c) { pass++; console.log('  [OK] ' + label) }
  else { bad++; console.log('  [XX] ' + label) }
}

// 模拟桥对象：只有被求值函数真正用到的状态
// 计数挂在 globalRef 上：真实调用是 globalRef.showToast(msg, color)，
// 所以 showToast 里的 this 绑的是 globalRef，不是桥对象。
//
// 🔴 这个假 showToast **刻意校验实参个数**：宿主签名是 C++
//    `showToast(const std::string&, const QColor& theme = "#1A1B1F")`，
//    但 QML 看不见 C++ 默认参数 —— moc 注册的是完整参数表，少传一个会抛
//    "Insufficient arguments"。夹具必须复现这个约束，否则它测不出这类回归。
//    （第一版夹具签名是 `function (m)`，对参数个数毫无意见 ⇒ 真代码只传 1 个
//     它照样全绿。夹具比被测代码宽松，就等于没测。）
function makeBridge() {
  const ref = {
    toastCount: 0, lastToast: '', lastToastColor: '', toasts: [],
    showToast: function (m, color) {
      if (arguments.length < 2)
        throw new Error('Insufficient arguments (expected 2, got ' + arguments.length + ')')
      ref.toastCount++; ref.lastToast = m; ref.lastToastColor = color; ref.toasts.push(m)
    },
  }
  return {
    lastReason: '', lastStopLine: '', pendingStopLine: '', lastStatus: '',
    status: 'not-enabled', globalRef: ref, _ref: ref,
    log: function () {},
  }
}

const fnNames = ['stopText', 'notifyFailure', 'isFailure']
const bodies = fnNames.map(function (n) { return extractFn(n) }).join('\n')

function attach(b) {
  const factory = new Function('bridge', `
    with (bridge) {
      ${bodies}
      return { stopText: stopText, notifyFailure: notifyFailure, isFailure: isFailure }
    }
  `)
  return factory(b)
}

const FAIL_MSG = '\u53d6\u4e0d\u5230\u64ad\u653e\u5730\u5740'   // 取不到播放地址
const LOCAL_MSG = '\u672c\u5730\u6587\u4ef6\u5df2\u4e22\u5931'  // 本地文件已丢失

console.log('=== 1. fail 首次转入 -> 弹一次 ===')
{
  const b = makeBridge()
  const f = attach(b)
  const txt = f.stopText({ status: 'stopped', reason: 'fail', text: FAIL_MSG })
  ok(txt === FAIL_MSG, 'stopText 返回 lua 给的文案，实测：' + txt)
  ok(b._ref.toastCount === 1, 'toast 弹了 1 次，实测：' + b._ref.toastCount)
  ok(b._ref.lastToastColor === '#E5605C',
     'toast 带上了颜色实参（QML 看不见 C++ 默认参数，少传会抛 Insufficient arguments），实测：' + b._ref.lastToastColor)
  ok(b.lastStopLine === FAIL_MSG, 'lastStopLine 记下原因（供保留期显示）')
  ok(f.isFailure() === true, 'isFailure() 为真')
}

console.log('=== 2. 同一失败态持续多拍 -> 不重复弹（关键：poll 每秒一拍）===')
{
  const b = makeBridge()
  const f = attach(b)
  for (let i = 0; i < 10; i++) f.stopText({ status: 'stopped', reason: 'fail', text: FAIL_MSG })
  ok(b._ref.toastCount === 1, '连跑 10 拍只弹 1 次，实测：' + b._ref.toastCount)
}

console.log('=== 3. 正常播过再失败 -> 重新弹（连续跳过是常态）===')
{
  const b = makeBridge()
  const f = attach(b)
  f.stopText({ status: 'stopped', reason: 'fail', text: FAIL_MSG })
  // 模拟 onNow 分③「真的在放了」时清空（真实代码就在那里清）
  b.lastReason = ''
  b.lastStopLine = ''
  b.pendingStopLine = ''
  f.stopText({ status: 'stopped', reason: 'fail', text: FAIL_MSG })
  ok(b._ref.toastCount === 2, '第二首失败仍会弹，实测：' + b._ref.toastCount)
}

console.log('=== 4. user / end 不弹（不能把正常行为报成错误）===')
{
  const b = makeBridge()
  const f = attach(b)
  const u = f.stopText({ status: 'stopped', reason: 'user', text: '\u5df2\u505c\u6b62' })
  ok(u === '\u5df2\u505c\u6b62', 'user -> 已停止，实测：' + u)
  ok(b._ref.toastCount === 0, 'user 不弹 toast，实测：' + b._ref.toastCount)
  ok(b.lastStopLine === '', 'user 不写 lastStopLine（不该以错误口吻留在卡片上）')

  const b2 = makeBridge()
  const f2 = attach(b2)
  const e = f2.stopText({ status: 'stopped', reason: 'end', text: '\u64ad\u653e\u7ed3\u675f' })
  ok(e === '\u64ad\u653e\u7ed3\u675f', 'end -> 播放结束，实测：' + e)
  ok(b2._ref.toastCount === 0, 'end 不弹 toast，实测：' + b2._ref.toastCount)
}

console.log('=== 5. 本地文件丢失（同为 fail，文案不同）===')
{
  const b = makeBridge()
  const f = attach(b)
  const t = f.stopText({ status: 'stopped', reason: 'fail', text: LOCAL_MSG })
  ok(t === LOCAL_MSG, '沿用 lua 文案，实测：' + t)
  ok(b._ref.toastCount === 1, '也会弹 toast，实测：' + b._ref.toastCount)
}

console.log('=== 6. 无 reason（旧版 now.json）-> 不误报为失败 ===')
{
  const b = makeBridge()
  const f = attach(b)
  const t = f.stopText({ status: 'stopped' })
  ok(t === '\u672a\u5728\u64ad\u653e', '无 reason -> 未在播放，实测：' + t)
  ok(b._ref.toastCount === 0, '无 reason 不弹，实测：' + b._ref.toastCount)
  ok(f.isFailure() === false, 'isFailure() 为假')
}

console.log('=== 7. globalRef 缺失 -> 静默降级，不抛异常（宿主重启后未开过插件页）===')
{
  const b = makeBridge()
  b.globalRef = null
  const f = attach(b)
  let threw = null
  try { f.stopText({ status: 'stopped', reason: 'fail', text: FAIL_MSG }) }
  catch (e) { threw = e }
  ok(threw === null, 'globalRef 为 null 时不抛异常' + (threw ? '：' + threw : ''))
}

console.log('=== 8. showToast 自身抛异常 -> 不影响播放控制 ===')
{
  const b = makeBridge()
  b.globalRef = { showToast: function () { throw new Error('host API changed') } }
  const f = attach(b)
  let threw = null
  let txt = null
  try { txt = f.stopText({ status: 'stopped', reason: 'fail', text: FAIL_MSG }) }
  catch (e) { threw = e }
  ok(threw === null, 'showToast 抛异常时被 try/catch 兜住' + (threw ? '：' + threw : ''))
  ok(txt === FAIL_MSG, 'stopText 仍正常返回文案，实测：' + txt)
}

console.log('')
if (bad > 0) { console.log('  ' + pass + ' 项通过, bad=' + bad); process.exit(1) }
console.log('  ' + pass + ' 项通过')
