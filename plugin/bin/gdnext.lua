--[[
gdnext.lua —— GD 音乐的「常驻播放器」内核

为什么是 lua 而不是独立守护进程：
  本机没有 OS 级后台服务（不是 Android）。lua 脚本跑在 mpv 进程内，
  所以「插件页被销毁」完全不影响它 —— mpv 活着，续播就在。
  这也复用了设备既有实践：/userdisk/mpv/config/scripts/bili_heartbeat.lua
  就是同样手法（mp.command_native 调 curl + end-file 事件）。

职责划分：
  QML  = 遥控器 + UI（搜索、歌词、封面、设置）
  lua  = 取流 + 顺序播放 + 播放推进 + 唤醒锁 + 状态上报
  两者靠两个文件通信，无进程间协议解析负担：
    /tmp/gdmusic/queue.json  <- QML 写：队列 / 当前索引 / 音源 / 优选 IP / 是否连播
    /tmp/gdmusic/now.json    -> lua 写：实时状态，QML 轮询读

QML 通过 mpv IPC 发 script-message 下命令：
  gd-load <index>  播队列第 index 首（QML 已写好 queue.json）
  gd-next / gd-prev
  gd-stop          停播 + 释放唤醒锁
  gd-reload        重读 queue.json（设置变了）
  gd-status        立刻刷新一次 now.json

全部路径都在 /tmp（tmpfs），不产生 flash 写入。
--]]

local mp = require 'mp'
local utils = require 'mp.utils'

-- ==================== 常量 ====================
local DIR      = "/tmp/gdmusic"
local QFILE    = DIR .. "/queue.json"
local NFILE    = DIR .. "/now.json"
local LOGFILE  = DIR .. "/lua.log"
local LOCK     = "/tmp/audio_wakelocks/gdmusic.lock"
local API_HOST = "music-api.gdstudio.xyz"
local MAX_IP_TRIES  = 4      -- 取流时最多试几个优选 IP
local MAX_SKIP      = 3      -- 连续取流失败时最多自动跳过几首
local CURL_CONN     = "3"    -- 连接超时
local CURL_MAX      = "8"    -- 总超时

-- ==================== 运行时状态 ====================
local conf       = nil       -- queue.json 的内容
local index      = -1        -- 当前播放的队列下标（1 起）
local switching  = false     -- 正在主动切歌，用于忽略由此产生的 end-file
local loading    = false     -- 正在异步取流（取流期间不要被 end-file 再推进一次）
local load_token = 0         -- 取流请求序号：只有最新一次的返回才生效
local seq        = 0         -- now.json 的递增号，QML 用它判断状态是否新鲜

-- ==================== 小工具 ====================
local function sh(cmd)
    os.execute(cmd .. " 2>/dev/null")
end

local function log(s)
    local f = io.open(LOGFILE, "a")
    if f then
        f:write(os.date("%m-%d %H:%M:%S ") .. s .. "\n")
        f:close()
    end
end

-- 🔴 事件/消息回调的异常保护（定义在这里是为了让下面所有回调都能用到）。
-- mpv 的 lua 脚本**没有全局错误处理**：任何在事件或 script-message 回调里抛出的
-- 异常都会打断整条回调链，之后定时器、file-loaded、script-message **永久全部失效**。
-- 表现：播放器假死（点了没反应、now.json 的 seq 不再增长），
-- 而 lua.log **一行都不会记** —— 错误信息只出现在 mpv 自己的 stderr 里，极难发现。
-- 2026-10-01 实测：仅一个 set_property 传了布尔而非字符串，就让整个播放器冻住。
-- 包一层 pcall 后，"一条命令出错"不会升级成"播放器再也收不到下一条命令"。
local function safe(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            log("!! [" .. name .. "] 回调异常: " .. tostring(err))
        end
    end
end

-- 带保护的注册入口：签名与 mpv 原版一致，所以调用处【只换函数名、闭合不用改】
local function register_evt(name, fn)   mp.register_event(name, safe(name, fn)) end
local function register_msg(name, fn)   mp.register_script_message(name, safe(name, fn)) end
local function add_timer(sec, fn)       mp.add_periodic_timer(sec, safe("timer", fn)) end

local function read_file(p)
    local f = io.open(p, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write_file(p, s)
    local f = io.open(p, "w")
    if not f then return false end
    f:write(s)
    f:close()
    return true
end

local function json_or_nil(s)
    if not s or s == "" then return nil end
    local ok, obj = pcall(utils.parse_json, s)
    if ok and type(obj) == "table" then return obj end
    return nil
end

-- JSON 字符串转义（手写 now.json 用；中文按字节原样输出，QML 的 JSON.parse 能识别）
-- GD API 的 artist 字段在多歌手时是**数组**（如 {"A","B"}）。
-- QML 侧写 ("" + arr) 会被 JS 自动摊平成 "A,B"（UI 再把 "," 换成 " / "），
-- 但 Lua 的 tostring(table) 会得到 "table: 0x17a66750" —— 就是播放页那串地址。
-- 所以这里显式摊平成逗号连接串，与 QML 的隐式转换保持同一约定。
-- 递归一层即可防御嵌套数组；纯对象（无数组段）退化为按 key 序取值，不会丢信息。
local function flat(v)
    if v == nil then return "" end
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    if #v > 0 then
        for i = 1, #v do
            local s = flat(v[i])
            if s ~= "" then parts[#parts + 1] = s end
        end
    else
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local s = flat(v[k])
            if s ~= "" then parts[#parts + 1] = s end
        end
    end
    return table.concat(parts, ",")
end

-- 读取 flag 类 mpv 属性（pause / idle-active …）。
-- ⚠️ mp.get_property() 对这类属性返回的是**字符串** "yes"/"no"（实测 type=string），
--    拿它跟 true 比较永远为假；只有 *_native 才给真正的布尔值。
local function is_flag(name)
    return mp.get_property_native(name) == true
end

local function jstr(v)
    if v == nil then return '""' end
    -- 兜底：任何混进来的 table 都先摊平，避免再漏 "table: 0x..." 到 UI
    local s = (type(v) == "table") and flat(v) or tostring(v)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", " "):gsub("\r", " ")
     :gsub("\t", " "):gsub("[%z\1-\31]", " ")
    return '"' .. s .. '"'
end

local function jnum(v, dflt)
    local n = tonumber(v)
    if n == nil then n = dflt or 0 end
    return string.format("%.3f", n)
end

-- URL 查询串里的值只允许安全字符，避免拼接出畸形请求
local function urlval(v)
    local s = tostring(v or "")
    s = s:gsub("[^%w_%-%.]", "")
    return s
end

-- ==================== 唤醒锁 ====================
-- 协议（见 PenMods src/system/sound/AudioDaemon.cpp）：
--   /tmp/audio_wakelocks/<名字>.lock，内容 = 持有者 PID。
--   没有有效锁时 AudioDaemon 会 closeAudioOutput 把音频设备关掉。
--   用独立名字（不用 VideoPlayer.lock），避免和视频播放互相踩。
local function acquire_lock()
    local p = mp.get_property_number("pid") or 0
    if p > 0 then
        sh("mkdir -p /tmp/audio_wakelocks")
        write_file(LOCK, tostring(p))
    end
end

local function release_lock()
    os.remove(LOCK)
end

-- ==================== 状态上报 ====================
local function write_now(over)
    over = over or {}
    seq = seq + 1
    local song = (conf and conf.list and index >= 1 and conf.list[index]) or {}
    local st = {
        ts       = os.time(),
        seq      = seq,
        index    = over.index or index,
        -- ⚠️ 必须用 get_property_native 取 flag 类属性。
        -- mp.get_property("pause") 返回的是**字符串** "yes"/"no"（实测 type=string），
        -- 永远不等于 true ⇒ 这三个字段会恒为假。后果（真机都发生过）：
        --   pause 恒 false  → UI 一直显示"正在播放"，暂停了也不变；
        --   status 恒 playing → QML 的按钮图标/歌词推进判据全错；
        --   idle   恒 false  → 曾误判为 keep-open=always 独有的问题，
        --                      实际那是第二重原因，两个得一起修才见效。
        status   = over.status or (is_flag("pause") and "paused" or "playing"),
        pos      = mp.get_property_number("time-pos") or 0,
        dur      = mp.get_property_number("duration") or 0,
        pause    = is_flag("pause"),
        idle     = is_flag("idle-active"),
        queueLen = (conf and conf.list and #conf.list) or 0,
        id       = song.id or "",
        name     = song.name or "",
        artist   = song.artist or "",
        reason   = over.reason or "",
        text     = over.text or "",
    }
    local parts = {}
    for _, k in ipairs({"ts","seq","index","pos","dur","queueLen"}) do
        table.insert(parts, jstr(k) .. ":" .. jnum(st[k]))
    end
    for _, k in ipairs({"pause","idle"}) do
        table.insert(parts, jstr(k) .. ":" .. (st[k] and "true" or "false"))
    end
    for _, k in ipairs({"status","id","name","artist","reason","text"}) do
        table.insert(parts, jstr(k) .. ":" .. jstr(st[k]))
    end
    write_file(NFILE, "{" .. table.concat(parts, ",") .. "}")
end

-- ==================== 配置 ====================
local function load_conf()
    local raw = read_file(QFILE)
    local obj = json_or_nil(raw)
    if not obj then
        log("load_conf: queue.json 不存在或不可解析")
        return false
    end
    conf = obj
    log("load_conf: list=" .. tostring(conf.list and #conf.list or 0)
        .. " index=" .. tostring(conf.index)
        .. " source=" .. tostring(conf.source)
        .. " quality=" .. tostring(conf.quality)
        .. " autoNext=" .. tostring(conf.autoNext))
    return true
end

-- ==================== 取流 ====================
-- 走 curl 子进程；不用 os.execute（会阻塞 mpv 主线程且拿不到输出）。
-- 串行尝试若干优选 IP：任意一个返回合法 JSON 就用它。
local function curl_get(url, ip, cb)
    local args = { "curl", "-s", "--connect-timeout", CURL_CONN, "--max-time", CURL_MAX,
                   "-A", "Mozilla/5.0" }
    if ip and ip ~= "" then
        table.insert(args, "--resolve")
        table.insert(args, API_HOST .. ":443:" .. ip)
    end
    table.insert(args, url)
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(ok, res)
        local out = (ok and res and res.stdout) or ""
        cb(out)
    end)
end

local function api_get(qs, cb)
    local base = conf and conf.apiBase
    if base and base ~= "" then
        -- 用户配了自定义中转（例如自建 Cloudflare Worker）：直接用它，不做 IP 优选
        base = base:gsub("/+$", "")
        local sep = base:find("?", 1, true) and "&" or "?"
        curl_get(base .. sep .. qs, nil, cb)
        return
    end
    local ips = {}
    if conf and conf.ips then
        for i = 1, math.min(#conf.ips, MAX_IP_TRIES) do
            ips[#ips + 1] = conf.ips[i]
        end
    end
    ips[#ips + 1] = ""   -- 兜底：交给系统 DNS
    local function try(i)
        if i > #ips then cb("") return end
        curl_get("https://" .. API_HOST .. "/api.php?" .. qs, ips[i], function(out)
            local c = out:sub(1, 1)
            if c == "[" or c == "{" then cb(out) else try(i + 1) end
        end)
    end
    try(1)
end

-- ==================== 播放控制 ====================
local function release_and_stop(reason, text)
    release_lock()
    load_token = load_token + 1   -- 让所有在途的取流请求作废
    loading = false
    switching = true
    mp.commandv("stop")
    switching = false
    -- 必须把 index 归零：否则每秒的定时器会继续 write_now({})，
    -- 而那时 status 取默认值（pause?paused:playing），会把刚写的 "stopped" 覆盖掉，
    -- 于是界面显示"队列已播完"但状态还是"正在播放"。
    index = -1
    write_now({ status = "stopped", reason = reason or "", text = text or "" })
    log("stop: reason=" .. tostring(reason) .. " " .. tostring(text))
end

-- 🔴 加载并【真正开始播放】。
--
-- 必须显式解除暂停：`pause` 是 mpv 的【全局】属性，loadfile **不会重置它**。
-- 一旦播放器停在暂停态（用户按过暂停、或 QML 同步过一次状态），之后每首新歌
-- 都会"加载完但不出声" —— 症状极具迷惑性：
--   · lua.log 一切正常（urled ok / file-loaded 都有，duration 也对）
--   · 缓存一直在涨（看不到头，像在缓冲）
--   · 但 time-pos 恒为 0、界面进度条不动、没有声音
-- 2026-10-01 实测踩到：发一条 set_property pause false 立刻从 -0.079 推进到 4.455。
local function load_and_play(path)
    switching = true
    mp.commandv("loadfile", path)
    -- ⚠️ 必须用 _native：mp.set_property() 只收【字符串】，传布尔会抛
    --    "bad argument #2 to 'set_property' (string expected, got boolean)"。
    --    这个异常发生在事件回调里，会直接打断整条回调链 ⇒ 定时器、file-loaded、
    --    script-message 全部失效，播放器假死（now.json 的 seq 不再增长），
    --    而 lua.log 里【一行记录都没有】，只有 mpv 自己的 stderr 里才有 stack traceback。
    --    （2026-10-01 实测踩到，正是"点了播放没反应"的直接原因。）
    mp.set_property_native("pause", false)
    acquire_lock()
end

-- 播放队列第 i 首；取不到流就按 autoNext 自动顺延（最多 MAX_SKIP 次）
local function play_index(i, skipped)
    if not conf or not conf.list or #conf.list == 0 then
        log("play_index: 队列为空")
        return
    end
    skipped = skipped or 0
    if i < 1 or i > #conf.list then
        -- 队列播完
        release_and_stop("end", "播放结束")
        return
    end
    index = i
    local song = conf.list[i]
    local can_next = (conf.autoNext ~= false) and (skipped < MAX_SKIP)

    -- 并发保护：取流是异步的，用户可能在取流途中又点了下一首。
    -- 每次请求领一个序号，返回时若已不是最新请求就整体丢弃，
    -- 否则两个请求会先后 loadfile，最终播哪首取决于 curl 谁先返回。
    load_token = load_token + 1
    local my_token = load_token
    loading = true

    write_now({ status = "loading", index = i })
    log("play_index: i=" .. i .. " id=" .. tostring(song.id) .. " name=" .. tostring(song.name))

    -- 本地已下载的曲目：直接 loadfile，完全不碰网络。
    -- 这条分支是「离线也能播」的全部实现 —— 队列里的对象只要带 file 字段就走这里，
    -- 所以在线歌和本地歌可以混在同一个队列里依次播。
    local lf = song.file
    if lf and lf ~= "" then
        local fh = io.open(lf, "r")
        if fh then
            fh:close()
            load_and_play(lf)
            log("play_index: 本地文件, path=" .. lf)
            return
        end
        -- index.json 里记录着但文件不在了（被文件管理器删了）→ 按取不到流处理
        log("play_index: 本地文件不存在, path=" .. lf)
        if can_next then
            play_index(i + 1, skipped + 1)
        else
            release_and_stop("fail", "本地文件已丢失")
        end
        return
    end

    local qs = "types=url&source=" .. urlval(conf.source or "netease")
            .. "&id=" .. urlval(song.id)
            .. "&br=" .. urlval(conf.quality or "320")

    api_get(qs, function(raw)
        if my_token ~= load_token then
            log("play_index: i=" .. i .. " 的取流结果已过时（有更新的请求），丢弃")
            return
        end
        loading = false
        local obj = json_or_nil(raw)
        local u = obj and obj.url
        if u and u ~= "" then
            load_and_play(u)
            log("play_index: urled ok, len=" .. #u)
        else
            log("play_index: 第 " .. i .. " 首取不到流" .. (can_next and "，顺延" or "，停止"))
            if can_next then
                play_index(i + 1, skipped + 1)
            else
                release_and_stop("fail", "取不到播放地址")
            end
        end
    end)
end

-- ==================== 事件 ====================
register_evt("file-loaded", function()
    -- 新文件真正加载完成，切歌标志复位
    switching = false
    write_now({ status = "playing" })
    acquire_lock()
    log("file-loaded: index=" .. tostring(index)
        .. " dur=" .. tostring(mp.get_property_number("duration")))
end)

register_evt("end-file", function(e)
    local r = e and e.reason or ""
    log("end-file: reason=" .. r .. " switching=" .. tostring(switching) .. " loading=" .. tostring(loading))
    if switching then
        -- 我们自己 loadfile/stop 引发的，不当作「播完」
        switching = false
        return
    end
    if loading then
        -- 旧歌正好在「已发起下一首取流、但还没换过去」的空档里播完。
        -- 此时推进会让 index 再 +1，白跳一首。
        log("end-file: 正在取流中，忽略本次推进")
        return
    end
    -- 只认 eof（正常播完）与 error（加载/解码失败）；stop/quit 都是主动行为
    if r == "eof" or r == "error" then
        if conf and conf.autoNext ~= false then
            play_index(index + 1)
        else
            release_and_stop("end", "播放结束")
        end
    end
end)

register_evt("shutdown", function()
    release_lock()
    log("shutdown: 已释放唤醒锁")
end)

-- 暂停时也保留唤醒锁：AudioDaemon 一旦判定无人出声就会关掉音频设备，
-- 而暂停后用户随时可能继续，重新打开设备的延迟很直观。
mp.observe_property("pause", "bool", function(_, paused)
    if index >= 1 and conf then
        write_now({ status = paused and "paused" or "playing" })
    end
end)

-- ==================== 遥控通道 ====================
-- 每个回调都用上面的 safe() 包一层（见 log 之后的注释）。
-- 注意：mpv 的 script-message 参数**必须全是字符串**。
-- 我们的 IPC 客户端对纯数字会发成 JSON 数字，mpv 会直接拒收整条命令，
-- 所以这里刻意**不接受数字参数** —— 要播第几首，QML 写进 queue.json 的 index 字段即可。
register_msg("gd-load", function()
    if not load_conf() then return end
    local n = tonumber(conf.index) or 1
    if n < 1 then n = 1 end
    play_index(n)
end)

register_msg("gd-next", function()
    if not conf then load_conf() end
    if conf and index >= 1 then play_index(index + 1) end
end)

register_msg("gd-prev", function()
    if not conf then load_conf() end
    if conf and index >= 1 then play_index(index - 1) end
end)

register_msg("gd-stop", function()
    conf = nil
    index = -1
    release_and_stop("user", "已停止")
end)

register_msg("gd-reload", function()
    load_conf()
end)

register_msg("gd-status", function()
    write_now({})
end)

-- ==================== 周期任务 ====================
-- 每秒刷新一次 now.json（QML 靠它同步进度条/歌词/当前曲目）
add_timer(1, function()
    if index >= 1 and conf then write_now({}) end
end)

-- ==================== 启动 ====================
sh("mkdir -p " .. DIR)
write_file(LOGFILE, "")            -- 每次随 mpv 启动清空日志，防止无限增长
sh("mkdir -p /tmp/audio_wakelocks")
log("=== gdnext loaded, mpv pid=" .. tostring(mp.get_property_number("pid")) .. " ===")
load_conf()
write_now({ status = "idle" })
