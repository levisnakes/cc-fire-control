-- Fire Control: CC decides when Big Cannons on a Sable ship fire.
--
-- Create Radar does the aiming (Network Controller + Target Filter + Auto
-- Yaw/Pitch Controllers). This computer only pulls the trigger. Several times
-- a second it flies an imaginary shell from where each barrel points right now
-- (Big Cannons physics, your ship's speed included) and:
--   * never fires if that shell would pass through your own ship
--   * fires if it would pass within HIT_RADIUS of a radar target
--
-- Keys: A arm/safe   X ignore the nearest target for good (part of your ship)
--       U un-ignore all   F fire every cannon that's clear of your own ship now
-- Parts of your ship on their own sublevels (swivel/physics bearings) are found
-- by themselves: they stay put relative to your ship while it moves or turns.

AUTOCANNON = true         -- true: hold the trigger while on target. false: big cannons, one shot per RELOAD
SHOT_SPEED = 9            -- blocks/tick, the most your rounds can do (learning never goes above it).
                          --   Autocannon: steel/cast iron with full barrels 9, bronze 7.5
                          --   (big cannon: 2 per Powder Charge)
AUTO_SPEED = true          -- learn the real round speed from how the radar aims (SHOT_SPEED is the first guess)
SHOT_LIFETIME = 60        -- ticks before an autocannon round vanishes: steel 60, bronze 25, cast iron 11
SHOT_GRAVITY = -0.025     -- autocannon rounds -0.025, big cannon shells -0.05
SHOT_DRAG = 0.01
BARREL_LENGTH = 3         -- blocks from the mount to the muzzle
HIT_RADIUS = 5            -- fire when the shot would pass this close to a target (blocks)
OWN_CLEARANCE = 8         -- never fire if it would pass this close to a part of your own ship
RELOAD = 6                -- big cannons only: seconds between shots of one cannon
STAGGER = 0.75            -- big cannons only: seconds between any two shots
MAX_ROCK = 8              -- hold fire while the ship turns/rocks faster than this (deg/s)
MAX_RANGE = 400
MIN_RANGE = 20
TARGETS = { SABLE = true, PLAYER = false, HOSTILE = false, MOB = false, ANIMAL = false }
OWN_SHIP_RADIUS = 20      -- radar contacts this close to your ship's center are your ship
TRACK_MEMORY = 15         -- seconds a contact is still followed after the radar last swept it
SIDES = {                 -- which cannons are on which side (names as on the screen)
  left = { "cannon_mount_4", "cannon_mount_5" },
  right = { "cannon_mount_2", "cannon_mount_3" },
}
ARC = 160                 -- a cannon only fires outward: within this arc around its side of the ship
ARCS = {}                 -- per cannon, e.g. ARCS["cannon_mount_0"] = { center = 90, width = 120 }
YAW_OFFSET = 0            -- calibration if the program thinks the barrels point the wrong way
PITCH_SIGN = 1
MOUNT_UP = true           -- false if the mounts hang upside down
AUTO_UPDATE = true

if fs and fs.exists("/config.lua") then
  local f, err = loadfile("/config.lua", nil, _ENV)
  if not f then error("/config.lua: " .. err, 0) end
  f()
end

-- ============================================================ math

VERSION = "1.5.0"
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local sin, cos, sqrt, abs, deg, rad = math.sin, math.cos, math.sqrt, math.abs, math.deg, math.rad
local LOOP = 0.1
local MAX_TICKS = 300

local function now() return os.clock() end
local function wrap(a) return (a + 180) % 360 - 180 end
local function len(v) return sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end

local function qrot(q, v)
  local tx = 2 * (q.y * v.z - q.z * v.y)
  local ty = 2 * (q.z * v.x - q.x * v.z)
  local tz = 2 * (q.x * v.y - q.y * v.x)
  return { x = v.x + q.w * tx + (q.y * tz - q.z * ty),
           y = v.y + q.w * ty + (q.z * tx - q.x * tz),
           z = v.z + q.w * tz + (q.x * ty - q.y * tx) }
end
local function qinv(q) return { x = -q.x, y = -q.y, z = -q.z, w = q.w } end
local function qmul(a, b)
  return { w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
           x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
           y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
           z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w }
end

-- Minecraft yaw: 0 = +Z (south), 90 = -X (west)
local function yawOf(v) return deg(atan2(-v.x, v.z)) end
local function dirOf(yaw, pitch)
  local y, p = rad(yaw), rad(pitch)
  return { x = -sin(y) * cos(p), y = sin(p), z = cos(y) * cos(p) }
end

local function vec(t)
  if type(t) ~= "table" then return nil end
  local x, y, z = tonumber(t.x), tonumber(t.y), tonumber(t.z)
  if not (x and y and z) then return nil end
  return { x = x, y = y, z = z }
end

-- ============================================================ hardware

if not (sublevel and sublevel.isInPlotGrid and sublevel.isInPlotGrid()) then
  printError("This computer isn't on a Sable ship (needs CC: Sable).")
  return
end

local shipId = nil
do
  local ok, id = pcall(sublevel.getUniqueId)
  if ok and id then shipId = tostring(id) end
end

local mounts, radar, fireControllers = {}, nil, 0

local function hasMethod(name, m)
  for _, x in ipairs(peripheral.getMethods(name) or {}) do
    if x == m then return true end
  end
  return false
end

local function findHardware()
  local seen, list = {}, {}
  for _, n in ipairs(peripheral.getNames()) do
    if not seen[n] then
      seen[n] = true
      list[#list + 1] = n
    end
  end
  local old = {}
  for _, m in ipairs(mounts) do old[m.name] = m end
  mounts, radar, fireControllers = {}, nil, 0
  for _, n in ipairs(list) do
    local t = peripheral.getType(n)
    if t == "cannon_mount" then
      mounts[#mounts + 1] = old[n] or { name = n, lastShot = -999, state = "starting" }
    elseif t and t:find("fire_controller", 1, true) then
      fireControllers = fireControllers + 1
    elseif hasMethod(n, "getTracks") and hasMethod(n, "getRange") and not hasMethod(n, "getSelectedTrack") then
      radar = radar or n
    end
  end
  table.sort(mounts, function(a, b) return a.name < b.name end)
end

-- ============================================================ ship pose

local pose = nil
local shipVel = { x = 0, y = 0, z = 0 }  -- blocks/tick
local rock = 0                           -- deg/s
-- Sable velocities are blocks per second or per tick; learned by comparing
-- the reported velocity with how far the ship really moves.
local velScale = nil
local velVotes = { [1] = 0, [20] = 0 }

local function readPose()
  local ok, p = pcall(sublevel.getLogicalPose)
  if not ok or type(p) ~= "table" or not p.position then return false end
  local o = p.orientation or {}
  local q = { x = o.x or 0, y = o.y or 0, z = o.z or 0, w = o.w or 1 }
  local t = now()
  if pose and t > pose.t then
    local dt = (t - pose.t) * 20
    local moved = { x = (p.position.x - pose.pos.x) / dt, y = (p.position.y - pose.pos.y) / dt, z = (p.position.z - pose.pos.z) / dt }
    local okV, api = pcall(sublevel.getLinearVelocity)
    api = okV and vec(api) or nil
    if api and not velScale and len(moved) > 0.05 then
      local r = len(api) / len(moved)
      for _, k in ipairs({ 1, 20 }) do
        if r > k * 0.7 and r < k * 1.3 then
          velVotes[k] = velVotes[k] + 1
          if velVotes[k] >= 5 then velScale = k end
        end
      end
    end
    if api and velScale then
      shipVel = { x = api.x / velScale, y = api.y / velScale, z = api.z / velScale }
    else
      local a = 0.5
      shipVel = { x = shipVel.x * (1 - a) + moved.x * a, y = shipVel.y * (1 - a) + moved.y * a, z = shipVel.z * (1 - a) + moved.z * a }
    end
    local dq = qmul(q, qinv(pose.q))
    local w = math.min(1, abs(dq.w))
    rock = rock * 0.5 + deg(2 * math.acos(w)) / (t - pose.t) * 0.5
  end
  pose = { pos = p.position, q = q, rp = p.rotationPoint or p.position, scale = p.scale or { x = 1, y = 1, z = 1 }, t = t }
  return true
end

local function toWorld(lp)
  local s = pose.scale
  local r = qrot(pose.q, { x = (lp.x - pose.rp.x) * (s.x or 1), y = (lp.y - pose.rp.y) * (s.y or 1), z = (lp.z - pose.rp.z) * (s.z or 1) })
  return { x = r.x + pose.pos.x, y = r.y + pose.pos.y, z = r.z + pose.pos.z }
end

-- ============================================================ radar contacts

local seen = {}         -- id -> contact
local targets = {}      -- contacts to shoot at, nearest first
local ownParts = {}     -- contacts that are part of your ship (never shoot through them)
local radarError = nil
local IGNORE_FILE = "/firecontrol_ignore"
local ignored = {}
local scanUnit, scanOffset = nil, nil

do
  if fs.exists(IGNORE_FILE) then
    local f = fs.open(IGNORE_FILE, "r")
    local t = textutils.unserialize(f.readAll())
    f.close()
    if type(t) == "table" then ignored = t end
  end
end

local function saveIgnored()
  local f = fs.open(IGNORE_FILE, "w")
  f.write(textutils.serialize(ignored))
  f.close()
end

local function scanTicks(st) return st / scanUnit end

-- velocity in blocks/tick: the radar's own reading if it has one
local function contactVel(s)
  if s.rv then
    local k = 1
    if s.cat == "SABLE" then
      k = velScale
      if not k then
        local m, r = len(s.v), len(s.rv)
        if (s.vn or 0) >= 1 and m > 0.02 and abs(r / 20 - m) > abs(r - m) then k = 1 else k = 20 end
      end
    end
    return { x = s.rv.x / k, y = s.rv.y / k, z = s.rv.z / k }
  end
  return s.v
end

-- where a contact will be `ahead` ticks from now, following its turn
local function contactPos(s, ahead)
  local age = now() - s.t
  if scanUnit and s.st and scanOffset then age = (now() * 20 - (scanTicks(s.st) + scanOffset)) / 20 end
  local a = math.max(0, math.min(age, TRACK_MEMORY)) * 20 + (ahead or 0)
  local v = contactVel(s)
  local w = s.turn or 0
  local dx, dz
  if abs(w) < 1e-5 then
    dx, dz = v.x * a, v.z * a
  else
    local sn, cs = sin(w * a) / w, (1 - cos(w * a)) / w
    dx = sn * v.x - cs * v.z
    dz = sn * v.z + cs * v.x
  end
  return { x = s.p.x + dx, y = s.p.y + v.y * a, z = s.p.z + dz }
end

local function update(s, tr, t)
  local p = tr.position
  local st = tonumber(tr.scannedTime)
  if p.x ~= s.p.x or p.y ~= s.p.y or p.z ~= s.p.z then
    local dt = (t - s.t) * 20
    if st and s.st and st > s.st then
      if not scanUnit and dt > 0 then
        local r = (st - s.st) / dt
        if r > 0.5 and r < 2 then scanUnit = 1 elseif r > 25 and r < 100 then scanUnit = 50 end
      end
      if scanUnit then dt = scanTicks(st - s.st) end
    end
    if scanUnit and st then
      local off = t * 20 - scanTicks(st)
      if not scanOffset or off < scanOffset then scanOffset = off end
    end
    s.st = st
    if dt > 0 then
      s.vn = (s.vn or 0) + 1
      local a = 0.6
      s.v = { x = s.v.x * (1 - a) + (p.x - s.p.x) / dt * a,
              y = s.v.y * (1 - a) + (p.y - s.p.y) / dt * a,
              z = s.v.z * (1 - a) + (p.z - s.p.z) / dt * a }
    end
    s.p, s.t = p, t
    -- bolted to us? same spot in our ship's frame while our ship moved/turned
    local rel = qrot(qinv(pose.q), { x = p.x - pose.pos.x, y = p.y - pose.pos.y, z = p.z - pose.pos.z })
    if s.lp then
      local shipMoved = len({ x = pose.pos.x - s.lpPos.x, y = pose.pos.y - s.lpPos.y, z = pose.pos.z - s.lpPos.z })
      local dq = qmul(pose.q, qinv(s.lpQ))
      local turned = deg(2 * math.acos(math.min(1, abs(dq.w))))
      local drift = len({ x = rel.x - s.lp.x, y = rel.y - s.lp.y, z = rel.z - s.lp.z })
      if (shipMoved > 4 or turned > 5) and drift < 2 + 0.25 * shipMoved then
        s.rigid = (s.rigid or 0) + 1
      elseif drift > 4 + 0.25 * shipMoved then
        s.rigid = 0
      end
    end
    s.lp, s.lpPos, s.lpQ = rel, pose.pos, pose.q
    local rv = vec(tr.velocity)
    if rv then
      local tick = (scanUnit and s.st and scanTicks(s.st)) or s.t * 20
      if s.rv and s.rvTick and tick > s.rvTick then
        local a, b = s.rv, rv
        local sa, sb = sqrt(a.x * a.x + a.z * a.z), sqrt(b.x * b.x + b.z * b.z)
        if sa > 0 and sb > 0 and sa > 0.05 * sb then
          local w = atan2(a.x * b.z - a.z * b.x, a.x * b.x + a.z * b.z) / (tick - s.rvTick)
          local cap = rad(30) / 20
          if w > cap then w = cap elseif w < -cap then w = -cap end
          s.turn = (s.turn or 0) * 0.4 + w * 0.6
        end
      end
      s.rv, s.rvTick = rv, tick
    end
  end
end

local function scan()
  if not radar then
    targets, ownParts = {}, {}
    return
  end
  local ok, list = pcall(peripheral.call, radar, "getTracks")
  if not ok or type(list) ~= "table" then
    radarError = tostring(list)
    return
  end
  radarError = nil
  local t = now()
  for _, tr in pairs(list) do
    if type(tr) == "table" and vec(tr.position) and tr.id ~= nil then
      local id = tostring(tr.id)
      local s = seen[id]
      tr.position = vec(tr.position)
      if not s then
        s = { id = id, p = tr.position, t = t, v = { x = 0, y = 0, z = 0 }, st = tonumber(tr.scannedTime), rv = vec(tr.velocity) }
        seen[id] = s
      else
        update(s, tr, t)
      end
      s.seenAt = t
      s.cat = tostring(tr.category)
      s.kind = tostring(tr.entityType or "")
    end
  end
  targets, ownParts = {}, {}
  for id, s in pairs(seen) do
    if t - s.seenAt > TRACK_MEMORY then
      seen[id] = nil
    elseif id ~= shipId then
      local p = contactPos(s)
      local d = len({ x = p.x - pose.pos.x, y = p.y - pose.pos.y, z = p.z - pose.pos.z })
      s.d = d
      if ignored[id] or (s.cat == "SABLE" and (d < OWN_SHIP_RADIUS or (s.rigid or 0) >= 2)) then
        ownParts[#ownParts + 1] = s
      elseif TARGETS[s.cat] and d >= MIN_RANGE and d <= MAX_RANGE then
        targets[#targets + 1] = s
      end
    end
  end
  table.sort(targets, function(a, b) return a.d < b.d end)
end

-- ============================================================ fire decision

local armed = false
local lastAnyShot = -999
local forceFire = false
local forceUntil = nil
local SPEED_FILE = "/firecontrol_speed"
local speed = SHOT_SPEED
local speedLearned = false
local speedSamples = {}
local lastLearn, learnIndex, learner = -999, 0, nil
if AUTO_SPEED and fs.exists(SPEED_FILE) then
  local f = fs.open(SPEED_FILE, "r")
  local v = tonumber(f.readAll())
  f.close()
  if v and v > 0 then speed, speedLearned = v, true end
end

-- Which side of the ship each cannon is on. The cannons are spread along the
-- ship's length (two per side), so that's the long axis; each cannon's side
-- is the way it sits off the line down the middle of them.
local function sideOf(name)
  for side, list in pairs(SIDES or {}) do
    for _, n in ipairs(list) do
      if n == name then return side end
    end
  end
end

-- From SIDES: "left" points from the right-hand cannons to the left-hand ones.
local function sidesArc(m)
  local side = sideOf(m.name)
  if side ~= "left" and side ~= "right" then return nil end
  local sum = { left = { x = 0, z = 0, n = 0 }, right = { x = 0, z = 0, n = 0 } }
  for _, k in ipairs(mounts) do
    local sd = sideOf(k.name)
    if k.localPos and sum[sd] then
      sum[sd].x, sum[sd].z, sum[sd].n = sum[sd].x + k.localPos.x, sum[sd].z + k.localPos.z, sum[sd].n + 1
    end
  end
  if sum.left.n == 0 or sum.right.n == 0 then return nil end
  local dx = sum.left.x / sum.left.n - sum.right.x / sum.right.n
  local dz = sum.left.z / sum.left.n - sum.right.z / sum.right.n
  if abs(dx) + abs(dz) < 0.5 then return nil end
  if side == "right" then dx, dz = -dx, -dz end
  return yawOf({ x = dx, y = 0, z = dz })
end

local function arcFor(m)
  local o = ARCS[m.name]
  if o then return o.center or 0, o.width or ARC end
  local c = sidesArc(m)
  if c then return c, ARC end
  local n, mx, mz = 0, 0, 0
  for _, k in ipairs(mounts) do
    if k.localPos then n, mx, mz = n + 1, mx + k.localPos.x, mz + k.localPos.z end
  end
  mx, mz = mx / n, mz / n
  local sx, sz = 0, 0
  for _, k in ipairs(mounts) do
    if k.localPos then sx, sz = sx + abs(k.localPos.x - mx), sz + abs(k.localPos.z - mz) end
  end
  local rx, rz = m.localPos.x - mx, m.localPos.z - mz
  local side
  if n >= 2 and sz >= sx and abs(rx) > 0.5 then
    side = { x = rx > 0 and 1 or -1, y = 0, z = 0 }
  elseif n >= 2 and sx > sz and abs(rz) > 0.5 then
    side = { x = 0, y = 0, z = rz > 0 and 1 or -1 }
  else
    -- one cannon, or one on the center line: outward from the ship's center
    local cx, cz = m.localPos.x - pose.rp.x, m.localPos.z - pose.rp.z
    if abs(cx) < 0.5 and abs(cz) < 0.5 then return 0, 360 end
    side = { x = cx, y = 0, z = cz }
  end
  return yawOf(side), ARC
end

-- Closest distance between the shell and a contact during one tick, both
-- moving in a straight line over that tick (a shell covers ~8 blocks a tick,
-- so checking only the tick ends could step right past a target).
local function closest(a0, a1, b0, b1)
  local rx, ry, rz = a0.x - b0.x, a0.y - b0.y, a0.z - b0.z
  local dx, dy, dz = (a1.x - b1.x) - rx, (a1.y - b1.y) - ry, (a1.z - b1.z) - rz
  local dd = dx * dx + dy * dy + dz * dz
  local u = 0
  if dd > 0 then u = math.max(0, math.min(1, -(rx * dx + ry * dy + rz * dz) / dd)) end
  local x, y, z = rx + dx * u, ry + dy * u, rz + dz * u
  return sqrt(x * x + y * y + z * z), y
end

-- Fly a shell from the barrel as it points now. Returns the closest target
-- (contact, miss distance, shell height minus target height there) or the
-- part of your own ship it would hit.
local function predictShot(m, dir, spd)
  spd = spd or speed
  local pos = { x = m.world.x + dir.x * BARREL_LENGTH, y = m.world.y + dir.y * BARREL_LENGTH, z = m.world.z + dir.z * BARREL_LENGTH }
  local v = { x = dir.x * spd + shipVel.x, y = dir.y * spd + shipVel.y, z = dir.z * spd + shipVel.z }
  local best, bestMiss, bestDy = nil, math.huge, 0
  local far = MAX_RANGE + 50
  local prevOwn, prevTgt = {}, {}
  for i, s in ipairs(ownParts) do prevOwn[i] = contactPos(s, 0) end
  for i, s in ipairs(targets) do prevTgt[i] = contactPos(s, 0) end
  local ticks = MAX_TICKS
  if AUTOCANNON then ticks = math.min(ticks, SHOT_LIFETIME) end
  for t = 1, ticks do
    local fx, fy, fz = -v.x * SHOT_DRAG, -v.y * SHOT_DRAG + SHOT_GRAVITY, -v.z * SHOT_DRAG
    local last = pos
    pos = { x = pos.x + v.x + fx / 2, y = pos.y + v.y + fy / 2, z = pos.z + v.z + fz / 2 }
    v = { x = v.x + fx, y = v.y + fy, z = v.z + fz }
    for i, s in ipairs(ownParts) do
      local p = contactPos(s, t)
      if closest(last, pos, prevOwn[i], p) < OWN_CLEARANCE then return nil, nil, nil, s end
      prevOwn[i] = p
    end
    for i, s in ipairs(targets) do
      local p = contactPos(s, t)
      local d, dy = closest(last, pos, prevTgt[i], p)
      if d < bestMiss then best, bestMiss, bestDy = s, d, dy end
      prevTgt[i] = p
    end
    if len({ x = pos.x - m.world.x, y = pos.y - m.world.y, z = pos.z - m.world.z }) > far then break end
  end
  return best, bestMiss, bestDy, nil
end

local function readMount(m)
  local ok, info = pcall(peripheral.call, m.name, "getInfo")
  if ok and type(info) == "table" then m.info = info else m.info = nil end
end

-- The radar aims with the real round speed, so the speed at which the
-- barrel's current aim would hit the target is the real one. Each sample
-- finds that speed; once several agree it's used (and saved).
local function learnSpeed(m, dir)
  local function missAt(sp)
    local tgt, miss = predictShot(m, dir, sp)
    if not tgt then return math.huge end
    return miss
  end
  -- never above SHOT_SPEED: a target out of reach would otherwise "teach"
  -- an impossible speed that reaches it
  local a, b = 1.5, SHOT_SPEED * 1.05
  local g = (sqrt(5) - 1) / 2
  local c, d = b - g * (b - a), a + g * (b - a)
  local fc, fd = missAt(c), missAt(d)
  for _ = 1, 14 do
    if fc < fd then
      b, d, fd = d, c, fc
      c = b - g * (b - a)
      fc = missAt(c)
    else
      a, c, fc = c, d, fd
      d = a + g * (b - a)
      fd = missAt(d)
    end
  end
  local best = (a + b) / 2
  if missAt(best) > HIT_RADIUS * 0.6 then return end   -- not lined up with anything
  speedSamples[#speedSamples + 1] = best
  if #speedSamples > 9 then table.remove(speedSamples, 1) end
  if #speedSamples < 5 then return end
  local sorted = {}
  for i, v in ipairs(speedSamples) do sorted[i] = v end
  table.sort(sorted)
  local med = sorted[math.ceil(#sorted / 2)]
  local agree = 0
  for _, v in ipairs(sorted) do
    if abs(v - med) <= med * 0.08 then agree = agree + 1 end
  end
  if agree >= 5 and (not speedLearned or abs(med - speed) > 0.05) then
    speed, speedLearned = med, true
    local f = fs.open(SPEED_FILE, "w")
    f.write(string.format("%.2f", speed))
    f.close()
  end
end

-- Autocannons fire while the trigger is held; big cannons get one pulse.
local function setTrigger(m, on)
  if m.trigger ~= on then
    local ok, err = pcall(peripheral.call, m.name, "fire", on)
    m.fireErr = (not ok) and tostring(err) or nil
    m.trigger = on
    m.triggerAt = now()
  elseif on and now() - (m.triggerAt or 0) > 1 then
    pcall(peripheral.call, m.name, "fire", true)   -- re-assert now and then
    m.triggerAt = now()
  end
end

local function holdFire(m, state)
  setTrigger(m, false)
  m.state = state
end

local function checkMount(m)
  if not AUTOCANNON and m.trigger then setTrigger(m, false) end
  m.miss, m.dy, m.target = nil, nil, nil
  local info = m.info
  if not info then return holdFire(m, "no reply") end
  -- the radar's controllers aim; computer control would lock them out
  if info.computerControl then pcall(peripheral.call, m.name, "setComputerControl", false) end
  if not info.assembled then return holdFire(m, "not assembled") end
  m.localPos = { x = info.x + 0.5, y = info.y + (MOUNT_UP and 1.5 or -0.5), z = info.z + 0.5 }
  m.world = toWorld(m.localPos)
  local yaw, pitch = (tonumber(info.yaw) or 0) - YAW_OFFSET, (tonumber(info.pitch) or 0) * PITCH_SIGN
  -- 1. never across your own deck
  local center, width = arcFor(m)
  if abs(wrap(yaw - center)) > width / 2 then return holdFire(m, "points at own ship") end
  local dir = qrot(pose.q, dirOf(yaw, pitch))
  local tgt, miss, dy, own = predictShot(m, dir)
  if AUTO_SPEED and not own and tgt and learner == m then
    learnSpeed(m, dir)
    tgt, miss, dy, own = predictShot(m, dir)
  end
  -- 2. never through another part of your ship
  if own then return holdFire(m, "own ship in line") end
  m.target, m.miss, m.dy = tgt, miss, dy
  -- a held trigger stays on a little longer so it doesn't flicker at the edge
  local radius = HIT_RADIUS
  if AUTOCANNON and m.trigger then radius = HIT_RADIUS * 1.2 end
  local onTarget = tgt and miss <= radius
  local t = now()
  if not onTarget and not forceFire then
    return holdFire(m, tgt and "not on target" or "no target")
  end
  if not armed and not forceFire then return holdFire(m, "ON TARGET") end
  if rock > MAX_ROCK and not forceFire then return holdFire(m, "ship rocking") end
  if AUTOCANNON then
    setTrigger(m, true)
    m.state = m.fireErr and ("fire error: " .. m.fireErr) or "FIRING"
    return
  end
  if t - m.lastShot < RELOAD then
    m.state = string.format("reload %.0fs", RELOAD - (t - m.lastShot))
  elseif t - lastAnyShot < STAGGER then
    m.state = "ON TARGET"
  else
    -- claim the slot before the call yields, so two cannons can't both fire
    m.lastShot, lastAnyShot = t, t
    setTrigger(m, true)
    m.shots = (m.shots or 0) + 1
    m.state = "FIRE"
  end
end

-- ============================================================ screen

local function draw()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.yellow)
  write("Fire Control " .. VERSION .. "  ")
  if armed then
    term.setTextColor(colors.red)
    write("ARMED")
  else
    term.setTextColor(colors.lime)
    write("SAFE (watching only)")
  end
  term.setTextColor(colors.white)
  print("")
  print(string.format("Radar: %s   ship %.0f m/s   rock %.1f", radar or "NONE", len(shipVel) * 20, rock))
  print(string.format("Round speed %.1f %s", speed, speedLearned and "(learned from the radar)" or
    (AUTO_SPEED and string.format("(SHOT_SPEED, learning %d/5)", #speedSamples) or "(SHOT_SPEED)")))
  if radarError then
    term.setTextColor(colors.red)
    print("Radar error: " .. radarError)
  end
  if fireControllers > 0 then
    term.setTextColor(colors.red)
    print("Fire Controller on the network: remove it, it fires by itself!")
  end
  term.setTextColor(colors.white)
  print("")
  if #targets == 0 then
    print("Targets: none in range")
  else
    for i = 1, math.min(3, #targets) do
      local s = targets[i]
      local ago = now() - s.seenAt
      term.setTextColor(i == 1 and colors.orange or colors.lightGray)
      print(string.format("%s %s %s %.0fm %.0fm/s%s", i == 1 and ">" or " ", s.cat, s.kind:sub(1, 12), s.d,
        len(contactVel(s)) * 20, ago > 1 and string.format(" (%.0fs ago)", ago) or ""))
    end
  end
  term.setTextColor(colors.gray)
  print(string.format("Own ship parts: %d   ignored: %d", #ownParts, (function() local n = 0 for _ in pairs(ignored) do n = n + 1 end return n end)()))
  print("")
  for _, m in ipairs(mounts) do
    local col = colors.lightGray
    if m.state == "FIRE" or m.state == "FIRING" then col = colors.red
    elseif m.state == "ON TARGET" then col = colors.lime
    elseif m.state == "points at own ship" or m.state == "own ship in line" then col = colors.orange end
    term.setTextColor(col)
    local sd = sideOf(m.name)
    local tag = sd == "left" and "L" or (sd == "right" and "R" or "?")
    local line = string.format("%-8s %s %-18s", m.name:gsub("^cannon_", ""):sub(1, 8), tag, (m.state or ""):sub(1, 18))
    if m.miss and m.miss < 1e6 then
      line = line .. string.format(" miss %.0f", m.miss)
      if m.miss > HIT_RADIUS and abs(m.dy) > m.miss * 0.5 then line = line .. (m.dy > 0 and " high" or " low") end
    end
    print(line:sub(1, w))
  end
  if #mounts == 0 then
    term.setTextColor(colors.red)
    print("No cannon mounts found (wired modems: right-click them).")
  end
  term.setTextColor(colors.gray)
  term.setCursorPos(1, h)
  write("A arm/safe  X ignore nearest  U unignore  F fire")
  term.setTextColor(colors.white)
end

-- ============================================================ loops

local function mainLoop()
  local lastFind = -999
  while true do
    if now() - lastFind > 5 then
      findHardware()
      lastFind = now()
    end
    if readPose() then
      scan()
      local jobs = {}
      for _, m in ipairs(mounts) do jobs[#jobs + 1] = function() readMount(m) end end
      if #jobs > 0 then parallel.waitForAll(table.unpack(jobs)) end
      -- one cannon a couple of times a second also checks the round speed
      learner = nil
      if #mounts > 0 and now() - lastLearn > 0.5 then
        lastLearn = now()
        learnIndex = learnIndex % #mounts + 1
        learner = mounts[learnIndex]
      end
      jobs = {}
      for _, m in ipairs(mounts) do jobs[#jobs + 1] = function() checkMount(m) end end
      if #jobs > 0 then parallel.waitForAll(table.unpack(jobs)) end
      if not forceUntil or now() > forceUntil then forceFire = false end
    end
    if not WARSHIP then draw() end
    sleep(LOOP)
  end
end

local function toggleArmed() armed = not armed end
local function ignoreNearest()
  if not targets[1] then return false end
  ignored[targets[1].id] = true
  saveIgnored()
  return true
end
local function unignoreAll()
  ignored = {}
  saveIgnored()
end
local function fireNow()
  forceFire = true
  forceUntil = now() + (AUTOCANNON and 1 or 0)
end

local function keyLoop()
  while true do
    local _, k = os.pullEvent("key")
    if k == keys.a then toggleArmed()
    elseif k == keys.x then ignoreNearest()
    elseif k == keys.u then unignoreAll()
    elseif k == keys.f then fireNow() end
  end
end

-- Run by cc-warship: the Ship Pilot's "Auto cannons" screen shows this and
-- uses these controls, so this program draws nothing itself.
if WARSHIP then
  WARSHIP.guns = {
    version = VERSION,
    toggle = toggleArmed,
    ignoreNearest = ignoreNearest,
    unignoreAll = unignoreAll,
    fire = fireNow,
    state = function()
      local st = {
        armed = armed, radar = radar, radarError = radarError, fireControllers = fireControllers,
        autocannon = AUTOCANNON, hitRadius = HIT_RADIUS, maxRock = MAX_ROCK,
        speed = speed, speedLearned = speedLearned, learning = AUTO_SPEED and not speedLearned and #speedSamples or nil,
        shipSpeed = len(shipVel) * 20, rock = rock, ownParts = #ownParts, ignored = 0, maxRange = MAX_RANGE,
        lockedAt = lastAnyShot,
        targets = {}, mounts = {},
      }
      for _ in pairs(ignored) do st.ignored = st.ignored + 1 end
      -- dx/dy/dz: where it is now, from this ship (for the captain's radar)
      for i = 1, math.min(8, #targets) do
        local c = targets[i]
        local p = pose and contactPos(c, 0)
        st.targets[i] = { cat = c.cat, kind = c.kind, d = c.d, speed = len(contactVel(c)) * 20, ago = now() - c.seenAt,
          dx = p and p.x - pose.pos.x, dy = p and p.y - pose.pos.y, dz = p and p.z - pose.pos.z }
      end
      for i, m in ipairs(mounts) do
        st.mounts[i] = { name = m.name, side = sideOf(m.name), state = m.state, miss = m.miss, dy = m.dy }
      end
      return st
    end,
  }
end

-- updates wait until nothing is in reach
function readyToUpdate()
  for _, m in ipairs(mounts) do
    if m.trigger then return false end
  end
  return not (armed and #targets > 0)
end

-- ============================================================ auto-update

-- Every UPDATE_CHECK_MINUTES this checks GitHub for a newer version. A new
-- version is downloaded, checked that it loads, given your current settings
-- (the UPPERCASE lines at the top of this file), saved, and the computer
-- reboots into it. Set AUTO_UPDATE = false at the top to turn this off.
local UPDATE_REPO = "levisnakes/cc-fire-control"
local UPDATE_FILE = "fire_control.lua"
local UPDATE_CHECK_MINUTES = 15
local PROGRAM_PATH = (shell and shell.getRunningProgram()) or "startup.lua"
local SHA_FILE = "/.version_" .. UPDATE_FILE

-- Settings are the top-of-file assignments to UPPERCASE names, before the
-- first "local" line or "-- ====" section. Tables can span several lines.
local function splitSettings(src)
  local settings, rest = {}, {}
  local inSettings = true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if inSettings and (line:match("^local ") or line:match("^%-%- ====")) then inSettings = false end
    table.insert(inSettings and settings or rest, line)
  end
  return settings, rest
end

local function braceDelta(line)
  local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
  local _, opens = code:gsub("{", "")
  local _, closes = code:gsub("}", "")
  return opens - closes
end

-- [NAME] = the full statement text, possibly several lines
local function statements(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^([%u_][%u%d_]*)%s*=")
    if name then
      local block = { lines[i] }
      local depth = braceDelta(lines[i])
      while depth > 0 and i < #lines do
        i = i + 1
        table.insert(block, lines[i])
        depth = depth + braceDelta(lines[i])
      end
      out[name] = table.concat(block, "\n")
    end
    i = i + 1
  end
  return out
end

-- New file, with each setting that already exists replaced by your value.
local function mergeSettings(oldSrc, newSrc)
  local oldSettings = statements((splitSettings(oldSrc)))
  local newSettings, rest = splitSettings(newSrc)
  local out = {}
  local i = 1
  while i <= #newSettings do
    local line = newSettings[i]
    local name = line:match("^([%u_][%u%d_]*)%s*=")
    if name and oldSettings[name] then
      table.insert(out, oldSettings[name])
      local depth = braceDelta(line)
      while depth > 0 and i < #newSettings do
        i = i + 1
        depth = depth + braceDelta(newSettings[i])
      end
    else
      table.insert(out, line)
    end
    i = i + 1
  end
  for _, line in ipairs(rest) do table.insert(out, line) end
  local merged = table.concat(out, "\n")
  -- splitting added one trailing newline's worth of empty line; match the source
  if newSrc:sub(-1) == "\n" and merged:sub(-1) ~= "\n" then merged = merged .. "\n" end
  return (merged:gsub("\n\n$", "\n"))
end

local function fetch(url, headers)
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = f.readAll()
  f.close()
  return t
end

local function writeText(path, text)
  local f = fs.open(path, "w")
  f.write(text)
  f.close()
end

local function checkForUpdate(atBoot)
  if AUTO_UPDATE == false or not http then return end
  local sha = fetch("https://api.github.com/repos/" .. UPDATE_REPO .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  if not sha then return end
  sha = sha:match("^%s*(%x+)%s*$")
  if not sha or #sha < 40 or readText(SHA_FILE) == sha then return end

  local newSrc = fetch("https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. sha .. "/" .. UPDATE_FILE)
  if not newSrc or not load(newSrc, UPDATE_FILE) then return end
  local oldSrc = readText(PROGRAM_PATH)
  if not oldSrc then return end
  local merged = mergeSettings(oldSrc, newSrc)
  if not load(merged, UPDATE_FILE) then return end
  if merged == oldSrc then
    writeText(SHA_FILE, sha)
    return
  end

  -- at boot nothing is running yet, so there is nothing to wait for
  while not atBoot and not readyToUpdate() do sleep(5) end
  writeText(PROGRAM_PATH .. ".old", oldSrc)
  writeText(PROGRAM_PATH, merged)
  writeText(SHA_FILE, sha)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Updated to " .. sha:sub(1, 7) .. ", restarting...")
  if not atBoot then sleep(1) end
  os.reboot()
end

local function updateLoop()
  while true do
    sleep(UPDATE_CHECK_MINUTES * 60)
    pcall(checkForUpdate)
  end
end

-- Check for a new version as soon as the computer starts, before the
-- program runs, so a restart always picks up the latest version.
local function bootUpdate()
  if AUTO_UPDATE == false or not http then return end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Checking for updates...")
  pcall(checkForUpdate, true)
end


findHardware()
for _, m in ipairs(mounts) do
  pcall(peripheral.call, m.name, "setComputerControl", false)
  pcall(peripheral.call, m.name, "fire", false)
end
bootUpdate()
local ok, err = pcall(parallel.waitForAny, mainLoop, keyLoop, updateLoop)
for _, m in ipairs(mounts) do pcall(peripheral.call, m.name, "fire", false) end
if not ok then error(err, 0) end
