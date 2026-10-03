-- 最小探针：验证设备上 mpv lua 的能力边界（读文件/parse_json/subprocess curl/写文件/取pid/script-message）
-- 结论全部落到 /tmp/gdmusic/lua.log（不依赖 mpv 的 msg-level），便于 tail
local mp = require 'mp'
local utils = require 'mp.utils'

local DIR = "/tmp/gdmusic"
local LOG = DIR .. "/lua.log"

local function log(s)
    local f = io.open(LOG, "a")
    if f then f:write(os.date("%H:%M:%S ") .. s .. "\n"); f:close() end
end

os.execute("mkdir -p " .. DIR)
log("=== probe start ===")

-- 1. 版本 / pid / mpv 版本
log("1. lua os.clock OK; mpv version = " .. tostring(mp.get_property("mpv-version")))
log("1b. utils.getpid = " .. tostring(utils.getpid and utils.getpid() or "无此函数"))
log("1c. mp pid prop = " .. tostring(mp.get_property_number("pid")))

-- 2. 读文件 + parse_json
local f = io.open(DIR .. "/in.json", "r")
if f then
    local raw = f:read("*a"); f:close()
    log("2. 读到 in.json 长度=" .. #raw)
    local ok, obj = pcall(utils.parse_json, raw)
    if ok and obj then
        log("2b. parse_json OK: list=" .. tostring(obj.list and #obj.list or "nil")
            .. " index=" .. tostring(obj.index) .. " source=" .. tostring(obj.source))
    else
        log("2b. parse_json FAIL: " .. tostring(obj))
    end
else
    log("2. in.json 不存在（跳过）")
end

-- 3. subprocess 调 curl（异步），结果写文件
local function test_curl()
    log("3. 发起 curl ...")
    local cmd = {
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = { "curl", "-s", "--max-time", "8", "-A", "Mozilla/5.0",
                 "--resolve", "music-api.gdstudio.xyz:443:104.18.0.1",
                 "https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=5257138&br=320" }
    }
    mp.command_native_async(cmd, function(success, result, err)
        if not success then
            log("3b. curl FAIL err=" .. tostring(err))
            return
        end
        local out = result and result.stdout or ""
        log("3b. curl status=" .. tostring(result.status) .. " 输出长度=" .. #out)
        local ok, obj = pcall(utils.parse_json, out)
        if ok and obj then
            log("3c. 解析出 url = " .. tostring(obj.url):sub(1, 70))
            log("3d. 解析出 name = " .. tostring(obj.name) .. " / " .. tostring(obj.artist))
        else
            log("3c. 解析失败: " .. tostring(obj) .. " 原文头部=" .. out:sub(1, 120))
        end
    end)
end

-- 4. 写文件（唤醒锁样式）
local function test_write()
    local lf = io.open("/tmp/audio_wakelocks/probe.lock", "w")
    if lf then lf:write(tostring(mp.get_property_number("pid") or 0)); lf:close()
        log("4. 写锁文件 OK -> /tmp/audio_wakelocks/probe.lock")
    else
        log("4. 写锁文件 FAIL")
    end
    os.remove("/tmp/audio_wakelocks/probe.lock")
    log("4b. 删锁文件 OK")
end

-- 5. script-message（QML 遥控通路）
mp.register_script_message("gd-probe", function(a, b)
    log("5. 收到 script-message gd-probe args=" .. tostring(a) .. "," .. tostring(b))
    local nf = io.open(DIR .. "/probe_reply.txt", "w")
    if nf then nf:write("got:" .. tostring(a)); nf:close() end
end)

-- 6. 事件
mp.register_event("file-loaded", function()
    log("6. file-loaded 触发, path=" .. tostring(mp.get_property("path")))
end)
mp.register_event("end-file", function(e)
    log("6b. end-file 触发 reason=" .. tostring(e and e.reason) .. " (eof=正常播完)")
end)

-- 7. 定时器
local n = 0
local t = mp.add_periodic_timer(2, function()
    n = n + 1
    log("7. tick#" .. n .. " pause=" .. tostring(mp.get_property("pause"))
        .. " idle=" .. tostring(mp.get_property("idle-active"))
        .. " pos=" .. tostring(mp.get_property_number("time-pos")))
    if n == 1 then test_curl() end
    if n == 3 then test_write() end
    if n >= 6 then t:kill(); log("7b. 探针结束") end
end)

log("=== probe ready ===")
