-- HD2-Addon: mods/hd2/navigation_stratagem_ball
--
-- Navigation Stratagem Ball v0.0.1 —— **只读侦察版**，只回答三件事（用户指定，不做别的）：
--   ① 从玩家的**按键配置文件**里找出「射击键」，连同临时追踪的 **Ctrl / Q** 一起，
--      把这三个键的按下/松开写进日志；
--   ② 分清**本机玩家**与联机玩家，抓本机玩家的**战备球**与**标记（ping）**；
--   ③ 记录战备球的**创建 / 销毁**，以及「**激活 / 未激活**」状态的候选信号。
--
-- 方法来源：上一个 MOD `mods/hd2/stratagem_ping_probe`（已弃用，思路保留）。
--   * 内存偏移来自 HD2 HUD+ 0.1.12 钉死的那一版构建 —— 启动时把 game.exe / game.dll 的
--     模块基址写进 census（**0.0.1 还不记 SHA-256 指纹**，游戏更新后如果读不到结构，
--     日志里会出现 no-xxx / layout 这类原因，而不是静默失效）；
--   * 玩家 / 标点表 / 投出物注册表 / Wieldable+Throwable 组件的形状照抄那一份，
--     但这份是**新写的、只留上面三件事**，没有锁定/冻结/写入/HUD 那一整套。
--   * 不写一个字节：所有读取都包 pcall，任何一项不确定就只写日志。
local MOD = {
    key = 'NavigationStratagemBall001',
    revision = 'v1.0.0',
}
local NAMES = {
    main = 'NavigationStratagemBall.log',
    status = 'NavigationStratagemBall_STATUS.log',
    census = 'NavigationStratagemBall_census.log',
    hex = 'NavigationStratagemBall_original_hex.log',
}

-- ── HUD 开关（切片 5）────────────────────────────────────────────────
-- Arsenal 选项替换的就是这一行（`HUD on (default)` = 1 / `HUD off` = 0）。
-- 关掉只是"什么都不画"，判定逻辑一行都不受影响。
local HUD_ENABLED = 1
-- 游戏自带的调试字体：给的是**资源名**，不是内存里的字体句柄（0.19.x 那次"进任务直接崩"
-- 就是从 game.dll 固定偏移读字体/材质句柄读坏的）。
local HUD_FONT = 'core/performance_hud/debug'

if rawget(_G, MOD.key) then return rawget(_G, MOD.key) end

local ffi = require('ffi')
pcall(ffi.cdef, [[
    typedef unsigned char nsb_u8;
    typedef unsigned short nsb_u16;
    typedef unsigned int nsb_u32;
    typedef unsigned long long nsb_u64;
    void *GetModuleHandleA(const char *name);
    void *GetCurrentProcess(void);
    int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read);
    int WriteProcessMemory(void *process, void *address, const void *buffer, size_t size, size_t *written);
    nsb_u64 GetTickCount64(void);
    short GetAsyncKeyState(int vkey);
    nsb_u32 GetModuleFileNameW(void *module, nsb_u16 *name, nsb_u32 size);
    nsb_u32 GetEnvironmentVariableW(const nsb_u16 *name, nsb_u16 *value, nsb_u32 size);
    int RegGetValueW(void *root, const nsb_u16 *subkey, const nsb_u16 *value, nsb_u32 flags,
                     nsb_u32 *type, void *data, nsb_u32 *size);
    void *CreateFileW(const nsb_u16 *name, nsb_u32 access, nsb_u32 share, void *sa,
                      nsb_u32 disposition, nsb_u32 flags, void *template);
    int ReadFile(void *file, void *buffer, nsb_u32 size, nsb_u32 *read, void *overlapped);
    int CloseHandle(void *handle);
    void *FindFirstFileW(const nsb_u16 *pattern, void *data);
    int FindNextFileW(void *handle, void *data);
    int FindClose(void *handle);
]])

-- ── 常量：游戏更新后要重新反推的就是这一块 ───────────────────────────
-- RVA 出处见 work\docs\11-战备球落在标点处-可行性调研.md 第 2 节。
local RVA = {
    player_manager = 0x3326468,   -- 玩家管理器
    mission_mode = 0x33266A0,     -- 任务模式（+8 生效位）
    avatar_manager = 0x3326D20,   -- 角色管理器（面板字节在里面）
    camera = 0x346D560,           -- 相机（+0x3C 是 XYZ）
    comms = 0x347CE30,            -- 标点（ping）环形表
    throwable_reg = 0x33264C0,    -- ThrowableComponent 注册表
    stratagem_slots = 0x347CE50,  -- **玩家记录数组**的指针（每个玩家一条 0x1690 的记录）
    self_ctx = 0x347CEF0,         -- 输入/会话上下文（+0xB398 处是本机 peer id，8 字节）
    now_obj = 0x3326348,          -- 全局计时对象（槽里 remain / elapsed 用它换算秒）
}
local EXE_RVA = {
    unit_registry = 0x1A100F0,    -- 单位注册表（unit id -> 对象）
    unit_vtable = 0x2BD870,       -- 布局自检
}
local OFF = {
    player_count = 0x84,
    player_available = 0x88,
    player_entity = 0xE8,
    player_unit = 0x3A8,          -- 本机 unit id
    mode_active = 8,
    mode_value = 0x40,
    entity_stride = 24,
    entity_id = 8,
    entity_unit = 12,
    entity_goid = 16,
    entity_owned = 20,
    map_capacity = 8,
    map_empty = 12,
    throwable_map = 48,
    throwable_backref = 72,
    throwable_rows = 80,
    throwable_stride = 120,
    throwable_fuse_pick = 112,
    throwable_fuse_count = 116,
    unit_registry_objects = 0x88,
    unit_registry_count = 0x98,
    unit_registry_generations = 0xA0,
    unit_node = 0x88,
    unit_node_pos = 0x30,
    ping_head = 8,
    ping_tail = 12,
    ping_entries = 16,
    ping_stride = 88,
    ping_slots = 128,
    ping_kind = 0,
    ping_x = 4, ping_y = 8, ping_z = 12,
    ping_lifetime = 16,
    ping_elapsed = 20,
    ping_owner = 24,
    ping_picture = 56,
    camera_pos = 0x3C,
}
-- 战备槽结构里的偏移（游戏自己的「正在启动 / 冷却 / 是否携带」，状态栏追踪用）
-- 玩家记录数组 / 每条玩家记录 / 记录里的战备槽（照 StratagemList HUD 的读法，见 docs\17 §7）
local REC_STRIDE, REC_CNT_OFF, REC_MAX = 0x1690, 0x2D200, 32
local SELF_PEER_OFF = 0xB398
local REC_SLOT_OFF, REC_SLOT_STRIDE, REC_SLOTCNT_OFF, REC_MAX_SLOTS = 0x1C0, 0x30, 0x7C0, 32
local BEACON_KIND = 20            -- 实测：刚投出的信标标记（life 9999）
local STRATAGEM_BALL_HASH = '16F397CA5F51F271'    -- 「Stratagem Ball」单位资源哈希
local STRATAGEM_BALL_LE = '71F2515FCA97F316'      -- 内存里的写法（小端）

local FRAME_START = 120           -- 等游戏把启动流程走完
local SLOW_POLL = 6               -- 结构巡检间隔（帧）
-- 0.1.8（用户定）：**只给标点表**单独一个更快的节拍 —— 标点的发现延迟从 ≤6 帧降到 ≤3 帧
-- （移动目标的目标点跟得更紧、"球创建之后才算新标点"的边界更细）。
-- 实测开销：标点表一次 11,264 B，6→3 帧只是 +1.9 KB/帧、Lua 侧 +3.5 µs/帧（可忽略）；
-- 其它巡检（状态栏槽表 / 本机玩家 / 球位置）**保持 6 帧不变**。
local PING_EVERY = 3              -- 标点表巡检间隔（帧）
local FLUSH_EVERY = 120           -- census 落盘间隔
local CENSUS_MAX = 96000
local NOTE_SUPPRESS = 300         -- 同一条 note 的抑制窗口（帧）
local READ_MAX = 65536
local OWNER_MATCH_MAX = 5.0       -- 信标标记与自己的球差多少米内才认 owner
local MARK_WINDOW_SEC = 3.0       -- 「标点后 3 秒内丢出」的窗口（用户定；按 dt 累加真实秒）
local PING_LOG_EVERY = 30         -- 同一条标点在动时，最多多少帧记一次「标点更新」
-- 0.1.16（用户定）：**"延迟"这套代码整个删掉** —— 一"松开射击键"（= 投出）就开传送。
-- 沿革：0.1.7 起是"松开 + 30 帧"，0.1.13 压到 0 帧（延迟变成空操作），0.1.16 把
-- `DEPLOY_DELAY_FRAMES` / `track.deploy_frame` / "延迟结束"日志一起删干净（不再留死代码）。
-- 为什么越早越好：攻击类（红色）打击落点在球**第一次触地**那一刻就被游戏记死
-- （`work\docs\11` §10.30/§10.31），写入越早越可能赶在触地之前把球按住。
-- 0.1.14（用户定）：**握持期预扫** —— 球一创建（还在手里）就开始扫，每 PRESCAN_EVERY 帧刷一次；
--   松手那一刻直接用这份偏移开写（0.1.13 有 3 次是"松手那一帧现扫扫到 0 处"⇒ 3 秒空转 cancel）。
-- 0.1.15（用户选 B）：**预扫缓存必须在松手时被证伪**，否则宁可不写、退回现扫：
--   * `PRESCAN_SCAN_SPAN`：预扫只扫 node ±8 KB（我们每局 `_original_hex.log` 里副本都落在
--     node +0x30~+0x7F0 那张 64 字节步长的表里）⇒ 把"扫到别人字段"的面积缩小 32 倍；
--   * `PRESCAN_VERIFY_MAX`：松手时逐条复核 —— 读一次，值必须还落在"球当前位置 1 米内"
--     （球自己的位置副本必然满足；被换过 node / 被复用的字段会被剔掉）。一条不剩就整份作废。
--   ⚠️ 这几个常量**必须声明在所有用到它们的函数之前**（0.1.12 的 `PROBE_ENABLED` 就是声明晚了，
--      函数里读到全局 nil，把整条传送卡死过一次）。
local PRESCAN_EVERY = 10              -- 握持期预扫间隔（帧）
local PRESCAN_SCAN_SPAN = 0x2000      -- 预扫窗口：node ±8 KB
local PRESCAN_VERIFY_MAX = 1.0        -- 松手复核：值离球当前位置这么近才算"仍是球的位置副本"

local state = {
    frames = 0, errors = 0, phase = 'wait', notes = {}, census = {}, census_bytes = 0,
    census_dirty = false, last_flush = 0, written_status = nil, started = false,
    player = {}, me = {}, my_owner = nil, solo = nil,
    balls = {}, ball_seen = {}, last = nil, key = {}, bindings = {}, fire = nil,
    key_log = {}, key_prev = nil, ping_sig = {}, ping_log_at = {}, ping_first = {},
    mark_skip = {}, mark_log_at = nil,
    strat = {}, strat_sig = {}, local_rec = nil, local_meta = nil,
    strat_shape = nil,
    seconds = 0, throw_reg = nil, throw_slots = nil, throw_why = nil,
    -- 0.1.0 状态机（切片 1+2：球逐帧判 + 标点跟踪 + 3 秒窗口；射击键/HUD/传送在后面的切片）
    track = { active = false, ball = nil, ball_frame = nil, mark = nil, mark_started = nil,
              window_left = 0, expired = false, frozen = false, watch = false, marks = 0 },
    counts = { balls = 0, created = 0, destroyed = 0, pings = 0, keys = 0, steps = 0 },
    scan_count = 0,
}

-- HUD 的表（切片 5）：**必须在这里先声明** —— `write_status` 在下面就要读它，
-- 声明晚了那个引用会变成"全局查找"，加载期第一次写 STATUS 就会 `index a nil value`。
local hud

-- ── 小工具 ───────────────────────────────────────────────────────────
local function u32(bytes, at)
    if not bytes or #bytes < at + 4 then return nil end
    local b1, b2, b3, b4 = bytes:byte(at + 1), bytes:byte(at + 2), bytes:byte(at + 3), bytes:byte(at + 4)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end
local function u64(bytes, at)
    local low, high = u32(bytes, at), u32(bytes, at + 4)
    if not low or not high then return nil end
    return low + high * 4294967296
end
local function f32(bytes, at)
    if not bytes or #bytes < at + 4 then return nil end
    local raw = bytes:sub(at + 1, at + 4)
    local value = ffi.new('float[1]')
    ffi.copy(value, raw, 4)
    local number = tonumber(value[0])
    if number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end
local function hexbytes(text)
    if not text then return '(nil)' end
    return (text:gsub('.', function(one) return string.format('%02X', one:byte()) end))
end
local function hexbytes_of(bytes, at, count)
    if not bytes then return nil end
    local part = bytes:sub(at + 1, at + count)
    if #part < count then return nil end
    return hexbytes(part)
end
local function xyz_text(xyz)
    if not xyz then return '(none)' end
    return string.format('%.3f,%.3f,%.3f', xyz[1], xyz[2], xyz[3])
end
local function distance3(a, b)
    if not a or not b or not a[1] or not b[1] then return math.huge end
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
local function wide_string(text)
    local out = ffi.new('nsb_u16[?]', #text + 1)
    for index = 1, #text do out[index - 1] = text:byte(index) end
    out[#text] = 0
    return out
end
local function wide_to_utf8(pointer, count)
    local parts = {}
    for index = 0, count - 1 do
        local code = pointer[index]
        if code == 0 then break end
        parts[#parts + 1] = string.char(code % 256)
    end
    return table.concat(parts)
end

-- ── 日志 ─────────────────────────────────────────────────────────────
local loader = rawget(_G, 'CowboyBingusModLoader')
local api_ok = type(loader) == 'table' and type(loader.api) == 'number' and loader.api >= 1
    and type(loader.open_log) == 'function'
local function open_log(name)
    if not api_ok then return nil end
    local ok, file = pcall(loader.open_log, name)
    if ok and file then return file end
    return nil
end
local log = open_log(NAMES.main)
local status_log = open_log(NAMES.status)
local census_log = open_log(NAMES.census)
local hex_log = open_log(NAMES.hex)

local function note(message, force)
    local text = tostring(message)
    local at = state.notes[text]
    if not force and at and (state.frames - at) < NOTE_SUPPRESS then return end
    state.notes[text] = state.frames
    local line = string.format('%s [frame %d] %s', MOD.revision, state.frames, text)
    if log then pcall(function() log:write(line .. '\n') end) end
    print('[NSB] ' .. line)
end
local function census_add(text)
    if state.census_bytes >= CENSUS_MAX then return end
    text = tostring(text)
    state.census[#state.census + 1] = text
    state.census_bytes = state.census_bytes + #text
    state.census_dirty = true
end
-- 改动前落盘证据（AGENTS 的规矩）：传送要写的每个地址，第一次写之前把**原字节**存下来
local HEX_MAX_LINES = 4000
local function hex_snapshot(address, bytes)
    if not hex_log then return end
    state.hex_lines = (state.hex_lines or 0) + 1
    if state.hex_lines > HEX_MAX_LINES then return end
    pcall(function()
        hex_log:write(string.format('%s [frame %d] addr=0x%X original=%s\n', MOD.revision,
            state.frames, address, hexbytes(bytes)))
        if state.hex_lines % 64 == 0 then hex_log:flush() end
    end)
end
local function flush_logs()
    if log then pcall(function() log:flush() end) end
    if state.census_dirty and census_log then
        state.census_dirty = false
        local text = table.concat(state.census, '\n')
        state.census = {}
        pcall(function() census_log:write(text .. '\n'); census_log:flush() end)
    end
end
local function write_status(conclusion)
    if not status_log or state.written_status == conclusion then return end
    state.written_status = conclusion
    local tail = string.format(
        'revision=%s\nphase=%s\nread_only=no（**只在传送那一段**写"球位置的副本"；其余全只读）\n'
        .. 'shots=%d frames=%d\nballs_created=%d balls_destroyed=%d live_balls=%d\n'
        .. 'pings_seen=%d\nfire_key=%s\n'
        .. 'tracker=%s phase=%s watch=%s mark=%s window_left=%.1f step_lines=%d\n'
        .. 'hud=%s drawn=%d gui=%s errors=%d\n'
        .. 'teleport_written=%d teleport_hex_lines=%d\n'
        .. 'local_player=%s my_owner=%s\nbindings_from_config=%d\nerrors=%d\n',
        MOD.revision, state.phase,
        state.phase == 'stopped' and 1 or 0, state.frames,
        state.counts.created, state.counts.destroyed, state.counts.balls, state.counts.pings,
        state.fire and (state.fire.name .. ' vk 0x' .. string.format('%02X', state.fire.vk))
            or '(没找到)',
        state.track.active and 'active' or 'idle',
        state.track.phase or 'idle',
        state.track.watch and 'yes' or 'no',
        state.track.mark and xyz_text(state.track.mark) or '(none)',
        state.track.window_left, state.counts.steps,
        (hud and hud.on) and ((hud.disabled and 'stopped') or 'on') or 'off',
        (hud and hud.drawn) or 0, (hud and hud.gui) and 'yes' or 'no',
        (hud and hud.errors) or 0,
        state.teleport_written or 0, state.hex_lines or 0,
        state.me.entity and string.format('entity=0x%X unit=%s', state.me.entity,
            tostring(state.me.unit)) or '(还没有)',
        tostring(state.my_owner), #state.bindings, state.errors)
    pcall(function() status_log:write(conclusion .. '\n' .. tail); status_log:flush() end)
end

-- ── 绑定 kernel32 / user32 ───────────────────────────────────────────
local api = { game = 0, exe = 0 }
local kernel, user32
local function bind()
    if api.ok then return true end
    local ok, result = pcall(function()
        kernel = ffi.load('kernel32')
        user32 = ffi.load('user32')
        local process = kernel.GetCurrentProcess()
        local game = kernel.GetModuleHandleA('game.dll')
        local exe = kernel.GetModuleHandleA(nil)
        if game == nil or exe == nil then return nil, 'no-module' end
        local bound = { ok = true, process = process, game = tonumber(ffi.cast('uintptr_t', game)),
                        exe = tonumber(ffi.cast('uintptr_t', exe)) }
        bound.read = function(address, size)
            if not address or address == 0 or size <= 0 or size > READ_MAX then return nil end
            local buffer, received = ffi.new('nsb_u8[?]', size), ffi.new('size_t[1]')
            -- ⚠️ 0.1.6 修：pcall 的第一个返回值是"调用没抛异常"，**不是**函数体里的返回值。
            -- 原来写成 `local ok_read = pcall(...)`，读失败（ReadProcessMemory 返回 0）时
            -- 内层的 `return false` 被丢掉 ⇒ 于是把一整块**零字节**当成了读到的内容
            -- （"读不到就安全失败"直接失效）。现在显式拿第二个返回值。
            local ok_read, read_ok = pcall(function()
                if kernel.ReadProcessMemory(process, ffi.cast('const void *', address), buffer,
                       size, received) == 0 then return false end
                return tonumber(received[0]) == size
            end)
            if not ok_read or read_ok ~= true then return nil end
            return ffi.string(buffer, size)
        end
        bound.get_key = function(vk)
            local ok_key, value = pcall(user32.GetAsyncKeyState, vk)
            if not ok_key or value == nil then return nil end
            return (tonumber(value) or 0) % 65536 >= 32768
        end
        bound.now = function() return tonumber(kernel.GetTickCount64()) / 1000 end
        -- 写内存（**只有传送那一段会用**）：写 12 字节并回读校验交给调用方
        bound.write = function(address, bytes)
            if not address or address == 0 or type(bytes) ~= 'string' or #bytes == 0 then
                return false
            end
            local written = ffi.new('size_t[1]')
            local ok_write, wrote = pcall(function()
                if kernel.WriteProcessMemory(process, ffi.cast('void *', address), bytes,
                       #bytes, written) == 0 then return false end
                return tonumber(written[0]) == #bytes
            end)
            return ok_write and wrote == true
        end
        -- 读整份文件（只读）：用于按键配置文件
        bound.read_file = function(path)
            local handle = kernel.CreateFileW(wide_string(path), 0x80000000, 0x00000001, nil, 3, 0x80, nil)
            if handle == nil or tonumber(ffi.cast('uintptr_t', handle)) == 0xFFFFFFFFFFFFFFFF then
                return nil, 'no-file'
            end
            local chunks, size = {}, 65536
            local buffer, received = ffi.new('nsb_u8[?]', size), ffi.new('nsb_u32[1]')
            for _ = 1, 64 do
                received[0] = 0
                local ok_read = pcall(function()
                    return kernel.ReadFile(handle, buffer, size, received, nil) ~= 0
                end)
                local got = tonumber(received[0]) or 0
                if not ok_read or got == 0 then break end
                chunks[#chunks + 1] = ffi.string(buffer, got)
            end
            kernel.CloseHandle(handle)
            local text = table.concat(chunks)
            if text == '' then return nil, 'empty' end
            return text
        end
        -- 注册表读字符串 / DWORD（只读）
        bound.reg_string = function(subkey, value)
            -- 0.1.0 修：`SteamPath` 是 **UTF-16**，原来用 `ffi.string(char[1024])` 读 ——
            -- 第一个字符后面紧跟一个 00 字节，于是只读出 1 个字符（实测日志里是 `d/userdata/…`，
            -- Steam 那条路径因此永远打不开、按键配置读不到）。改成按 UTF-16 解码。
            local data, size = ffi.new('nsb_u16[512]'), ffi.new('nsb_u32[1]', 1024)
            local code = kernel.RegGetValueW(ffi.cast('void *', 0x80000001), wide_string(subkey),
                wide_string(value), 0x00000002, nil, data, size)
            if code ~= 0 then return nil end
            local chars = math.floor((tonumber(size[0]) or 0) / 2)   -- pcbData 是**字节数**
            if chars <= 0 then return nil end
            local text = wide_to_utf8(data, chars)
            if text == '' then return nil end
            return (text:gsub('/$', ''))
        end
        bound.reg_dword = function(subkey, value)
            local data, size = ffi.new('nsb_u32[1]'), ffi.new('nsb_u32[1]', 4)
            -- v0.0.2 修：0.0.1 这里用了 RRF_RT_REG_SZ(0x2)，读 DWORD 直接失败 ——
            -- 于是 ActiveUser 读不到、Steam 那条配置路径被跳过（日志里"试过 2 个路径"就是这个）。
            local code = kernel.RegGetValueW(ffi.cast('void *', 0x80000001), wide_string(subkey),
                wide_string(value), 0x00000010, nil, data, size)
            if code ~= 0 then return nil end
            return tonumber(data[0])
        end
        bound.env = function(name)
            local value = ffi.new('nsb_u16[1024]')
            local got = kernel.GetEnvironmentVariableW(wide_string(name), value, 1024)
            if got == 0 then return nil end
            return wide_to_utf8(value, got)
        end
        -- 目录里找一份文件（只读）：本地存档的文件名带 id（`<peer_id>_input_settings.config`）
        bound.find_file = function(pattern)
            local data = ffi.new('nsb_u8[1168]')     -- WIN32_FIND_DATAW 够大；cFileName 在 +44
            local handle = kernel.FindFirstFileW(wide_string(pattern), data)
            if handle == nil or tonumber(ffi.cast('uintptr_t', handle)) == 0xFFFFFFFFFFFFFFFF then
                return nil
            end
            local name = wide_to_utf8(ffi.cast('nsb_u16 *', data + 44), 260)
            kernel.FindClose(handle)
            if name == '' then return nil end
            return name
        end
        return bound
    end)
    if not ok or not result then
        api.error = tostring(result)
        return nil
    end
    for index, value in pairs(result) do api[index] = value end
    api.ok = true
    return true
end

-- ── 只读内存小工具 ───────────────────────────────────────────────────
local function deref(address)
    if not address or address == 0 then return nil end
    local bytes = api.read(address, 8)
    if not bytes then return nil end
    local value = u64(bytes, 0)
    if not value or value == 0 then return nil end
    return value
end
local function global_at(rva)
    return deref(api.game + rva)
end
local function unit_node_and_position(unit_ref)
    if not unit_ref or unit_ref == 0 or unit_ref == 0xFFFFFFFF then return nil, nil, 'no-ref' end
    local registry = deref(api.exe + EXE_RVA.unit_registry)
    if not registry then return nil, nil, 'no-registry' end
    local header = api.read(registry, 0xA8)
    if not header then return nil, nil, 'no-header' end
    local count = u32(header, OFF.unit_registry_count)
    local objects, generations = u64(header, OFF.unit_registry_objects), u64(header, OFF.unit_registry_generations)
    if not count or not objects or not generations or count > 1048576 then
        return nil, nil, 'bad-header'
    end
    local slot = unit_ref % 4194304
    if slot >= count then return nil, nil, 'slot-range' end
    local generation = math.floor(unit_ref / 4194304) % 256
    local gen_byte = api.read(generations + slot, 1)
    if not gen_byte or gen_byte:byte(1) ~= generation then return nil, nil, 'generation' end
    local object = deref(objects + 8 * slot)
    if not object then return nil, nil, 'no-object' end
    local vtable = deref(object)
    if not vtable then return nil, nil, 'no-vtable' end
    local fn = deref(vtable + 0xE8)
    if not fn or fn ~= api.exe + EXE_RVA.unit_vtable then return nil, nil, 'layout' end
    local node = deref(object + OFF.unit_node)
    if not node then return nil, nil, 'no-node' end
    local bytes = api.read(node + OFF.unit_node_pos, 12)
    if not bytes then return nil, nil, 'no-pos' end
    local x, y, z = f32(bytes, 0), f32(bytes, 4), f32(bytes, 8)
    if not x or not y or not z then return nil, nil, 'bad-pos' end
    return node, { x, y, z }
end
-- ── 结构读取 ─────────────────────────────────────────────────────────
local function read_player()
    local pm = global_at(RVA.player_manager)
    if not pm then return nil, 'no-player-manager' end
    local head = api.read(pm, 0x440)
    if not head then return nil, 'no-player-record' end
    local count, available = u32(head, OFF.player_count), u32(head, OFF.player_available)
    if not count or not available or count > 4 or available > 4 then return nil, 'player-layout' end
    local mode
    local mode_manager = global_at(RVA.mission_mode)
    if mode_manager then
        local mode_bytes = api.read(mode_manager, 0x44)
        if mode_bytes and u32(mode_bytes, OFF.mode_active) ~= 0 then
            mode = u32(mode_bytes, OFF.mode_value)
        end
    end
    local player = { address = pm, count = count, available = available, mode = mode,
                     unit_ref = u32(head, OFF.player_unit) }
    local entity_at = deref(pm + OFF.player_entity)
    local entity = entity_at and api.read(entity_at, OFF.entity_stride)
    if entity then
        player.entity_at = entity_at
        player.entity_id = u32(entity, OFF.entity_id)
        player.unit = u32(entity, OFF.entity_unit)
        player.goid = u32(entity, OFF.entity_goid)
        player.owned = entity:byte(OFF.entity_owned + 1) % 2 == 1
    end
    player.in_mission = mode ~= nil and count >= 1 and count <= 4
    return player
end
local function ping_fields(entry)
    return { kind = u32(entry, OFF.ping_kind),
             x = f32(entry, OFF.ping_x), y = f32(entry, OFF.ping_y), z = f32(entry, OFF.ping_z),
             lifetime = f32(entry, OFF.ping_lifetime), elapsed = f32(entry, OFF.ping_elapsed),
             owner = u32(entry, OFF.ping_owner),
             picture = hexbytes_of(entry, OFF.ping_picture, 8) }
end
local function read_pings()
    local list = global_at(RVA.comms)
    if not list then return nil, 'no-ping-table' end
    local head_bytes = api.read(list + OFF.ping_head, 8)
    if not head_bytes then return nil, 'no-ping-head' end
    local head, tail = u32(head_bytes, 0), u32(head_bytes, 4)
    if not head or not tail or head > OFF.ping_slots or tail > OFF.ping_slots then
        return nil, 'ping-layout'
    end
    local entries_at = list + OFF.ping_entries
    local block = api.read(entries_at, OFF.ping_slots * OFF.ping_stride)
    if not block then return nil, 'no-ping-block' end
    local found = {}
    for slot = 0, OFF.ping_slots - 1 do
        local at = slot * OFF.ping_stride
        -- v0.0.2（优化）：**用整数比，不用十六进制字符串**。原来每轮对 128 个槽各拼两条
        -- 十六进制串（256 次 sub + gsub、2048 次 string.format），是整个 MOD 最重的 Lua 段；
        -- 改成比 7 个 u32 之后离线仿真量到每帧 45.6 → 20.9 微秒。
        local previous = state.ping_sig[slot]
        local kind_b, xb, yb = u32(block, at + OFF.ping_kind), u32(block, at + OFF.ping_x),
            u32(block, at + OFF.ping_y)
        local zb, owner_b = u32(block, at + OFF.ping_z), u32(block, at + OFF.ping_owner)
        local pic_lo, pic_hi = u32(block, at + OFF.ping_picture),
            u32(block, at + OFF.ping_picture + 4)
        local changed = not previous or previous[1] ~= kind_b or previous[2] ~= xb
            or previous[3] ~= yb or previous[4] ~= zb or previous[5] ~= owner_b
            or previous[6] ~= pic_lo or previous[7] ~= pic_hi
        if changed then
            state.ping_sig[slot] = { kind_b, xb, yb, zb, owner_b, pic_lo, pic_hi }
            local fields = ping_fields(block:sub(at + 1, at + OFF.ping_stride))
            local live = fields.lifetime and fields.elapsed and fields.owner
                and fields.lifetime > 0 and fields.elapsed >= 0 and fields.elapsed < fields.lifetime
                and fields.owner ~= 0
            if live then
                fields.slot = slot
                fields.excluded = fields.kind == BEACON_KIND
                fields.new_mark = not previous or previous[1] ~= kind_b or previous[5] ~= owner_b
                    or previous[6] ~= pic_lo or previous[7] ~= pic_hi
                found[#found + 1] = fields
            end
        end
    end
    return { address = list, head = head, tail = tail }, nil, found
end
local function read_throwables()
    local registry = global_at(RVA.throwable_reg)
    if not registry then return nil, 'no-throwable-registry' end
    local head = api.read(registry + OFF.throwable_map, 20)
    if not head then return nil, 'no-throwable-map' end
    local capacity, empty = u32(head, OFF.map_capacity), u32(head, OFF.map_empty)
    local table_at = u64(head, 0)
    if not capacity or not empty or not table_at or capacity == 0 or capacity > 4096 then
        return nil, 'throwable-map-layout'
    end
    local slots = api.read(table_at, capacity * 8)
    if not slots then return nil, 'no-throwable-slots' end
    local back = deref(registry + OFF.throwable_backref)
    local list = {}
    for slot = 0, capacity - 1 do
        local at = slot * 8
        local key, index = u32(slots, at), u32(slots, at + 4)
        if key and index and key ~= empty and index ~= 0xFFFFFFFF and index < 4096 then
            local entry = { entity_id = key, index = index }
            local record_at = back and deref(back + index * 8) or nil
            local record = record_at and api.read(record_at, OFF.entity_stride)
            if record and u32(record, OFF.entity_id) == key then
                entry.record_at = record_at
                entry.unit_ref = u32(record, OFF.entity_unit)
                entry.goid = u32(record, OFF.entity_goid)
                entry.owned = record:byte(OFF.entity_owned + 1) % 2 == 1
                entry.hash = hexbytes_of(record, 0, 8)
            end
            local row = api.read(registry + OFF.throwable_rows + index * OFF.throwable_stride,
                OFF.throwable_stride)
            if row then
                entry.fuse_pick = u32(row, OFF.throwable_fuse_pick)
                entry.fuse_count = u32(row, OFF.throwable_fuse_count)
            end
            local node, position, why = unit_node_and_position(entry.unit_ref)
            entry.node, entry.position, entry.position_error = node, position, why
            list[#list + 1] = entry
        end
    end
    return { address = registry, capacity = capacity, entries = list }
end

-- ── ① 按键：读玩家的按键配置文件，找出「射击键」 ──────────────────────
-- HD2 把绑定存在 `input_settings.config`（Lua 风格的文本表）：
--   * 关云存档：`%APPDATA%\Arrowhead\Helldivers2\saves\*_input_settings.config`
--   * 云存档：  `<SteamPath>\userdata\<ActiveUser>\553850\remote\input_settings.config`
-- 文件里只写**玩家改过**的绑定（没改的沿用游戏默认），所以找不到射击键时要说明这一点。
local function parse_bindings(text)
    local group, action, device, trigger = '', '', '', ''
    local out = {}
    for line in text:gmatch('[^\r\n]+') do
        local key = line:match('^([A-Za-z_][%w_]*)%s*=%s*{')
        if key then
            group, action = key, ''
        else
            local item = line:match('^\t([A-Za-z_][%w_]*)%s*=%s*%[')
            if item then
                action = item
            else
                local declared = line:match('^%s*device_type%s*=%s*"([^"]*)"')
                if declared then device = declared end
                local pressed = line:match('^%s*trigger%s*=%s*"([^"]*)"')
                if pressed then trigger = pressed end
                local bound = line:match('^%s*input%s*=%s*"([^"]*)"')
                if bound then
                    out[#out + 1] = { group = group, action = action, device = device,
                                      input = bound, trigger = trigger }
                    bound = nil
                end
            end
        end
    end
    return out
end

local KEY_VKS = {
    ['left ctrl'] = 0x11, ['right ctrl'] = 0xA3, ['left shift'] = 0x10, ['right shift'] = 0xA0,
    ['left alt'] = 0x12, ['right alt'] = 0xA4, ['space'] = 0x20, ['tab'] = 0x09,
    ['enter'] = 0x0D, ['escape'] = 0x1B, ['backspace'] = 0x08,
    ['mousebutton1'] = 0x01, ['mousebutton2'] = 0x02, ['mousebutton3'] = 0x04,
    ['mousebutton4'] = 0x05, ['mousebutton5'] = 0x06,
}
for letter = string.byte('a'), string.byte('z') do
    KEY_VKS[string.char(letter)] = letter - 32
end
for digit = 0, 9 do
    KEY_VKS[tostring(digit)] = 0x30 + digit
    KEY_VKS['numpad ' .. digit] = 0x60 + digit
end
KEY_VKS['numpad *'] = 0x6A
KEY_VKS['numpad +'] = 0x6B
KEY_VKS['numpad -'] = 0x6D
KEY_VKS['numpad .'] = 0x6E
KEY_VKS['numpad /'] = 0x6F

local function vk_of(name)
    if type(name) ~= 'string' then return nil end
    return KEY_VKS[name:lower()]
end

local FIRE_NAME_HINTS = { 'fire', 'shoot', 'attack', 'weapon', 'trigger' }
local function pick_fire(bindings)
    local best
    for _, row in ipairs(bindings) do
        local action = (row.action or ''):lower()
        local hit = nil
        for _, hint in ipairs(FIRE_NAME_HINTS) do
            if action:find(hint, 1, true) then hit = hint break end
        end
        if hit then
            local vk = vk_of(row.input)
            if vk then
                local rank = (row.device == 'Keyboard' and 1) or (row.device == 'Mouse' and 2) or 3
                if not best or rank < best.rank then
                    best = { rank = rank, name = row.action, input = row.input, vk = vk,
                             device = row.device, group = row.group, hint = hit }
                end
            end
        end
    end
    return best
end

local function load_input_config()
    local paths = {}
    local steam = api.reg_string('Software\\Valve\\Steam', 'SteamPath')
    local active = api.reg_dword('Software\\Valve\\Steam\\ActiveProcess', 'ActiveUser')
    census_add(string.format('keyconfig_steam steam=%s active=%s', tostring(steam),
        tostring(active)))
    if steam and active and active > 0 then
        paths[#paths + 1] = string.format('%s/userdata/%d/553850/remote/input_settings.config',
            steam, active)
    end
    local appdata = api.env('APPDATA')
    if appdata then
        paths[#paths + 1] = appdata .. '\\Arrowhead\\Helldivers2\\input_settings.config'
        paths[#paths + 1] = appdata .. '\\Arrowhead\\Helldivers2\\saves\\input_settings.config'
        -- 本地存档里的名字带 id（`<peer_id>_input_settings.config`）→ 目录里找一份
        if api.find_file then
            local name = api.find_file(appdata
                .. '\\Arrowhead\\Helldivers2\\saves\\*_input_settings.config')
            if name then
                paths[#paths + 1] = appdata .. '\\Arrowhead\\Helldivers2\\saves\\' .. name
            end
        end
    end
    local text, used
    for _, path in ipairs(paths) do
        local ok, content = pcall(api.read_file, path)
        if ok and content then text, used = content, path break end
        census_add(string.format('keyconfig_miss path=%s err=%s', path, tostring(content)))
    end
    if not text then
        note('KEY 没读到按键配置文件（试过 ' .. #paths .. ' 个路径）→ 按键追踪退回默认', true)
        state.fire = { name = 'MouseButton1（默认）', device = 'Mouse', input = 'MouseButton1',
                       vk = 0x01, default = true }
        return
    end
    note(string.format('KEY 按键配置文件：%s（%d 字节）', used, #text), true)
    census_add(string.format('keyconfig path=%s bytes=%d', used, #text))
    state.bindings = parse_bindings(text)
    note(string.format('KEY 配置文件里共 %d 条绑定：', #state.bindings), true)
    for _, row in ipairs(state.bindings) do
        local line = string.format('  %s / %s → %s:%s（trigger=%s）', row.group, row.action,
            row.device, row.input, row.trigger)
        note(line, true)
        census_add(string.format('binding group=%s action=%s device=%s input=%s trigger=%s',
            row.group, row.action, row.device, row.input, row.trigger))
    end
    local fire = pick_fire(state.bindings)
    if fire then
        state.fire = fire
        note(string.format('KEY 射击键 = %s（%s:%s，vk=0x%02X；靠动作名含「%s」认出）',
            fire.name, fire.device, fire.input, fire.vk, fire.hint), true)
    else
        state.fire = { name = 'MouseButton1（默认）', device = 'Mouse', input = 'MouseButton1',
                       vk = 0x01, default = true }
        note('KEY 配置文件里没有射击键 —— 说明玩家没改过它（文件只写改过的绑定）→ '
            .. '按 HD2 默认的鼠标左键（MouseButton1）追踪；如果你改过，把上面那份绑定清单发我',
            true)
    end
end

-- ── ② 本机玩家 vs 联机玩家 ──────────────────────────────────────────
-- 三条证据并用（每条都写进日志，谁对谁错上机一眼能看出来）：
--   ① 游戏自己的**本机玩家记录**（player_manager → entity id / unit / goid）；
--   ② **owner 自学**：自己丢出的球落地时游戏会插一条 kind=20 的信标标记，它的 owner 就是我的 id
--      （上一个 MOD 的做法：标记与自己的球相距 < 5 米才算），学到之后标点表就能分"是不是我标的"；
--   ③ **按键对齐**：用户指定 —— 按 Ctrl 才会生成战备球、按 Q 才会标点。
--      所以"记录出现时最近按过键"= 本机的强证据；"没按键却有记录"= 联机玩家的。
local function poll_player()
    local player, why = read_player()
    if not player then
        census_add(string.format('player_fail frame=%d why=%s', state.frames, tostring(why)))
        return
    end
    state.player = player
    state.solo = player.count == 1 and player.available == 1
    if player.entity_id and player.entity_id ~= state.me.entity then
        state.me = { entity = player.entity_id, unit = player.unit, goid = player.goid,
                        count = player.count, available = player.available }
        note(string.format('PLAYER 本机玩家 entity=0x%X unit=%s goid=%s（场上 %d 人，%s）',
            player.entity_id, tostring(player.unit), tostring(player.goid), player.count,
            state.solo and '单人局' or '多人局'), true)
        census_add(string.format('player local entity=0x%X unit=%s goid=%s count=%d',
            player.entity_id, tostring(player.unit), tostring(player.goid), player.count))
    end
end

local function learn_owner(ping)
    if ping.kind ~= BEACON_KIND or not ping.owner then return end
    local nearest, which = math.huge, nil
    for id, ball in pairs(state.balls) do
        -- 用户确认（第一点）：**只从"本机球"学 owner** —— 本机球 = entity 记录的 owned 位为 true
        -- 的那颗（就是我们归属判定用的同一条判据）。0.0.1 是"离哪颗球最近就学谁"，会把别人的球
        -- 的信标也学进来（实测 my_owner 在 928/858/918/1630/4194873… 之间来回跳）。
        if ball.mine == true and ball.position then
            local gap = distance3(ball.position, { ping.x, ping.y, ping.z })
            if gap < nearest then nearest, which = gap, id end
        end
    end
    if not which or nearest > OWNER_MATCH_MAX then
        if not state.owner_wait then
            state.owner_wait = true
            census_add(string.format('owner_wait frame=%d why=还没有"本机球"（owned 位=true 的球）'
                .. ' → 先不学 owner，免得学成别人的', state.frames))
        end
        return
    end
    state.owner_wait = nil
    if state.my_owner ~= ping.owner then
        state.my_owner = ping.owner
        note(string.format('PLAYER 自学到本机 owner=%s（由**本机球** entity=0x%X 落地后的信标标记'
            .. '反推，相距 %.2f 米；该球 owned 位=true）→ 标点表用它对"是不是我标的"',
            tostring(ping.owner), which, nearest), true)
        census_add(string.format('owner_learn frame=%d owner=%s from=0x%X dist=%.2f',
            state.frames, tostring(ping.owner), which, nearest))
    end
end

local function ping_is_mine(ping)
    if state.my_owner ~= nil and ping.owner == state.my_owner then return true, 'owner 自学命中' end
    if state.me.entity ~= nil and ping.owner == state.me.entity then
        return true, '本机玩家 entity 命中'
    end
    if state.solo == true then return true, '单人局（场上只有我）' end
    -- 第四点（用户要求日志改清楚）：这里写"owner 不是本机"会被读成"这不是你标的" ——
    -- 其实只是"owner 与**当时自学到的**那个值不符"，而那个自学值本身可能不准。
    return false, string.format('owner 与暂定本机 owner（%s）不符 —— 自学值，未必可靠',
        tostring(state.my_owner))
end

-- ── ③.5 状态机（0.1.0；本切片 = 切片 1+2）──────────────────────────────
-- 用户给的《主要运行逻辑 - 测试》落到代码的顺序（一片片来、一片片测）：
--   切片 1（本文件已做）：球逐帧判 —— 注册表头 + 槽表逐帧比，变了才做完整枚举
--   切片 2（本文件已做）：球创建 → 跟踪标点 → 我的新标点 → ready 3 秒倒计时 + 每步一行日志
--   切片 3（已做）：射击键窗口追踪（「开始追踪 / 已松开」两行）+ 0.1.2 的三条补充
--   切片 4（已做）：deploy（黄）→ **没有延迟**（0.1.16 起把延迟代码删干净）→ accomplish / cancel（红）
--   切片 5（本切片）：HUD（两行四色、默认 on、可关；判定逻辑不依赖它）
--   切片 6：传送（每帧写所有副本）—— 还没做
-- 判据（用户已确认）：只认**球创建之后**出现的我的标点（不支持"先标点后拿球"）；
--   排除 kind=20（自己刚丢的信标）；其余标点类型一律收；多次标点只留最新、每标一次重开窗口。
local function step(name, detail)
    state.counts.steps = state.counts.steps + 1
    note(string.format('STEP %s frame=%d t=%.1fs%s', name, state.frames, state.seconds,
        detail and (' ' .. detail) or ''), true)
    census_add(string.format('step name=%s frame=%d t=%.1f %s', name, state.frames,
        state.seconds, detail or ''))
end

local function track_reset()
    local track = state.track
    track.active, track.ball, track.ball_frame = false, nil, nil
    track.mark, track.window_left, track.expired = nil, 0, false
    track.frozen, track.watch, track.mark_started = false, false, nil
    track.phase = 'idle'
    -- 0.1.14：握持期预扫的缓存跟着本轮作废（换球/收尾都要重扫）
    state.prescan_offsets, state.prescan_at, state.prescan_count = nil, nil, nil
    state.prescan_node, state.prescan_pos = nil, nil
end

local function track_end(reason)
    if not state.track.active then return end
    step('战备球销毁', string.format('reason=%s entity=0x%X mark=%s → 停止跟踪，回第一步',
        tostring(reason), state.track.ball or 0,
        state.track.mark and xyz_text(state.track.mark) or '(还没标点)'))
    track_reset()
end

local function track_begin(entity_id)
    track_reset()                       -- 新球接管：上一颗的跟踪作废（用户：记录最后出现的那颗）
    local track = state.track
    track.active, track.ball, track.ball_frame = true, entity_id, state.frames
    track.phase = 'ready'
    step('检测到本机战备球创建', string.format('entity=0x%X 单位哈希=战备球 owned=true', entity_id))
    step('开始跟踪标点', '只认这之后出现的我的标点（kind≠20）')
    -- 0.1.2（用户补充）：**跟踪射击键从"球创建那一刻"就开始**（原来是在第一次标点之后）。
    track.watch = true
    step('开始追踪射击键', '球创建即开始（0.1.2 补充）；等"松开射击键"')
end

local function track_mark(ping, mine)
    local track = state.track
    if not track.active or not mine then return end
    if ping.kind == BEACON_KIND then return end          -- 自己刚丢的信标：不算玩家标点
    local mark = track.mark
    local same = mark and mark.slot == ping.slot
    if track.phase == 'deploy' then
        -- 切片 4（用户定："deploy 不冻结，继续获取最新的标点坐标"）：
        -- 目标跟着**最新**的我的标点走，但**窗口不重开**（窗口已冻结在松开那一刻，只用于超时判定）。
        if ping.new_mark then
            track.mark = { ping.x, ping.y, ping.z }
            track.mark.slot, track.mark.kind = ping.slot, ping.kind
            track.mark.owner, track.mark.frame = ping.owner, state.frames
            step('标点更新', string.format('slot=%d kind=%d xyz=%s（deploy 期间跟最新标点；窗口不重开）',
                ping.slot, ping.kind, xyz_text(track.mark)))
        elseif same then
            mark[1], mark[2], mark[3] = ping.x, ping.y, ping.z
            if (state.frames - (state.mark_log_at or -99999)) >= PING_LOG_EVERY then
                state.mark_log_at = state.frames
                step('标点更新', string.format('slot=%d xyz=%s（deploy 期间；窗口不重开）',
                    ping.slot, xyz_text(track.mark)))
            end
        end
        return
    end
    if not (ping.new_mark or same) then
        -- 既不是"刚出现/刚被换上来的新标记"，也不是我们已经在跟的那条
        -- ⇒ 它只能是**球创建之前就存在**的旧标点，这会儿只是位置在变。
        -- 用户明确：不支持"先标点后拿球" ⇒ 拒收（只记 census，按槽限流）。
        if not state.mark_skip[ping.slot] then
            state.mark_skip[ping.slot] = true
            census_add(string.format('mark_skip frame=%d slot=%d kind=%d 首见=%s 球创建=%s'
                .. '（旧标点，只是位置在变 → 不采纳）', state.frames, ping.slot, ping.kind,
                tostring(state.ping_first[ping.slot]), tostring(track.ball_frame)))
        end
        return
    end
    -- 走到这里只可能是两种情况：① ping.new_mark（刚出现/刚被换上来的新标记）
    -- ② same（我们已经在跟的那条）。所以 `not same` 等价于"这是新标记"，
    -- 但写成 `not same` 更稳：万一 mark 丢了也不会去索引空表。
    if not same then
        -- 存成数组（xyz_text / distance3 都按 [1][2][3] 读），后面挂上出处信息
        track.mark = { ping.x, ping.y, ping.z }
        track.mark.slot, track.mark.kind = ping.slot, ping.kind
        track.mark.owner, track.mark.frame = ping.owner, state.frames
        track.marks = track.marks + 1
        track.window_left, track.expired = MARK_WINDOW_SEC, false
        track.frozen, track.mark_started = false, state.seconds
        state.mark_log_at = state.frames
        step('新标点', string.format('slot=%d kind=%d xyz=%s → 开始 %.1f 秒倒计时（第 %d 次重开）',
            ping.slot, ping.kind, xyz_text(track.mark), MARK_WINDOW_SEC, track.marks))
        -- 0.1.2：不再"每标一次重新武装"——射击键追踪从球创建起一直开着，
        -- 第一次"松开"就用掉这次呼叫（超时 / 未超时都算，见 poll_fire_watch）。
        return
    end
    -- 同一条标点在动（或同一个静态标点重复读）：只更新坐标，**不重开窗口**
    mark[1], mark[2], mark[3] = ping.x, ping.y, ping.z
    if (state.frames - (state.mark_log_at or -99999)) >= PING_LOG_EVERY then
        state.mark_log_at = state.frames
        step('标点更新', string.format('slot=%d xyz=%s 剩余=%.1fs', ping.slot,
            xyz_text(track.mark), math.max(0, track.window_left)))
    end
end

local function track_tick(dt_secs)
    local track = state.track
    if not track.active or not track.mark or track.frozen or track.window_left <= 0 then return end
    track.window_left = track.window_left - dt_secs
    if track.window_left > 0 then return end
    track.window_left, track.expired = 0, true
    step('倒计时结束', string.format('窗口 %.1f 秒走完（标点还留着；等切片 3 的"松开射击键"再判定）',
        MARK_WINDOW_SEC))
end

-- ── 切片 3：射击键窗口（逐帧静默采样 → 认"松开"）──────────────────────
-- 用户流程：「开始跟踪射击键状态… if 玩家"松开"射击键 → 冻结标点倒计时」。
-- 这里只做"认出松开 + 冻结 + 写日志"；deploy / 传送 / cancel 是切片 4 / 6。
-- 窗口武装（track.watch）由"球创建后第一次采纳标点"打开；一次呼叫只认一次松开。
local function poll_fire_watch()
    if not api.get_key or not state.fire then return end
    local down = api.get_key(state.fire.vk)
    if down == nil then return end
    local previous = state.key_prev
    state.key_prev = down
    if previous == nil or previous == down then return end
    state.counts.keys = state.counts.keys + 1
    census_add(string.format('key_edge tag=fire %s frame=%d', down and 'down' or 'up',
        state.frames))
    if down then return end                              -- 只关心"松开"
    local track = state.track
    if not (track.active and track.watch) then return end
    track.watch = false                                  -- 一次呼叫只认一次松开
    local since_ball = track.ball_frame and (state.frames - track.ball_frame) or -1
    local age = track.mark_started and (state.seconds - track.mark_started) or nil
    step('松开射击键', string.format('球创建后 %d 帧；标点后 %s', since_ball,
        age and string.format('%.1fs', age) or '(还没标点)'))
    if not track.mark then
        -- 0.1.2（用户补充）：球到手、还没标点就松手 ⇒ 这次作废，回第一步
        -- （用户明确要求按原样做、不收紧：球还在手里也不算，玩家自己再拿一颗）
        step('停止跟踪', '还没标点就"松开射击键" → 这次作废，回第一步（0.1.2 补充）')
        track_reset()
        return
    end
    track.frozen = true                                  -- 冻结：track_tick 不再走这个窗口
    if track.window_left <= 0 then
        step('冻结倒计时', string.format('标点后 %.1fs > %.1f 秒 → 超时',
            age or 0, MARK_WINDOW_SEC))
        -- 切片 4：超时 ⇒ cancel（红）⇒ 停止跟踪，回第一步
        step('cancel', string.format('红色、停止刷新（HUD 后台 2 秒后关）→ 本轮结束，回第一步（mark=%s）',
            xyz_text(track.mark)))
        state.hud_last = { phase = 'cancel', mark = track.mark,
                           until_frame = state.frames + 120 }
        track_reset()
        return
    end
    step('冻结倒计时', string.format('标点后 %.1fs ≤ %.1f 秒（窗口剩 %.1fs）→ 未超时',
        age or 0, MARK_WINDOW_SEC, track.window_left))
    -- 切片 4：未超时 ⇒ deploy（黄）；**记录最后的本机战备球索引**，后面出现新球也不换
    track.phase = 'deploy'
    step('deploy', string.format('黄色、无倒计时；目标球 entity=0x%X 已锁定', track.ball or 0))
end

-- 切片 4/6：deploy 阶段逐帧推进 —— **没有延迟**：松开那一刻（同一帧）就开始传送
local function track_deploy()
    local track = state.track
    if track.phase ~= 'deploy' then return end
    step('开始传送', string.format('松开即投出（无延迟）→ **开始传送**（目标 xyz=%s）',
        track.mark and xyz_text(track.mark) or '(没标点)'))
    track.phase = 'teleport'                                  -- HUD 上仍按 deploy 显示
    -- 0.1.14：把"握持期预扫"的偏移拿过来当初始清单 —— 松手这一帧就直接开写，不再现扫。
    -- 0.1.15（用户选 B）：**拿之前必须先证伪**，两条硬闸门：
    --   ① **node 必须还是同一个**（偏移是相对 node 的；球离手重挂/换对象后，旧偏移会指到别人的字段）；
    --   ② **逐条复核**：读一次，值必须还落在"球当前位置 1 米内"（球自己的位置副本必然满足；
    --      被复用的字段会被剔掉）。一条都不剩就整份作废。
    -- 预扫为空 / 被证伪 ⇒ 留空：teleport_step 的老路（缓存空 → 现扫）会兜住。
    local seeded, offsets = false, {}     -- ⚠️ 必须是 false（空表恒真，会把"没预扫"当成"已就绪"）
    local ball = track.ball and state.balls[track.ball]
    local node, pos = unit_node_and_position(ball and ball.unit_ref)
    if state.prescan_offsets and state.prescan_node and node and pos then
        if state.prescan_node ~= node then
            step('预扫作废', string.format('node 变了（预扫 0x%X → 现在 0x%X）→ 丢掉握持期缓存，'
                .. '改用在飞行中现扫', state.prescan_node, node))
        else
            local kept, dropped = 0, 0
            for _, entry in ipairs(state.prescan_offsets) do
                local bytes = api.read(node + entry.offset, 12)
                local ok = false
                if bytes then
                    local x, y, z = f32(bytes, 0), f32(bytes, 4), f32(bytes, 8)
                    ok = x and y and z and distance3({ x, y, z }, pos) <= PRESCAN_VERIFY_MAX
                end
                if ok then
                    offsets[#offsets + 1] = { offset = entry.offset, fails = 0 }
                    kept = kept + 1
                else
                    dropped = dropped + 1
                end
            end
            seeded = kept > 0
            step('预扫复核', string.format('%d 处里留下 %d 处（丢掉 %d 处：值已不在球当前位置 '
                .. '%.1f 米内）→ %s', #state.prescan_offsets, kept, dropped, PRESCAN_VERIFY_MAX,
                seeded and '用这份清单开写' or '一条都不剩 → 改用飞行中现扫'))
        end
    end
    state.teleport = { active = true, ball = track.ball,
                       target = { track.mark and track.mark[1] or 0,
                                  track.mark and track.mark[2] or 0,
                                  track.mark and track.mark[3] or 0 },
                       offsets = offsets, scanned_at = seeded and state.frames or nil,
                       written = 0, rounds = 0,
                       start = state.frames, start_sec = state.seconds, hits = 0,
                       scans = 0, seeded = seeded, seeded_count = #offsets }
    if seeded then
        step('预扫就绪', string.format('松手即刻开写：直接用握持期预扫好的 %d 处偏移（这一帧就写）',
            #offsets))
    end
end

-- ── ⑥ 传送（切片 6）：把"球位置的所有副本"改写成标点坐标 ────────────────
-- 用户《主要运行逻辑》：deploy → 把最后的战备球传到标点 → accomplish（0.1.16 起**没有延迟**）；
-- 传不过去 → cancel。做法照旧 MOD 实测"机制成立"的那条路（靶子 6）：
--   ① 在球 node ±256 KB 里扫出所有"值等于球当前位置"的 float3（位置副本）；
--   ② **把这些地址缓存下来，之后每帧重写** —— 物理每帧都会重算，只写一次会被覆盖；
--   ③ 每个地址：备份原字节 → 写 → 回读校验 → 不一致就**回滚**并把该地址踢出缓存；
--   ④ 三道保护：写前复核球还在/仍是本机战备球、堆复用闸门（该地址的值仍等于目标值或离球 5 米内）、
--      单颗球写入预算 3000 处。
-- 这是本 MOD **唯一写内存**的地方；每写一个新地址前先把原字节落到 `_original_hex` 日志。
--   0.1.7（用户定，治掉帧/治"传不动"）：
--     * **按"相对 node 的偏移"缓存**，扫描只在缓存为空时做（且两次扫描至少隔 30 帧）——
--       原来按"球离上次扫描点 >2 米"重扫 ⇒ 球飞行时**每帧都重扫 512 KB**，实测掉到 31 fps；
--     * 写入上限从"累计 3000 处"改成"**整个传送最多 3 秒**"（累计写入会被正常的长呼叫撞上）。
local TELEPORT_SCAN_SPAN = 0x40000        -- 球 node ±256 KB
local TELEPORT_CHUNK = 0x10000            -- 一次读 64 KB（受 READ_MAX 限制）
local TELEPORT_MAX_ADDRS = 256
local TELEPORT_MAX_SEC = 3.0              -- 传送最多 3 秒（用户定；取代"写入处数预算"）
local TELEPORT_REACH = 0.25               -- 球离目标多近算"到了"（用户定：不放宽）
local TELEPORT_MAX_FRAMES = 1800          -- 兜底硬上限（30 秒）
local TELEPORT_TOL = 0.02                 -- 扫"等于球位置"的容差（米）
local TELEPORT_RESCAN_GAP = 30            -- 缓存空了以后，两次扫描至少隔这么多帧
local TELEPORT_OFFSET_DEAD = 60           -- 某个偏移连续失败这么多次就从缓存里删掉

-- 握持期预扫的常量在文件顶部配置区（PRESCAN_EVERY / PRESCAN_SCAN_SPAN / PRESCAN_VERIFY_MAX）——
-- 必须声明在用它们的函数之前，别挪回这里（0.1.12 的 `PROBE_ENABLED` 就是声明晚了踩的坑）。

local function pos_bytes(x, y, z)
    local buffer = ffi.new('nsb_u8[12]')
    local floats = ffi.cast('float *', buffer)
    floats[0], floats[1], floats[2] = x, y, z
    return ffi.string(buffer, 12)
end

-- 扫描：返回的是**相对 node 的偏移**（不是绝对地址）—— 同一颗球的副本偏移是稳定的，
-- 之后每帧按偏移直接算地址，不用再扫。
-- `span` 可选（0.1.15）：握持期预扫传 ±8 KB，传送期间的现扫仍用默认 ±256 KB。
local function teleport_scan(node, pos, span)
    local hits = {}
    span = span or TELEPORT_SCAN_SPAN
    local offset = -span
    while offset < span do
        -- 0.1.16 修：一次读多少要由"**剩余窗口**"决定。原来固定读 TELEPORT_CHUNK（64 KB），
        -- 比预扫窗口（±8 KB）还大 ⇒ 实际第一读就覆盖 [node-8KB, node+56KB]，等于窗口没收窄
        -- （0.1.15 那局实测：写入地址跨度最大 32 KB、169 帧里 28 帧 > 8 KB）。
        local step = math.min(TELEPORT_CHUNK, span - offset)
        local bytes = api.read(node + offset, step)
        if bytes then
            for at = 0, #bytes - 12, 4 do
                local x, y, z = f32(bytes, at), f32(bytes, at + 4), f32(bytes, at + 8)
                -- 0.1.15 修：`f32` 遇到 NaN/Inf 会返回 nil ⇒ 三个分量都要判（0.1.13 那局就因为
                -- 只判了 x、y 是 nil，报了 "attempt to perform arithmetic on local 'y'"）。
                if x and y and z
                    and math.abs(x - pos[1]) <= TELEPORT_TOL
                    and math.abs(y - pos[2]) <= TELEPORT_TOL
                    and math.abs(z - pos[3]) <= TELEPORT_TOL then
                    if #hits < TELEPORT_MAX_ADDRS then
                        hits[#hits + 1] = { offset = offset + at, fails = 0 }
                    end
                end
            end
        end
        offset = offset + step
    end
    return hits
end

-- 0.1.14：握持期预扫 —— 球还在手里（phase='ready'）时每 PRESCAN_EVERY 帧扫一次，把偏移存起来。
-- 球在手里时全体副本同步（实测 36~38 处），松手那一刻 teleport_begin 会直接把这份缓存当初始清单。
local function prescan_step()
    local track = state.track
    if not track.active or track.phase ~= 'ready' then return end   -- 只管"球在手里"这一段
    if state.prescan_at and state.frames - state.prescan_at < PRESCAN_EVERY then return end
    local ball = track.ball and state.balls[track.ball]
    if not ball or ball.mine ~= true or ball.hash ~= STRATAGEM_BALL_LE then return end
    local node, pos = unit_node_and_position(ball.unit_ref)
    if not node or not pos then return end
    state.prescan_at = state.frames
    -- 省算力的闸门（0.1.14）：偏移是**相对 node** 的，球站着不动时再扫一遍结果必然一样。
    -- 只有"球动了（≥5 cm）"或"node 换了"才真扫 —— 实测每 10 帧硬扫一次是 +0.38 ms/帧、
    -- 单次 ~3.8 ms 的小卡顿；加这道闸门后站着拿球时**一次都不扫**。
    if state.prescan_offsets and state.prescan_node == node and state.prescan_pos
        and distance3(pos, state.prescan_pos) < 0.05 then
        return
    end
    local offsets = teleport_scan(node, pos, PRESCAN_SCAN_SPAN)   -- 0.1.15：预扫只扫 ±8 KB
    if #offsets == 0 then return end                 -- 扫不到就留着上一次的结果
    state.prescan_offsets = offsets
    state.prescan_node = node
    state.prescan_pos = { pos[1], pos[2], pos[3] }
    if state.prescan_count ~= #offsets then          -- 只在"扫到几处"变了时记一行，避免刷日志
        state.prescan_count = #offsets
        step('握持预扫', string.format('球还在手里：node ±%d KB 扫到 %d 处位置副本（每 %d 帧刷一次）'
            .. ' → 松手直接用这份偏移开写', PRESCAN_SCAN_SPAN / 1024, #offsets, PRESCAN_EVERY))
    end
end

local function teleport_write(node, list, target, ball_pos)
    local written = 0
    for index = #list, 1, -1 do
        local entry = list[index]
        local address = node + entry.offset
        local before = api.read(address, 12)
        if not before then
            entry.fails = entry.fails + 1                     -- 读不到：先记失败，连续太久才踢
        else
            local x, y, z = f32(before, 0), f32(before, 4), f32(before, 8)
            local at_target = x and math.abs(x - target[1]) <= 0.05
                and math.abs(y - target[2]) <= 0.05 and math.abs(z - target[3]) <= 0.05
            -- 堆复用闸门：要么已经是我们写进去的目标值，要么它还在球的附近（没被复用）
            local ok_here = at_target
            if not ok_here and x and ball_pos then
                ok_here = distance3({ x, y, z }, ball_pos) < 5.0
            end
            if not ok_here then
                entry.fails = entry.fails + 1
            else
                if not at_target then hex_snapshot(address, before) end
                if api.write and api.write(address, pos_bytes(target[1], target[2], target[3])) then
                    local after = api.read(address, 12)
                    if after and f32(after, 0) and math.abs(f32(after, 0) - target[1]) <= 0.05
                        and math.abs(f32(after, 4) - target[2]) <= 0.05
                        and math.abs(f32(after, 8) - target[3]) <= 0.05 then
                        written = written + 1
                        entry.fails = 0
                    else
                        api.write(address, before)               -- 回读不一致 → 回滚
                        entry.fails = entry.fails + 1
                    end
                else
                    entry.fails = entry.fails + 1
                end
            end
        end
        if entry.fails >= TELEPORT_OFFSET_DEAD then table.remove(list, index) end
    end
    return written
end

local function teleport_finish(ok, detail)
    local tele, track = state.teleport, state.track
    if not tele then return end
    local target = { tele.target[1], tele.target[2], tele.target[3] }
    state.teleport_written = (state.teleport_written or 0) + tele.written
    if ok then
        step('传送成功', string.format('球已在目标附近（写了 %d 处、%d 轮）', tele.written,
            tele.rounds))
        step('accomplish', string.format('蓝色、停止刷新；显示目标坐标 %s（HUD 后台 2 秒后关）'
            .. '→ 本轮结束，回第一步', xyz_text(target)))
        state.hud_last = { phase = 'accomplish', mark = target, until_frame = state.frames + 120 }
    else
        step('cancel', string.format('红色、停止刷新；**传送失败（%s）**（写了 %d 处、%d 轮）'
            .. '→ 本轮结束，回第一步', tostring(detail), tele.written, tele.rounds))
        state.hud_last = { phase = 'cancel', mark = track.mark or target,
                           until_frame = state.frames + 120 }
    end
    state.teleport = nil
    track_reset()
end

local function teleport_step()
    local tele = state.teleport
    if not tele or not tele.active then return end
    local track = state.track
    -- 目标跟着**最新**的我的标点（用户定：deploy 不冻结）
    if track.mark then
        tele.target[1], tele.target[2], tele.target[3] = track.mark[1], track.mark[2], track.mark[3]
    end
    -- 写前复核：球还在、还是本机战备球
    local ball = tele.ball and state.balls[tele.ball]
    if not ball or ball.mine ~= true or ball.hash ~= STRATAGEM_BALL_LE then
        teleport_finish(false, '球已经不在了（或不再是本机战备球）')
        return
    end
    local node, pos, why = unit_node_and_position(ball.unit_ref)
    if not node or not pos then
        census_add(string.format('teleport_no_pos frame=%d why=%s', state.frames, tostring(why)))
        if state.frames - tele.start > 60 then teleport_finish(false, '读不到球坐标') end
        return
    end
    -- ① 只在**缓存为空**时扫一次（两次扫描至少隔 TELEPORT_RESCAN_GAP 帧）。
    --    0.1.7：不再按"球位移"重扫 —— 那是掉帧的根因（球飞行时每帧都满足）。
    if #tele.offsets == 0
        and (not tele.scanned_at or state.frames - tele.scanned_at >= TELEPORT_RESCAN_GAP) then
        tele.offsets = teleport_scan(node, pos)
        tele.scanned_at = state.frames
        tele.scans = tele.scans + 1
        tele.hits = tele.hits + #tele.offsets
        step('传送扫描', string.format('node=0x%X 找到 %d 处位置副本（第 %d 次扫，'
            .. '之后按相对偏移直接用）', node, #tele.offsets, tele.scans))
    end
    -- ② 每帧重写缓存里的地址
    if #tele.offsets > 0 then
        local written = teleport_write(node, tele.offsets, tele.target, pos)
        tele.written = tele.written + written
        tele.rounds = tele.rounds + 1
        if tele.rounds == 1 or tele.rounds % 30 == 0 then
            step('传送写入', string.format('第 %d 轮：写 %d 处（缓存剩 %d）', tele.rounds, written,
                #tele.offsets))
        end
    end
    -- ③ 成功：球已经到目标附近
    if distance3(pos, tele.target) <= TELEPORT_REACH then
        teleport_finish(true)
        return
    end
    -- ④ 失败：3 秒还没成（用户定）→ 失败；再有 30 秒的硬兜底
    if state.seconds - (tele.start_sec or state.seconds) > TELEPORT_MAX_SEC then
        teleport_finish(false, string.format('%.0f 秒还没传到', TELEPORT_MAX_SEC))
        return
    end
    if state.frames - tele.start > TELEPORT_MAX_FRAMES then
        teleport_finish(false, string.format('%d 帧还没到', TELEPORT_MAX_FRAMES))
    end
end

-- ── ⑤ HUD（切片 5）：屏幕上方两行 —— STATE + 标点 XYZ ───────────────────
-- 画法照真机跑得起来的那两份成品（`work\reference` 里的 Reticle Ammo HUD 1.1.3 /
-- `mods\stratagem_ping_hud`）：
--   * 字体/材质用**资源名**（HUD_FONT），**一个字都不从内存里读句柄** ⇒ 不需要"构建指纹"闸门；
--   * **画完即销毁** + 内容指纹节流：倒计时量化到 0.1 秒进指纹 ⇒ 每 0.1 秒重画一次；
--   * 每帧确认 world 还活着才 destroy_gui；只在任务里画；连续出错 5 次本次会话停手；
--   * **判定逻辑一行都不读 HUD** —— HUD 只把状态机画出来，它出错只影响显示。
-- 两行：`STATE  <phase> <倒计时>`（ready 才有倒计时，一位小数）/ `XYZ  x  y  z`。
-- 颜色：ready 绿 / deploy 黄 / accomplish 蓝 / cancel 红。
-- ⚠️ **引擎 `stingray.Color` 的参数顺序是 (a, r, g, b) —— alpha 在最前面**（0.1.5 修的 bug）：
--   参考成品 ReticleAmmoHUD 1.1.3 的 `rgba()` 返回的就是 `{alpha, r, g, b}`，再交给
--   `Color(c[1], c[2], c[3], c[4])`；`mods\stratagem_ping_hud` 也是这个顺序
--   （`Color(255, 120, 240, 150)` = 不透明 + 浅绿）。0.1.4 我按 (r,g,b,a) 传，
--   于是 ready 的 60 被当成 alpha（≈24% 不透明）、RGB 变成 (255,90,235) → 看起来是"粉紫、很淡"。
--   下面这张表就是 {a, r, g, b}，调用处照数组顺序传即可。
local HUD_MAX_ERRORS = 5
local HUD_RETRY_FRAMES = 30
local HUD_MISSION_DELAY = 300          -- 进任务后先等 ~3.5 秒再碰引擎
local HUD_CLOSE_FRAMES = 120           -- accomplish / cancel 之后后台 2 秒关 HUD
local HUD_COLORS = {
    ready = { 235, 60, 255, 90 }, deploy = { 235, 255, 205, 60 },
    accomplish = { 235, 90, 170, 255 }, cancel = { 235, 255, 80, 80 },
}

hud = {
    on = HUD_ENABLED ~= 0, frames = 0, mission_frames = 0, errors = 0, disabled = false,
    next_build_at = nil, build_why = nil, engine_why = nil, key = nil, drawn = 0,
    gui = nil, world = nil, ids = {}, Gui = nil, World = nil, App = nil,
    line1 = nil, line2 = nil,
}

hud.world_alive = function(worlds, wanted)
    if type(worlds) ~= 'table' or wanted == nil then return false end
    for _, item in pairs(worlds) do if item == wanted then return true end end
    return false
end

hud.worlds = function()
    if type(hud.App) ~= 'table' then return nil end
    local ok, worlds = pcall(hud.App.worlds)
    if ok and type(worlds) == 'table' then return worlds end
    return nil
end

hud.clear = function()
    if hud.gui and type(hud.Gui) == 'table' then
        for index = #hud.ids, 1, -1 do
            pcall(hud.Gui.destroy_text, hud.gui, hud.ids[index])
        end
    end
    hud.ids, hud.key = {}, nil
end

hud.release = function(worlds)
    if hud.gui and type(hud.World) == 'table'
        and hud.world_alive(worlds or hud.worlds(), hud.world) then
        hud.clear()
        pcall(hud.World.destroy_gui, hud.world, hud.gui)
    end
    hud.gui, hud.world, hud.ids, hud.key = nil, nil, {}, nil
end

hud.ensure = function()
    local worlds = hud.worlds()
    if not worlds then return false, 'no-worlds' end
    if hud.gui and hud.world_alive(worlds, hud.world) then return true end
    hud.release(worlds)
    local okm, main = pcall(hud.App.main_world)
    local pick
    for _, item in pairs(worlds) do if item ~= main then pick = item break end end
    pick = pick or main
    if not pick then return false, 'no-world' end
    note(string.format('HUD 准备建 GUI：worlds=%d font=%s（不读内存句柄）', #worlds, HUD_FONT),
        true)
    local okg, gui = pcall(hud.World.create_screen_gui, pick, 'scale', 1, 1)
    note('HUD create_screen_gui -> ' .. tostring(okg and 'ok' or gui), true)
    if not okg or not gui then return false, 'no-gui' end
    hud.gui, hud.world = gui, pick
    return true
end

hud.vector2 = function(x, y)
    local sr = rawget(_G, 'stingray')
    local V = (type(sr) == 'table') and sr.Vector2 or nil
    if type(V) == 'table' and type(V.new) == 'function' then
        local ok, value = pcall(V.new, x, y)
        if ok then return value end
    end
    if type(V) == 'table' or type(V) == 'function' then
        local ok, value = pcall(V, x, y)
        if ok then return value end
    end
    return nil
end

hud.draw = function(lines)
    local sr = rawget(_G, 'stingray')
    local Color = (type(sr) == 'table') and sr.Color or nil
    if type(Color) ~= 'function' then return nil, 'no-color' end
    local width, height = 1920, 1080
    local okr, w, h = pcall(hud.Gui.resolution)
    if okr and type(w) == 'number' and w > 0 then width, height = w, h end
    local size = math.max(14, math.min(22, math.floor(height / 60)))
    local top = math.floor(height * 0.06)
    for index, line in ipairs(lines) do
        local y = top + (index - 1) * math.floor(size * 1.4)
        hud.last_y = y
        if not hud.y_logged then
            hud.y_logged = true
            note(string.format('HUD 第一帧画字：screen=%dx%d top=%d 行高=%d '
                .. '（第 1 行 y=%d、第 2 行 y=%d；顺序与屏幕上下方向的对照就看这一行）',
                width, height, top, math.floor(size * 1.4), top,
                top + math.floor(size * 1.4)), true)
        end
        local measured
        local okx, lo, hi = pcall(hud.Gui.text_extents, hud.gui, line.text, HUD_FONT, size)
        if okx and lo and hi and type(sr) == 'table' and type(sr.Vector2) == 'table'
            and type(sr.Vector2.x) == 'function' then
            local ok1, low = pcall(sr.Vector2.x, lo)
            local ok2, high = pcall(sr.Vector2.x, hi)
            if ok1 and ok2 then measured = high - low end
        end
        local position = hud.vector2(measured and math.max(0, (width - measured) / 2) or 0, y)
        if not position then return nil, 'no-position' end
        -- 表里就是 {a, r, g, b}（引擎 Color 的顺序），照数组顺序传即可
        local rgba = HUD_COLORS[line.phase] or HUD_COLORS.ready
        local ok, id = pcall(hud.Gui.text, hud.gui, line.text, HUD_FONT, size, HUD_FONT,
            position, Color(rgba[1], rgba[2], rgba[3], rgba[4]))
        if not ok or id == nil then return nil, 'text-failed' end
        hud.ids[#hud.ids + 1] = id
    end
    return true
end

-- 画什么：状态机（ready/deploy 直接取），accomplish / cancel 用"后台 2 秒"的快照
hud.snapshot = function()
    local track = state.track
    if track.active and track.mark
        and (track.phase == 'ready' or track.phase == 'deploy' or track.phase == 'teleport') then
        -- 传送那一段在 HUD 上仍按 deploy 显示（用户 txt 里没有单独的状态）
        local phase = (track.phase == 'teleport') and 'deploy' or track.phase
        return phase, track.mark, (phase == 'ready') and track.window_left or nil
    end
    local last = state.hud_last
    if last and last.mark and state.frames < (last.until_frame or 0) then
        return last.phase, last.mark, nil
    end
    return 'none', nil, nil
end

hud.step = function()
    if not hud.on or hud.disabled then return end
    local sr = rawget(_G, 'stingray')
    if type(sr) ~= 'table' or type(sr.Gui) ~= 'table' or type(sr.World) ~= 'table'
        or type(sr.Application) ~= 'table' then
        if not hud.engine_why then
            hud.engine_why = 'no-engine'
            census_add(string.format('hud_no_engine frame=%d（没有 stingray.Gui/World/Application'
                .. ' → HUD 不画；主功能不受影响）', state.frames))
        end
        return
    end
    hud.Gui, hud.World, hud.App = sr.Gui, sr.World, sr.Application
    hud.frames = hud.frames + 1
    -- 闸门 1：只在任务里画（菜单/加载/切场景时 UI 资源可能还没就绪）
    if not (state.player and state.player.in_mission) then
        if hud.gui then hud.release() end
        hud.mission_frames = 0
        return
    end
    hud.mission_frames = hud.mission_frames + 1
    -- 闸门 2：进任务后先等一会儿再碰引擎
    if not hud.gui and hud.mission_frames < HUD_MISSION_DELAY then return end
    -- 闸门 3：world 没了就先清干净（而且不再对已销毁的 world 调 destroy_gui）
    local worlds = hud.worlds()
    if hud.gui and not hud.world_alive(worlds, hud.world) then
        note('HUD 所在 world 没了（切场景），清掉重来', true)
        hud.release(worlds)
    end
    if not hud.gui then
        if hud.next_build_at and hud.frames < hud.next_build_at then return end
        local built, why = hud.ensure()
        if not built then
            hud.next_build_at = hud.frames + HUD_RETRY_FRAMES
            if why ~= hud.build_why then
                hud.build_why = why
                note('HUD 暂不可用：' .. tostring(why), true)
            end
            return
        end
        hud.build_why = nil
    end
    -- 内容：阶段 + 倒计时（量化到 0.1 秒）+ XYZ。全部只读状态机。
    local phase, mark, left = hud.snapshot()
    if phase == 'none' or not mark then
        if hud.key ~= 'none' then hud.clear() end
        hud.key = 'none'
        return
    end
    local line1 = 'STATE  ' .. phase
    if phase == 'ready' and left then
        line1 = string.format('STATE  ready   %.1fs', math.floor(math.max(0, left) * 10 + 0.5) / 10)
    end
    local line2 = string.format('XYZ    %.1f   %.1f   %.1f', mark[1], mark[2], mark[3])
    local key = line1 .. '|' .. line2
    hud.line1, hud.line2 = line1, line2
    if key == hud.key then return end
    hud.clear()
    -- 行序（用户 0.1.6 要求）：**XYZ 一行画在 y 较小的一侧、STATE 在另一侧** ——
    -- 用户实测屏幕上是"XYZ 在上、STATE 在下"，所以这里把数组顺序调换成
    -- {XYZ, STATE}，让屏幕上变成 "STATE 在上、XYZ 在下"。
    -- （HUD 第一帧会往日志写一行 screen/top/行高 与两行的 y，下次对不上再翻一次即可。）
    local drawn, why = hud.draw({ { text = line2, phase = phase }, { text = line1, phase = phase } })
    if not drawn then
        hud.clear()
        error('HUD 画字失败：' .. tostring(why))
    end
    hud.key, hud.drawn = key, hud.drawn + 1
end

-- ── ④ 每一个战备的状态判定（用户要求）────────────────────────────────
-- 槽里能读到的三件事决定状态（读法照 StratagemList HUD，见 docs\17 §7）：
--   elapsed<0 → 「正在启动」（HUD 上那句正在启动）
--   remain>0  → 「冷却中」
-- 用户要的粒度：**只在状态变化时记一行**，冷却只报「冷却中 / 冷却结束」，不报秒数。
local function slot_label(slot)
    -- 优先级照 StratagemList HUD 的绘制链（docs\17 §7）：抵达 → 冷却 → 就绪
    if slot.elapsed and slot.elapsed < 0 then return '抵达中' end
    if slot.remain and slot.remain > 0 then return '冷却中' end
    return '就绪'
end

-- ── 本机玩家 ID（用户要求：靠 ID 锁定本机）──────────────────────────
-- 照 StratagemList HUD 的读法（docs\17 §7）：
--   * 本机 peer id = *( (game+0x347CEF0) + 0xB398 ) 的 8 字节；
--   * 玩家记录数组 = *(game+0x347CE50)，记录数在 +0x2D200（≤32），每条 0x1690；
--   * 每条记录 **+0 的 8 字节就是它主人的 peer id** → 与本机 peer id 相等的那条 = 本机记录。
--     （这份 HUD 的纪律：**命不中就不读槽表**，免得读到别人的战备。）
local function read_self_peer()
    local ctx = global_at(RVA.self_ctx)
    if not ctx then return nil, 'no-ctx' end
    local bytes = api.read(ctx + SELF_PEER_OFF, 8)
    if not bytes then return nil, 'no-peer' end
    local lo, hi = u32(bytes, 0), u32(bytes, 4)
    if not lo or not hi or (lo == 0 and hi == 0) then return nil, 'peer-zero' end
    return bytes, string.format('%08X%08X', hi, lo)
end
local function read_local_record()
    local arr = global_at(RVA.stratagem_slots)
    if not arr then return nil, nil, 'no-arr' end
    local peer, peer_text = read_self_peer()
    if not peer then return nil, nil, 'no-self-peer' end
    local count_bytes = api.read(arr + REC_CNT_OFF, 4)
    local count = count_bytes and u32(count_bytes, 0) or 0
    local limit = (count >= 1 and count <= REC_MAX) and count or REC_MAX
    local lo, hi = u32(peer, 0), u32(peer, 4)
    for index = 0, limit - 1 do
        local rec = arr + index * REC_STRIDE
        local head = api.read(rec, 8)
        if head and u32(head, 0) == lo and u32(head, 4) == hi then
            return rec, { index = index, count = count, peer = peer_text }, nil
        end
    end
    return nil, { count = count, peer = peer_text }, 'not-found'
end

local function read_stratagem_state(rec)
    if not rec then return nil, 'no-local-record' end
    local count_bytes = api.read(rec + REC_SLOTCNT_OFF, 4)
    local count = count_bytes and u32(count_bytes, 0) or nil
    if not count or count > REC_MAX_SLOTS then return nil, 'bad-slot-count' end
    local now_obj = deref(api.game + RVA.now_obj)
    local now
    if now_obj then
        local raw = api.read(now_obj + 0x18, 8)
        now = raw and u64(raw, 0) or nil
    end
    local slots = {}
    if count > 0 then
        local head = api.read(rec + REC_SLOT_OFF, count * REC_SLOT_STRIDE)
        if not head then return nil, 'no-slot-table' end
        local good = 0
        for index = 0, count - 1 do
            local at = index * REC_SLOT_STRIDE
            local idx = u32(head, at)
            if idx and idx ~= 0 then
                -- 闸门（照 docs\12 §12.3 的纪律）：序号要落在 1..160 的合理集合里
                if idx >= 1 and idx <= 160 then good = good + 1 end
                local end_us, base_us = u64(head, at + 0x18), u64(head, at + 0x20)
                slots[#slots + 1] = {
                    -- 用户要求：**不再记录"剩余次数"**（`uses` 不读了）
                    slot = index, idx = idx,
                    remain = (now and end_us) and (end_us - now) / 1000000 or nil,
                    elapsed = (now and base_us) and (now - base_us) / 1000000 or nil,
                    granted = (u32(head, at + 8) or 0) ~= 0,
                }
            end
        end
        if #slots ~= count or good < math.min(count, 5) then
            return nil, string.format('slot-table-implausible(count=%d slots=%d good=%d)',
                count, #slots, good)
        end
    end
    return { address = rec, count = count, slots = slots }
end

-- ── ④ 状态栏：每一个战备的状态变化（用户要求）────────────────────────
local function poll_strat()
    -- 先锁定"本机玩家记录"（靠 ID），槽表**只从本机记录读** —— 这正是 StratagemList HUD 的纪律
    local rec, meta, why_rec = read_local_record()
    if not rec then
        if state.strat_why ~= why_rec then
            state.strat_why = why_rec
            note(string.format('PLAYER 本机 ID 锁定失败（%s；本机 ID=%s，场上记录 %s 条）→ '
                .. '状态栏不读（避免读到别人的战备）', tostring(why_rec),
                tostring(meta and meta.peer), tostring(meta and meta.count)), true)
            census_add(string.format('local_record_fail frame=%d why=%s peer=%s count=%s',
                state.frames, tostring(why_rec), tostring(meta and meta.peer),
                tostring(meta and meta.count)))
        end
        return
    end
    if state.local_rec ~= rec then
        state.local_rec = rec
        state.local_meta = meta
        note(string.format('PLAYER 本机 ID=%s 记录 i=%s/%s（用 peer id 在玩家记录数组里锁定本机）',
            tostring(meta and meta.peer), tostring(meta and meta.index), tostring(meta and meta.count)),
            true)
        census_add(string.format('local_record frame=%d rec=0x%X i=%s n=%s peer=%s',
            state.frames, rec, tostring(meta and meta.index), tostring(meta and meta.count),
            tostring(meta and meta.peer)))
        -- 用户定：**不找名字了**，用账号 ID 认人（那串 ID 和 %APPDATA% 下的存档文件名一致）。
    end
    local info, why = read_stratagem_state(rec)
    if not info then
        if state.strat_why ~= why then
            state.strat_why = why
            census_add(string.format('strat_unavailable frame=%d why=%s', state.frames,
                tostring(why)))
        end
        return
    end
    state.strat_why = nil
    -- ③ 用户确认：槽表"整体换了一套"（船→任务 / 复活 / 换局）时要**重置状态表**并重报初始状态，
    --    否则新一套槽会被旧记录污染（出现"内容变了却不报"）。
    local shape = {}
    for _, slot in ipairs(info.slots) do
        shape[#shape + 1] = tostring(slot.idx)
    end
    local shape_text = table.concat(shape, ',')
    if state.strat_shape ~= shape_text then
        if state.strat_shape ~= nil then
            note(string.format('STRAT 槽表换了一套 frame=%d（战备 idx：%s → %s）→ 重新报初始状态',
                state.frames, state.strat_shape, shape_text), true)
            state.strat = {}
        end
        state.strat_shape = shape_text
    end
    for _, slot in ipairs(info.slots) do
        -- 用户确认（0.0.6）：**追踪槽表里每一个带序号的本机槽**。
        --    0.0.5 只追踪 `granted == true` 的槽；实测单人局本机槽的 granted 位读出来不是
        --    true → 状态栏一条都不报（"还是没有战备状态"的直接原因）。槽表本来就只有本机
        --    自己的战备，所以这道闸门不再看 granted（有序号就追）。
        local tracked = slot.idx ~= nil
        if tracked then
            local label = slot_label(slot)
            local previous = state.strat[slot.slot]
            if not previous then
                state.strat[slot.slot] = { label = label, idx = slot.idx }
                note(string.format('STRAT 状态变化 frame=%d 战备 idx=%d（槽 %d）：初始 → %s',
                    state.frames, slot.idx, slot.slot, label), true)
            elseif previous.label ~= label or previous.idx ~= slot.idx then
                -- 用户要的粒度：从「冷却中」出来就叫「冷却结束」，不报秒数
                local shown = label
                if previous.label == '冷却中' and label ~= '冷却中' then shown = '冷却结束' end
                if previous.idx ~= slot.idx then
                    note(string.format('STRAT 状态变化 frame=%d 槽 %d 换了战备：idx %s → %d（%s）',
                        state.frames, slot.slot, tostring(previous.idx), slot.idx, shown), true)
                else
                    note(string.format('STRAT 状态变化 frame=%d 战备 idx=%d（槽 %d）：%s → %s'
                        , state.frames, slot.idx, slot.slot, previous.label, shown), true)
                end
                census_add(string.format('strat_change frame=%d slot=%d idx=%d %s->%s',
                    state.frames, slot.slot, slot.idx, previous.label, shown))
                previous.label, previous.idx = label, slot.idx
            end
        end
    end
end

local function poll_pings()
    local table_ok, why, found = read_pings()
    if not table_ok then
        census_add(string.format('ping_fail frame=%d why=%s', state.frames, tostring(why)))
        return
    end
    for _, ping in ipairs(found or {}) do
        state.counts.pings = state.counts.pings + 1
        local mine, evidence = ping_is_mine(ping)
        if ping.new_mark then
            -- 这条标记"第一次被看到"的帧 —— 状态机用它判"是不是球创建之后才标的点"
            state.ping_first[ping.slot] = state.frames
        end
        -- v0.0.2（优化/降噪）：同一条标记"在动"时不再每轮刷一行（0.0.1 一局 1292 行 PING、
        -- 单槽最多 124 行，全是信标标记在漂）。现在：换了一条新标记立刻记；同一条每 120 帧最多一次。
        local due = ping.new_mark
            or (state.frames - (state.ping_log_at[ping.slot] or -99999)) >= 120
        if due then
            state.ping_log_at[ping.slot] = state.frames
            note(string.format('PING %s frame=%d slot=%d kind=%d owner=%s 本机=%s（%s）'
                .. ' xyz=%s life=%.1f elapsed=%.2f',
                ping.new_mark and '新标记' or '位置更新', state.frames,
                ping.slot, ping.kind, tostring(ping.owner), mine and '是' or '否', evidence,
                xyz_text({ ping.x, ping.y, ping.z }), ping.lifetime or -1, ping.elapsed or -1),
                ping.new_mark)
        end
        if ping.new_mark then
            census_add(string.format('ping_new frame=%d slot=%d kind=%d owner=%s mine=%s xyz=%s',
                state.frames, ping.slot, ping.kind, tostring(ping.owner), tostring(mine),
                xyz_text({ ping.x, ping.y, ping.z })))
        end
        track_mark(ping, mine)
        learn_owner(ping)
    end
end

-- ── ③ 战备球：创建 / 销毁 ─────────────────────────────────────────────
-- 0.1.0（切片 1）：**逐帧判**。原来每 6 帧才枚举一次注册表，"发现球创建"最多晚 6 帧；
-- 而用户实测一次点击（按下→松开）只有 7~11 帧，晚这 6 帧就会漏掉"松开射击键"。
-- 现在每帧只读注册表头 20 B + 槽表 capacity×8（≈150 B），**和上一帧的字节比**；
-- 变了才做一次完整枚举（记创建/销毁、刷位置）。位置照旧每 SLOW_POLL 帧刷一次。
local function throwable_probe()
    local registry = global_at(RVA.throwable_reg)
    if not registry then return nil, nil, 'no-throwable-registry' end
    local head = api.read(registry + OFF.throwable_map, 20)
    if not head then return nil, nil, 'no-throwable-map' end
    local capacity, empty = u32(head, OFF.map_capacity), u32(head, OFF.map_empty)
    local table_at = u64(head, 0)
    if not capacity or not empty or not table_at or capacity == 0 or capacity > 4096 then
        return nil, nil, 'throwable-map-layout'
    end
    local slots = api.read(table_at, capacity * 8)
    if not slots then return nil, nil, 'no-throwable-slots' end
    return slots, registry, nil
end

local function refresh_balls()
    local registry, why = read_throwables()
    if not registry then
        census_add(string.format('throwable_fail frame=%d why=%s', state.frames, tostring(why)))
        return
    end
    local live, newest = {}, nil
    for _, entry in ipairs(registry.entries) do
        live[entry.entity_id] = true
        if not state.balls[entry.entity_id] then
            entry.created = state.frames
            state.counts.balls = state.counts.balls + 1
            state.counts.created = state.counts.created + 1
            local is_ball = entry.hash == STRATAGEM_BALL_LE
            -- v0.0.2：**归属结论直接写在"创建"这一行里**（0.0.1 把它单独放一行"归属核对"，
            -- 用户说在日志里找不到 —— 合并掉，并把 owned 位写成一眼能看懂的结论）。
            entry.mine = entry.owned == true
            note(string.format('BALL 创建 #%d frame=%d entity=0x%X 归属=%s（entity 记录的 '
                .. 'owned 位=%s）unit=%s goid=%s 单位哈希=%s（%s）',
                state.counts.balls, state.frames, entry.entity_id,
                entry.mine and '本机' or '不是本机', tostring(entry.owned),
                tostring(entry.unit_ref), tostring(entry.goid), tostring(entry.hash),
                is_ball and '战备球' or '不是战备球'), true)
            census_add(string.format('ball_create frame=%d entity=0x%X unit=%s goid=%s hash=%s owned=%s',
                state.frames, entry.entity_id, tostring(entry.unit_ref), tostring(entry.goid),
                tostring(entry.hash), tostring(entry.owned)))
            -- 状态机入口：本机战备球创建 → 开始跟踪标点（手雷/别人的球不开追踪）
            if is_ball and entry.mine then
                if state.track.phase == 'deploy' or state.track.phase == 'teleport' then
                    -- 切片 4/6（用户 txt）："记录最后的本机战备球索引，**后面出现新的战备球也不更新**"
                    census_add(string.format('ball_ignored_deploy frame=%d entity=0x%X'
                        .. '（本轮目标已锁定，不换）', state.frames, entry.entity_id))
                else
                    track_begin(entry.entity_id)
                end
            end
        end
        state.balls[entry.entity_id] = state.balls[entry.entity_id] or entry
        state.balls[entry.entity_id].position = entry.position
        state.balls[entry.entity_id].fuse_pick = entry.fuse_pick
        state.balls[entry.entity_id].fuse_count = entry.fuse_count
        if not newest or entry.entity_id > newest then newest = entry.entity_id end
    end
    for id, entry in pairs(state.balls) do
        if not live[id] then
            state.counts.destroyed = state.counts.destroyed + 1
            note(string.format('BALL 销毁 frame=%d entity=0x%X 归属=%s 存活 %d 帧 最后坐标=%s',
                state.frames, id, entry.mine and '本机' or '不是本机',
                state.frames - (entry.created or state.frames), xyz_text(entry.position)), true)
            census_add(string.format('ball_destroy frame=%d entity=0x%X alive=%d',
                state.frames, id, state.frames - (entry.created or state.frames)))
            if state.track.active and state.track.ball == id then
                track_end('战备球销毁')
            end
            state.balls[id] = nil
        end
    end
end

local function poll_ball_presence()
    local slots, registry, why = throwable_probe()
    if not slots then
        if state.throw_why ~= why then
            state.throw_why = why
            census_add(string.format('throwable_probe_fail frame=%d why=%s', state.frames,
                tostring(why)))
        end
        return
    end
    state.throw_why = nil
    if registry == state.throw_reg and slots == state.throw_slots then return end
    state.throw_reg, state.throw_slots = registry, slots
    refresh_balls()
end

-- ── 主循环 ───────────────────────────────────────────────────────────
local function advance(dt)
    state.frames = state.frames + 1
    if state.frames < FRAME_START then return end
    -- dt 累加"真实秒"（3 秒窗口用它；游戏帧率不是恒定 60，按帧算会漂）。
    -- 夹一下范围：读到 nil/异常值就用 1/60，单帧最长只算 0.25 秒（避免卡顿时把窗口一刀切光）。
    local dt_secs = tonumber(dt)
    if not dt_secs or dt_secs <= 0 then dt_secs = 1 / 60 end
    if dt_secs > 0.25 then dt_secs = 0.25 end
    state.seconds = state.seconds + dt_secs
    if not api.ok then
        if bind() then
            note(string.format('内核就绪：game=0x%X exe=0x%X', api.game, api.exe), true)
            census_add(string.format('modules frame=%d game=0x%X exe=0x%X（偏移来自 HD2 HUD+ 0.1.12 '
                .. '那一版构建；0.0.1 不记 SHA-256）', state.frames, api.game, api.exe))
            write_status('STARTING - 已装载：本机玩家 / 战备球（逐帧）/ 状态机 / HUD / 传送'
                .. '（只在传送那一段写内存）')
        else
            if state.frames % 120 == 0 then
                note('绑不上内核（' .. tostring(api.error) .. '），继续等', true)
            end
            return
        end
    end
    if not state.started then
        state.started = true
        local ok, problem = pcall(load_input_config)
        if not ok then note('读按键配置文件出错：' .. tostring(problem), true) end
    end
    local okk, problemk = pcall(poll_fire_watch)         -- 切片 3：射击键窗口
    if not okk then state.errors = state.errors + 1; note('poll_fire_watch: ' .. tostring(problemk)) end
    local okb, problemb = pcall(poll_ball_presence)      -- 切片 1：逐帧判球
    if not okb then state.errors = state.errors + 1; note('poll_ball_presence: ' .. tostring(problemb)) end
    local okt, problemt = pcall(track_tick, dt_secs)     -- 切片 2：3 秒窗口倒计时
    if not okt then state.errors = state.errors + 1; note('track_tick: ' .. tostring(problemt)) end
    local okp, problemp = pcall(track_deploy)            -- 切片 4/6：deploy → 立刻开始传送（无延迟）
    if not okp then state.errors = state.errors + 1; note('track_deploy: ' .. tostring(problemp)) end
    local okps, problemps = pcall(prescan_step)          -- 0.1.14：球在手里时每 10 帧预扫一次
    if not okps then state.errors = state.errors + 1; note('prescan_step: ' .. tostring(problemps)) end
    local oktp, problemtp = pcall(teleport_step)         -- 切片 6：传送（唯一写内存的地方）
    if not oktp then
        state.errors = state.errors + 1
        note('teleport_step: ' .. tostring(problemtp))
    end
    local okh, problemh = pcall(hud.step)                -- 切片 5：HUD（出错只影响显示）
    if not okh then
        hud.errors = hud.errors + 1
        note('HUD 这一帧出错：' .. tostring(problemh), true)
        if hud.errors >= HUD_MAX_ERRORS then
            hud.disabled = true
            pcall(hud.release)
            note(string.format('HUD 连续出错 %d 次，本次会话停手（主功能不受影响）', hud.errors),
                true)
        end
    end
    -- 0.1.8：标点表单独走 PING_EVERY（3 帧）—— 发现标点更快，其余巡检仍是 SLOW_POLL（6 帧）
    if state.frames % PING_EVERY == 0 then
        local okp2, problemp2 = pcall(poll_pings)
        if not okp2 then state.errors = state.errors + 1; note('poll_pings: ' .. tostring(problemp2)) end
    end
    if state.frames % SLOW_POLL == 0 then
        local ok0, problem0 = pcall(poll_strat)
        if not ok0 then state.errors = state.errors + 1; note('poll_strat: ' .. tostring(problem0)) end
        local ok1, problem1 = pcall(poll_player)
        if not ok1 then state.errors = state.errors + 1; note('poll_player: ' .. tostring(problem1)) end
        local ok3, problem3 = pcall(refresh_balls)
        if not ok3 then state.errors = state.errors + 1; note('refresh_balls: ' .. tostring(problem3)) end
        state.scan_count = state.scan_count + 1
        if state.scan_count == 1 then
            write_status(string.format(
                'OK - 在跑：本机玩家 %s、场上球 %d 颗、标点 %d 条、状态机 %s',
                state.me.entity and string.format('entity=0x%X', state.me.entity) or '(等待识别)',
                state.counts.balls, state.counts.pings,
                state.track.active and '跟踪中' or '待命'))
        end
    end
    if state.frames % FLUSH_EVERY == 0 then
        flush_logs()
        state.scan_count = state.scan_count
    end
end

local original_update = rawget(_G, 'update')
local original_shutdown = rawget(_G, 'shutdown')
local retired = false
local function describe()
    return string.format('OK - 侦察 + 传送结束：球创建 %d / 销毁 %d / 现存 %d、标点 %d 条、'
        .. '状态机 %d 步、传送写入 %d 处、本机玩家 %s、自学 owner=%s、错误 %d',
        state.counts.created, state.counts.destroyed, state.counts.balls, state.counts.pings,
        state.counts.steps, state.teleport_written or 0,
        state.me.entity and string.format('entity=0x%X', state.me.entity)
        or '(未识别)', tostring(state.my_owner), state.errors)
end
local function my_update(dt, ...)
    local ok, problem = pcall(advance, dt)
    if not ok then
        state.errors = state.errors + 1
        note('advance 出错：' .. tostring(problem))
    end
    if original_update then return original_update(dt, ...) end
end
local function my_shutdown(...)
    retired = true
    if rawget(_G, 'update') == my_update then rawset(_G, 'update', original_update) end
    pcall(function() hud.release() end)                  -- 切片 5：退出时先把 GUI 清干净
    if state.frames >= FRAME_START then
        state.phase = 'stopped'
        write_status(describe())
    else
        write_status('NOT_FOUND - 还没跑到第 ' .. FRAME_START .. ' 帧就退出了')
    end
    flush_logs()
    if original_shutdown then return original_shutdown(...) end
end
if api_ok and type(original_update) == 'function' then
    rawset(_G, 'update', my_update)
    rawset(_G, 'shutdown', my_shutdown)
else
    write_status('FAILED - Loader API 不满足（需要 Bingus Shared Loader v15+ / API 1）')
end
write_status('STARTING - 已装载，等游戏跑到第 ' .. FRAME_START .. ' 帧')

MOD.api = { version = MOD.revision, state = state }
rawset(_G, MOD.key, MOD)
return MOD
