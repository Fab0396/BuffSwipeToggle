-- BuffSwipeToggle.lua
-- Optimized + combat-safe:
-- - NEVER writes custom fields onto Blizzard objects (only weak-key tables on our side)
-- - NO enforce in combat (applies after combat)
-- - Hot hooks NEVER do parent-chain viewer resolve (major hitch reduction)
-- - Scanning targets CooldownViewer-style frames only (no brute-force "all cooldowns")

local ADDON_NAME = ...
local BST = {}
_G.BuffSwipeToggle = BST

BuffSwipeToggleDB = BuffSwipeToggleDB or nil
BuffSwipeToggleCharDB = BuffSwipeToggleCharDB or nil

-- -------------------------------------------------------
-- Anchors
-- -------------------------------------------------------
local ANCHORS = {
	{ key = "TOPLEFT",     text = "Top Left" },
	{ key = "TOP",         text = "Top" },
	{ key = "TOPRIGHT",    text = "Top Right" },
	{ key = "LEFT",        text = "Left" },
	{ key = "CENTER",      text = "Center" },
	{ key = "RIGHT",       text = "Right" },
	{ key = "BOTTOMLEFT",  text = "Bottom Left" },
	{ key = "BOTTOM",      text = "Bottom" },
	{ key = "BOTTOMRIGHT", text = "Bottom Right" },
	{ key = "EDGETOP",     text = "Edge Top" },
	{ key = "EDGEBOTTOM",  text = "Edge Bottom" },
}

local ANCHOR_TEXT = {}
for i = 1, #ANCHORS do ANCHOR_TEXT[ANCHORS[i].key] = ANCHORS[i].text end

local function SafeAnchor(a)
	if a == "EDGE" then return "EDGETOP" end
	if ANCHOR_TEXT[a] then return a end
	return "CENTER"
end

-- -------------------------------------------------------
-- Defaults
-- -------------------------------------------------------
local DEFAULTS = {
	minimap = { show = true, angle = 220 },
	useCharacterSettings = false,

	defaultNewViewerSwipe = true,
	defaultNewViewerMoveDuration = true,
	defaultNewViewerMoveStacks = true,

	knownViewers = {},     -- [viewer]=true
	swipe = {},            -- [viewer]=bool

	moveDuration = {},     -- [viewer]=bool
	moveStacks = {},       -- [viewer]=bool

	durationPos = {},      -- [viewer]={anchor,x,y}
	stackPos = {},         -- [viewer]={anchor,x,y}

	-- legacy
	textPos = {},

	lastSeen = {},
	ui = { compact = false, selectedViewer = "" },
}

local function DeepCopyDefaults(dst, src)
	if type(dst) ~= "table" then dst = {} end
	for k, v in pairs(src) do
		if type(v) == "table" then
			dst[k] = DeepCopyDefaults(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
	return dst
end

local function EnsureTables(db)
	db.minimap = db.minimap or { show = true, angle = 220 }
	db.knownViewers = db.knownViewers or {}
	db.swipe = db.swipe or {}

	db.moveDuration = db.moveDuration or {}
	db.moveStacks = db.moveStacks or {}

	db.durationPos = db.durationPos or {}
	db.stackPos = db.stackPos or {}

	db.textPos = db.textPos or {}
	db.lastSeen = db.lastSeen or {}
	db.ui = db.ui or {}

	if db.ui.compact == nil then db.ui.compact = false end
	if db.ui.selectedViewer == nil then db.ui.selectedViewer = "" end

	if db.defaultNewViewerSwipe == nil then db.defaultNewViewerSwipe = true end
	if db.defaultNewViewerMoveDuration == nil then db.defaultNewViewerMoveDuration = true end
	if db.defaultNewViewerMoveStacks == nil then db.defaultNewViewerMoveStacks = true end
end

-- -------------------------------------------------------
-- Safe helpers
-- -------------------------------------------------------
local function SafeCall(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		DEFAULT_CHAT_FRAME:AddMessage(("|cffff5555[BuffSwipeToggle]|r %s"):format(tostring(err)))
	end
	return ok
end

function BST:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(("|cff66ccff[BuffSwipeToggle]|r %s"):format(msg))
end

local function InCombat()
	return (type(InCombatLockdown) == "function") and InCombatLockdown()
end

local function IsFrame(v)
	return type(v) == "table" and type(v.GetObjectType) == "function" and v:GetObjectType() == "Frame"
end

local function IsFontString(o)
	return type(o) == "table" and type(o.GetObjectType) == "function" and o:GetObjectType() == "FontString"
end

local function SafeEq(a, b)
	local ok, res = pcall(function() return a == b end)
	return ok and res or false
end

local function SafeNum(v)
	local ok, n = pcall(function() return tonumber(v) end)
	if ok and n then return n end
	return 0
end

local function SafeToString(v)
	if v == nil then return "" end
	local ok, s = pcall(function() return tostring(v) end)
	if ok and type(s) == "string" then return s end
	return ""
end

local function SafeStrFind(s, pat)
	if type(s) ~= "string" then return false end
	local ok, pos = pcall(string.find, s, pat)
	return ok and (pos ~= nil) or false
end

local function IsNumericText(s)
	if type(s) ~= "string" then return false end
	return SafeStrFind(s, "%d")
end

local function SafeGetPoint(fs)
	if not fs or type(fs.GetPoint) ~= "function" then return nil end
	local ok, p, rel, rp, ox, oy = pcall(fs.GetPoint, fs, 1)
	if not ok then return nil end
	return p, rel, rp, ox, oy
end

local function SafeSortStrings(t)
	table.sort(t, function(a, b)
		return SafeToString(a) < SafeToString(b)
	end)
end

-- -------------------------------------------------------
-- DB
-- -------------------------------------------------------
BST._dbReady = false

function BST:InitDB()
	BuffSwipeToggleDB = DeepCopyDefaults(BuffSwipeToggleDB or {}, DEFAULTS)
	BuffSwipeToggleCharDB = DeepCopyDefaults(BuffSwipeToggleCharDB or {}, DEFAULTS)
	EnsureTables(BuffSwipeToggleDB)
	EnsureTables(BuffSwipeToggleCharDB)
	self._dbReady = true

	-- merge known viewers
	for vn in pairs(BuffSwipeToggleDB.knownViewers) do BuffSwipeToggleCharDB.knownViewers[vn] = true end
	for vn in pairs(BuffSwipeToggleCharDB.knownViewers) do BuffSwipeToggleDB.knownViewers[vn] = true end
end

function BST:EnsureInit()
	if not self._dbReady then self:InitDB() end
end

function BST:GetAccountDB() return BuffSwipeToggleDB end
function BST:GetCharDB() return BuffSwipeToggleCharDB end

function BST:UseCharSettings()
	local c = self:GetCharDB()
	return c and c.useCharacterSettings
end

function BST:GetActiveDB()
	return self:UseCharSettings() and self:GetCharDB() or self:GetAccountDB()
end

-- -------------------------------------------------------
-- Runtime caches (NO writes onto Blizzard objects)
-- -------------------------------------------------------
BST._viewerByCooldown  = setmetatable({}, { __mode = "k" }) -- cooldown -> viewerName
BST._appliedByCooldown = setmetatable({}, { __mode = "k" }) -- cooldown -> state
BST._cooldownsByViewer = {}                                 -- viewerName -> weak-key set

BST._swipeHooked = setmetatable({}, { __mode = "k" })        -- cooldown -> true
BST._swipeGuard  = setmetatable({}, { __mode = "k" })        -- cooldown -> true while we set

BST._textHookInfo = setmetatable({}, { __mode = "k" })       -- fs -> { cooldown=cd, which="duration"/"stack" }
BST._textGuard    = setmetatable({}, { __mode = "k" })       -- fs -> true while we set points

local function EnsureViewerSet(self, vn)
	if not self._cooldownsByViewer[vn] then
		self._cooldownsByViewer[vn] = setmetatable({}, { __mode = "k" })
	end
end

-- -------------------------------------------------------
-- Viewer defaults / settings
-- -------------------------------------------------------
function BST:EnsureViewerDefaults(vn)
	if not vn or vn == "" then return end
	self:EnsureInit()
	local db = self:GetActiveDB(); if not db then return end
	EnsureTables(db)

	db.knownViewers[vn] = true

	if db.swipe[vn] == nil then db.swipe[vn] = not not db.defaultNewViewerSwipe end
	if db.moveDuration[vn] == nil then db.moveDuration[vn] = not not db.defaultNewViewerMoveDuration end
	if db.moveStacks[vn] == nil then db.moveStacks[vn] = not not db.defaultNewViewerMoveStacks end

	if db.durationPos[vn] == nil then
		local legacy = db.textPos[vn]
		if type(legacy) == "table" then
			db.durationPos[vn] = { anchor = "CENTER", x = tonumber(legacy.x) or 0, y = tonumber(legacy.y) or 0 }
		else
			db.durationPos[vn] = { anchor = "CENTER", x = 0, y = 0 }
		end
	else
		local p = db.durationPos[vn]
		p.anchor = SafeAnchor(p.anchor)
		p.x = tonumber(p.x) or 0
		p.y = tonumber(p.y) or 0
	end

	if db.stackPos[vn] == nil then
		db.stackPos[vn] = { anchor = "BOTTOMRIGHT", x = 0, y = 0 }
	else
		local p = db.stackPos[vn]
		p.anchor = SafeAnchor(p.anchor)
		p.x = tonumber(p.x) or 0
		p.y = tonumber(p.y) or 0
	end

	if db.lastSeen[vn] == nil then db.lastSeen[vn] = 0 end
	EnsureViewerSet(self, vn)
end

function BST:MarkSeen(vn)
	local db = self:GetActiveDB(); if not db then return end
	EnsureTables(db)
	db.lastSeen[vn] = time()
end

function BST:IsSwipeEnabled(vn)
	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	return not not db.swipe[vn]
end

function BST:IsMoveDurationEnabled(vn)
	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	return not not db.moveDuration[vn]
end

function BST:IsMoveStacksEnabled(vn)
	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	return not not db.moveStacks[vn]
end

function BST:GetDurationPos(vn)
	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	local p = db.durationPos[vn]
	return SafeAnchor(p.anchor), tonumber(p.x) or 0, tonumber(p.y) or 0
end

function BST:GetStackPos(vn)
	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	local p = db.stackPos[vn]
	return SafeAnchor(p.anchor), tonumber(p.x) or 0, tonumber(p.y) or 0
end

-- -------------------------------------------------------
-- Desired points
-- -------------------------------------------------------
local function GetDesiredPoint(anchor, x, y)
	anchor = SafeAnchor(anchor)
	x = tonumber(x) or 0
	y = tonumber(y) or 0

	if anchor == "EDGETOP" then
		return "CENTER", "TOP", x, y
	elseif anchor == "EDGEBOTTOM" then
		return "CENTER", "BOTTOM", x, y
	end
	return anchor, anchor, x, y
end

local function ApplyFS(fs, cooldown, anchor, x, y)
	local fsP, cdP, dx, dy = GetDesiredPoint(anchor, x, y)
	fs:ClearAllPoints()
	fs:SetPoint(fsP, cooldown, cdP, dx, dy)
end

local function IsFSAtDesired(fs, cooldown, anchor, x, y)
	local pWant, rpWant, dxWant, dyWant = GetDesiredPoint(anchor, x, y)
	local p, rel, rp, ox, oy = SafeGetPoint(fs)
	if p == nil then return false end
	if not SafeEq(rel, cooldown) then return false end
	if not SafeEq(p, pWant) then return false end
	if not SafeEq(rp, rpWant) then return false end
	if SafeNum(ox) ~= dxWant then return false end
	if SafeNum(oy) ~= dyWant then return false end
	return true
end

-- -------------------------------------------------------
-- Safe capture/restore
-- -------------------------------------------------------
local function CaptureOriginalPoint(fs)
	local p, rel, rp, ox, oy = SafeGetPoint(fs)
	if p == nil then return nil end

	local relName
	if rel and type(rel) == "table" and rel.GetName then
		local ok, n = pcall(rel.GetName, rel)
		if ok and type(n) == "string" and n ~= "" then relName = n end
	end
	return { p = p, rel = rel, relName = relName, rp = rp, ox = ox, oy = oy }
end

local function RestoreOriginalPoint(fs, orig, cooldown)
	if not fs or not orig then return end

	local rel = orig.rel
	if (not rel) and orig.relName and _G[orig.relName] then rel = _G[orig.relName] end
	if not rel then rel = cooldown end
	if not rel then rel = fs:GetParent() end

	fs:ClearAllPoints()
	local ok = pcall(fs.SetPoint, fs,
		orig.p or "CENTER",
		rel,
		orig.rp or orig.p or "CENTER",
		orig.ox or 0,
		orig.oy or 0
	)

	if not ok then
		fs:ClearAllPoints()
		if cooldown then
			pcall(fs.SetPoint, fs, "CENTER", cooldown, "CENTER", 0, 0)
		else
			pcall(fs.SetPoint, fs, "CENTER", fs:GetParent(), "CENTER", 0, 0)
		end
	end
end

-- -------------------------------------------------------
-- Viewer discovery
-- -------------------------------------------------------
BST._lastGlobalViewerScan = 0

function BST:DiscoverViewersFast()
	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)

	for _, name in ipairs({ "BuffIconCooldownViewer", "EssentialCooldownViewer", "UtilityCooldownViewer" }) do
		local f = _G[name]
		if f and IsFrame(f) then
			self:EnsureViewerDefaults(name)
			self:MarkSeen(name)
		end
	end

	for vn in pairs(db.knownViewers) do
		self:EnsureViewerDefaults(vn)
	end
end

function BST:DiscoverViewersGlobal(force)
	local now = GetTime()
	if not force and (now - (self._lastGlobalViewerScan or 0)) < 6.0 then return end
	self._lastGlobalViewerScan = now

	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)

	for k, v in pairs(_G) do
		if type(k) == "string" and k:match("CooldownViewer$") and IsFrame(v) then
			self:EnsureViewerDefaults(k)
			self:MarkSeen(k)
		end
	end
end

function BST:GetSortedViewerNames()
	self:DiscoverViewersFast()
	local db = self:GetActiveDB(); EnsureTables(db)
	local t = {}
	for vn in pairs(db.knownViewers) do t[#t + 1] = vn end
	SafeSortStrings(t)
	return t
end

-- -------------------------------------------------------
-- Resolve viewer name from parent chain (ONLY used outside hot hooks)
-- -------------------------------------------------------
local function ResolveViewerNameFromChain(start, db)
	local p = start
	for _ = 1, 14 do
		if not p then break end

		local vf = rawget(p, "viewerFrame")
		if vf and IsFrame(vf) and type(vf.GetName) == "function" then
			local vn = vf:GetName()
			if vn and vn ~= "" then return vn end
		end

		for _, key in ipairs({ "cooldownViewer", "CooldownViewer", "viewer", "Viewer" }) do
			local ref = rawget(p, key)
			if ref and IsFrame(ref) and type(ref.GetName) == "function" then
				local vn = ref:GetName()
				if vn and vn ~= "" then return vn end
			end
		end

		if type(p.GetName) == "function" then
			local name = p:GetName()
			if name and name ~= "" then
				if db and db.knownViewers and db.knownViewers[name] then return name end
				if name:match("CooldownViewer$") and _G[name] and IsFrame(_G[name]) then return name end
			end
		end

		p = (type(p.GetParent) == "function") and p:GetParent() or nil
	end
	return nil
end

function BST:_TrackCooldown(cooldown, vn)
	if not cooldown or not vn or vn == "" then return end
	self._viewerByCooldown[cooldown] = vn
	self:EnsureViewerDefaults(vn)
	self._cooldownsByViewer[vn][cooldown] = true
end

-- -------------------------------------------------------
-- Find duration/stacks FontStrings
-- -------------------------------------------------------
local function CollectFontStrings(frame, out)
	if not frame or type(frame.GetRegions) ~= "function" then return end
	local regions = { frame:GetRegions() }
	for i = 1, #regions do
		local r = regions[i]
		if IsFontString(r) then out[#out + 1] = r end
	end
end

local function FontSize(fs)
	if not fs or type(fs.GetFont) ~= "function" then return 0 end
	local ok, _, size = pcall(function()
		local f, s = fs:GetFont()
		return f, s
	end)
	if ok and size then return tonumber(size) or 0 end
	return 0
end

local function PointName(fs)
	local p = SafeGetPoint(fs)
	return SafeToString(p)
end

function BST:FindDurationText(cooldown)
	local candidates = {}
	local parent = (type(cooldown.GetParent) == "function") and cooldown:GetParent() or nil
	local gp = (parent and type(parent.GetParent) == "function") and parent:GetParent() or nil

	CollectFontStrings(cooldown, candidates)
	CollectFontStrings(parent, candidates)
	CollectFontStrings(gp, candidates)

	for _, k in ipairs({ "text", "Text", "CountdownText", "CooldownText", "TimerText" }) do
		local fs = rawget(cooldown, k)
		if IsFontString(fs) then candidates[#candidates + 1] = fs end
	end

	local seen, best, bestScore = {}, nil, -1
	for i = 1, #candidates do
		local fs = candidates[i]
		if fs and not seen[fs] then
			seen[fs] = true
			local txt = fs.GetText and fs:GetText() or nil
			local size = FontSize(fs)
			local pName = PointName(fs)

			local score = 0
			if IsNumericText(txt) then score = score + 100 end
			score = score + (size * 3)

			if SafeStrFind(pName, "CENTER") then score = score + 25 end
			if SafeStrFind(pName, "TOP") then score = score + 10 end
			if SafeStrFind(pName, "BOTTOMRIGHT") then score = score - 35 end

			local _, rel = SafeGetPoint(fs)
			if rel and SafeEq(rel, cooldown) then score = score + 25 end

			if score > bestScore then best, bestScore = fs, score end
		end
	end
	return best
end

function BST:FindStackText(cooldown, durationFS)
	local candidates = {}
	local parent = (type(cooldown.GetParent) == "function") and cooldown:GetParent() or nil
	local gp = (parent and type(parent.GetParent) == "function") and parent:GetParent() or nil

	CollectFontStrings(cooldown, candidates)
	CollectFontStrings(parent, candidates)
	CollectFontStrings(gp, candidates)

	if parent then
		for _, k in ipairs({ "count", "Count", "stack", "Stack", "Stacks", "ChargeText" }) do
			local fs = rawget(parent, k)
			if IsFontString(fs) then candidates[#candidates + 1] = fs end
		end
	end

	local seen, best, bestScore = {}, nil, -1
	for i = 1, #candidates do
		local fs = candidates[i]
		if fs and fs ~= durationFS and not seen[fs] then
			seen[fs] = true

			local txt = fs.GetText and fs:GetText() or nil
			local size = FontSize(fs)
			local pName = PointName(fs)

			local score = 0
			if IsNumericText(txt) then score = score + 100 end
			score = score - (size * 2)

			if SafeStrFind(pName, "BOTTOMRIGHT") then score = score + 40 end
			if SafeStrFind(pName, "BOTTOM") then score = score + 15 end
			if SafeStrFind(pName, "RIGHT") then score = score + 10 end
			if SafeStrFind(pName, "TOP") then score = score - 20 end

			if score > bestScore then best, bestScore = fs, score end
		end
	end
	return best
end

-- -------------------------------------------------------
-- Hooks (combat-safe) + OPTIMIZED: no chain resolving in hot hooks
-- -------------------------------------------------------
function BST:_EnsureSwipeEnforcer(cooldown)
	if self._swipeHooked[cooldown] then return end
	if type(cooldown.SetDrawSwipe) ~= "function" then return end
	self._swipeHooked[cooldown] = true

	hooksecurefunc(cooldown, "SetDrawSwipe", function(cd, val)
		if InCombat() then return end
		if BST._swipeGuard[cd] then return end

		-- OPTIMIZATION: only enforce if we already tracked this cooldown -> viewer
		local vn = BST._viewerByCooldown[cd]
		if not vn then return end

		local desired = BST:IsSwipeEnabled(vn)
		if val ~= desired then
			BST._swipeGuard[cd] = true
			pcall(cd.SetDrawSwipe, cd, desired)
			BST._swipeGuard[cd] = nil
		end
	end)
end

function BST:_EnsureTextEnforcer(fs, cooldown, which)
	if not fs or not cooldown or not IsFontString(fs) then return end
	local info = self._textHookInfo[fs]
	if info and info.cooldown == cooldown and info.which == which then return end

	self._textHookInfo[fs] = { cooldown = cooldown, which = which }

	hooksecurefunc(fs, "SetPoint", function(font)
		if InCombat() then return end
		if BST._textGuard[font] then return end

		local inf = BST._textHookInfo[font]
		if not inf then return end

		local cd = inf.cooldown
		local w = inf.which

		-- OPTIMIZATION: only enforce if we already tracked this cooldown -> viewer
		local vn = BST._viewerByCooldown[cd]
		if not vn then return end

		if w == "duration" and not BST:IsMoveDurationEnabled(vn) then return end
		if w == "stack" and not BST:IsMoveStacksEnabled(vn) then return end

		local a, x2, y2
		if w == "duration" then
			a, x2, y2 = BST:GetDurationPos(vn)
		else
			a, x2, y2 = BST:GetStackPos(vn)
		end

		if IsFSAtDesired(font, cd, a, x2, y2) then return end

		BST._textGuard[font] = true
		pcall(ApplyFS, font, cd, a, x2, y2)
		BST._textGuard[font] = nil
	end)
end

-- -------------------------------------------------------
-- Apply core (combat-safe)
-- -------------------------------------------------------
function BST:ApplyToCooldown(cooldown, viewerName)
	if not cooldown or type(cooldown.SetDrawSwipe) ~= "function" then return end

	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)

	local vn = viewerName or self._viewerByCooldown[cooldown] or ResolveViewerNameFromChain(cooldown, db)
	if not vn then return end

	self:EnsureViewerDefaults(vn)
	self:MarkSeen(vn)
	self:_TrackCooldown(cooldown, vn)

	self:_EnsureSwipeEnforcer(cooldown)

	if InCombat() then return end

	local st = self._appliedByCooldown[cooldown]
	if not st then st = {}; self._appliedByCooldown[cooldown] = st end

	-- Swipe
	local desiredSwipe = self:IsSwipeEnabled(vn)
	if st.swipe ~= desiredSwipe then
		self._swipeGuard[cooldown] = true
		pcall(cooldown.SetDrawSwipe, cooldown, desiredSwipe)
		self._swipeGuard[cooldown] = nil
		st.swipe = desiredSwipe
	end

	-- Duration text
	local moveDur = self:IsMoveDurationEnabled(vn)
	if moveDur then
		local durA, durX, durY = self:GetDurationPos(vn)
		local durFS = st.durFS
		if not (durFS and IsFontString(durFS)) then
			durFS = self:FindDurationText(cooldown)
			st.durFS = durFS
			st.durOrig = nil
		end

		if durFS then
			if not st.durOrig then st.durOrig = CaptureOriginalPoint(durFS) end
			self:_EnsureTextEnforcer(durFS, cooldown, "duration")

			if st.durA ~= durA or st.durX ~= durX or st.durY ~= durY or not IsFSAtDesired(durFS, cooldown, durA, durX, durY) then
				self._textGuard[durFS] = true
				pcall(ApplyFS, durFS, cooldown, durA, durX, durY)
				self._textGuard[durFS] = nil
				st.durA, st.durX, st.durY = durA, durX, durY
			end
		end
	else
		local durFS = st.durFS
		if durFS and IsFontString(durFS) and st.durOrig then
			self._textGuard[durFS] = true
			RestoreOriginalPoint(durFS, st.durOrig, cooldown)
			self._textGuard[durFS] = nil
		end
	end

	-- Stack text
	local moveStk = self:IsMoveStacksEnabled(vn)
	if moveStk then
		local stkA, stkX, stkY = self:GetStackPos(vn)

		local durFS = st.durFS
		if not (durFS and IsFontString(durFS)) then durFS = nil end

		local stkFS = st.stkFS
		if not (stkFS and IsFontString(stkFS)) then
			stkFS = self:FindStackText(cooldown, durFS)
			st.stkFS = stkFS
			st.stkOrig = nil
		end

		if stkFS then
			if not st.stkOrig then st.stkOrig = CaptureOriginalPoint(stkFS) end
			self:_EnsureTextEnforcer(stkFS, cooldown, "stack")

			if st.stkA ~= stkA or st.stkX ~= stkX or st.stkY ~= stkY or not IsFSAtDesired(stkFS, cooldown, stkA, stkX, stkY) then
				self._textGuard[stkFS] = true
				pcall(ApplyFS, stkFS, cooldown, stkA, stkX, stkY)
				self._textGuard[stkFS] = nil
				st.stkA, st.stkX, st.stkY = stkA, stkX, stkY
			end
		end
	else
		local stkFS = st.stkFS
		if stkFS and IsFontString(stkFS) and st.stkOrig then
			self._textGuard[stkFS] = true
			RestoreOriginalPoint(stkFS, st.stkOrig, cooldown)
			self._textGuard[stkFS] = nil
		end
	end
end

function BST:ApplyViewerCooldowns(vn)
	if not vn or vn == "" then return end
	self:EnsureViewerDefaults(vn)
	local set = self._cooldownsByViewer[vn]
	if not set then return end
	for cd in pairs(set) do
		self:ApplyToCooldown(cd, vn)
	end
end

function BST:ApplyAllKnownCooldowns()
	for vn, set in pairs(self._cooldownsByViewer) do
		if set then
			for cd in pairs(set) do
				self:ApplyToCooldown(cd, vn)
			end
		end
	end
end

-- -------------------------------------------------------
-- Coalesce touches (combat-safe queue)
-- -------------------------------------------------------
BST._pendingSet = setmetatable({}, { __mode = "k" })
BST._pendingList = {}
BST._pendingIndex = 1
BST._pendingScheduled = false
BST._pendingAfterCombat = false

function BST:EnqueueCooldown(cooldown)
	if not cooldown then return end
	if self._pendingSet[cooldown] then return end
	self._pendingSet[cooldown] = true
	self._pendingList[#self._pendingList + 1] = cooldown

	if InCombat() then
		self._pendingAfterCombat = true
		return
	end
	self:SchedulePending()
end

function BST:SchedulePending()
	if self._pendingScheduled then return end
	self._pendingScheduled = true
	C_Timer.After(0, function()
		BST._pendingScheduled = false
		BST:ProcessPending(25)
	end)
end

function BST:ProcessPending(budget)
	if InCombat() then return end

	local list = self._pendingList
	local idx = self._pendingIndex
	if not list[idx] then
		self._pendingList = {}
		self._pendingIndex = 1
		return
	end

	local n = 0
	while n < budget do
		local cd = list[idx]
		if not cd then break end
		self._pendingSet[cd] = nil
		list[idx] = nil
		idx = idx + 1
		n = n + 1
		self:ApplyToCooldown(cd, nil)
	end
	self._pendingIndex = idx

	if self._pendingIndex > 220 then
		local new = {}
		for i = self._pendingIndex, #list do
			local cd = list[i]
			if cd then new[#new + 1] = cd end
		end
		self._pendingList = new
		self._pendingIndex = 1
	end

	if self._pendingList[self._pendingIndex] then
		self:SchedulePending()
	else
		self._pendingList = {}
		self._pendingIndex = 1
	end
end

function BST:TryHookCooldownSetters()
	if self._hookedCooldownSetters then return end
	self._hookedCooldownSetters = true

	local function OnCooldownTouched(cooldown)
		if cooldown then BST:EnqueueCooldown(cooldown) end
	end

	if type(_G.CooldownFrame_Set) == "function" then hooksecurefunc("CooldownFrame_Set", OnCooldownTouched) end
	if type(_G.CooldownFrame_SetTimer) == "function" then hooksecurefunc("CooldownFrame_SetTimer", OnCooldownTouched) end
	if type(_G.CooldownFrame_SetCooldown) == "function" then hooksecurefunc("CooldownFrame_SetCooldown", OnCooldownTouched) end

	for _, mixinName in ipairs({ "CooldownFrameMixin", "CooldownMixin" }) do
		local mix = _G[mixinName]
		if type(mix) == "table" then
			if type(mix.SetCooldown) == "function" then
				hooksecurefunc(mix, "SetCooldown", function(self) OnCooldownTouched(self) end)
			end
			if type(mix.SetTimer) == "function" then
				hooksecurefunc(mix, "SetTimer", function(self) OnCooldownTouched(self) end)
			end
		end
	end
end

-- -------------------------------------------------------
-- Incremental scan (never in combat) - OPTIMIZED: only CooldownViewer-style frames
-- -------------------------------------------------------
BST._scanTicker = nil
BST._scanEnumFrame = nil
BST._scanReason = nil
BST._lastGlobalViewerScan = 0

function BST:StopScan(reasonFilter)
	if self._scanTicker and (not reasonFilter or self._scanReason == reasonFilter) then
		self._scanTicker:Cancel()
		self._scanTicker = nil
		self._scanEnumFrame = nil
		self._scanReason = nil
	end
end

function BST:StartScan(reason, perTick, interval, delay)
	if InCombat() then return end

	self:StopScan()
	self._scanReason = reason

	local pt = perTick or 12
	local iv = interval or 0.03
	local dl = delay or 0.35

	C_Timer.After(dl, function()
		if InCombat() then return end
		if BST._scanReason ~= reason then return end
		BST._scanEnumFrame = EnumerateFrames()

		BST._scanTicker = C_Timer.NewTicker(iv, function()
			if InCombat() then BST:StopScan(); return end

			local f = BST._scanEnumFrame
			local n = 0
			local db = BST:GetActiveDB(); EnsureTables(db)

			while f and n < pt do
				-- OPTIMIZATION: only frames that look like CooldownViewer items
				-- Typical: item has viewerFrame + Cooldown child
				local vf = rawget(f, "viewerFrame")
				local cd = rawget(f, "Cooldown")
				if vf and IsFrame(vf) and cd and type(cd.SetDrawSwipe) == "function" then
					local vn = (type(vf.GetName) == "function") and vf:GetName() or nil
					if vn then BST:ApplyToCooldown(cd, vn) end
				end

				f = EnumerateFrames(f)
				n = n + 1
			end

			BST._scanEnumFrame = f
			if not f then BST:StopScan() end
		end)
	end)
end

-- -------------------------------------------------------
-- Post-combat smooth catch-up
-- -------------------------------------------------------
BST._postCombatTicker = nil
BST._postCombatQueue = nil
BST._postCombatIndex = 1

function BST:CancelPostCombat()
	if self._postCombatTicker then
		self._postCombatTicker:Cancel()
		self._postCombatTicker = nil
	end
	self._postCombatQueue = nil
	self._postCombatIndex = 1
end

function BST:PostCombatUpdate()
	if InCombat() then return end

	self:CancelPostCombat()
	self:StopScan()

	if self._pendingAfterCombat then
		self._pendingAfterCombat = false
		self:SchedulePending()
	end

	local q, seen = {}, {}
	for cd in pairs(self._viewerByCooldown) do
		if cd and not seen[cd] then seen[cd] = true; q[#q + 1] = cd end
	end
	for cd in pairs(self._appliedByCooldown) do
		if cd and not seen[cd] then seen[cd] = true; q[#q + 1] = cd end
	end

	self._postCombatQueue = q
	self._postCombatIndex = 1

	local perTick = 6      -- slightly lower burst to reduce post-combat hitch
	local interval = 0.03

	self._postCombatTicker = C_Timer.NewTicker(interval, function()
		if InCombat() then
			BST:CancelPostCombat()
			return
		end

		local idx = BST._postCombatIndex
		for i = 1, perTick do
			local cd = BST._postCombatQueue[idx]
			if not cd then break end
			BST:ApplyToCooldown(cd, nil)
			idx = idx + 1
		end
		BST._postCombatIndex = idx

		if not BST._postCombatQueue[idx] then
			BST:CancelPostCombat()
			BST:StartScan("POSTCOMBAT", 12, 0.03, 0.45)
		end
	end)
end

-- -------------------------------------------------------
-- UI (single-window, grey + 2px borders)
-- -------------------------------------------------------
local function Border2px(frame)
	if frame._bstBorder then return end
	frame._bstBorder = true
	local border = 2
	local function mk()
		local t = frame:CreateTexture(nil, "BORDER")
		t:SetColorTexture(0, 0, 0, 1)
		return t
	end
	local top = mk();    top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(border)
	local bottom = mk(); bottom:SetPoint("BOTTOMLEFT"); bottom:SetPoint("BOTTOMRIGHT"); bottom:SetHeight(border)
	local left = mk();   left:SetPoint("TOPLEFT"); left:SetPoint("BOTTOMLEFT"); left:SetWidth(border)
	local right = mk();  right:SetPoint("TOPRIGHT"); right:SetPoint("BOTTOMRIGHT"); right:SetWidth(border)
end

local function SkinCell(frame, bg, keepMouse)
	if frame._bstSkinned then return end
	frame._bstSkinned = true
	if not keepMouse and frame.EnableMouse then frame:EnableMouse(false) end

	local border = 2
	local bgc = bg or { 0.22, 0.22, 0.22, 1.0 }

	local t = frame:CreateTexture(nil, "BACKGROUND")
	t:SetPoint("TOPLEFT", frame, "TOPLEFT", border, -border)
	t:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -border, border)
	t:SetColorTexture(bgc[1], bgc[2], bgc[3], bgc[4])

	local shade = frame:CreateTexture(nil, "BACKGROUND")
	shade:SetAllPoints(t)
	shade:SetColorTexture(0, 0, 0, 0.06)

	Border2px(frame)
end

local function StyleGreyButton(btn)
	if not btn or btn._bstGrey then return end
	btn._bstGrey = true

	local n = btn:CreateTexture(nil, "BACKGROUND"); n:SetAllPoints(); n:SetColorTexture(0.30, 0.30, 0.30, 1.0)
	local p = btn:CreateTexture(nil, "BACKGROUND"); p:SetAllPoints(); p:SetColorTexture(0.22, 0.22, 0.22, 1.0)
	local h = btn:CreateTexture(nil, "HIGHLIGHT");  h:SetAllPoints(); h:SetColorTexture(1, 1, 1, 0.08)

	btn:SetNormalTexture(n)
	btn:SetPushedTexture(p)
	btn:SetHighlightTexture(h)
	Border2px(btn)

	local fs = btn.GetFontString and btn:GetFontString()
	if fs then fs:SetTextColor(1, 1, 1) end
end

local function MakeLabel(parent, text, template)
	local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
	fs:SetText(text)
	return fs
end

local function MakeNumberBox(parent, w)
	local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	eb:SetAutoFocus(false)
	eb:SetSize(w or 56, 20)
	eb:SetJustifyH("CENTER")
	eb:SetTextInsets(8, 8, 0, 0)
	return eb
end

local function CreateCheck(parent, text, point, rel, x, y, labelWidth)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetSize(24, 24)
	cb:SetPoint(point, rel, point, x, y)

	local l = cb.Text or cb.text
	if not l then
		l = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		cb._bstLabel = l
	end
	if cb._bstLabel then l = cb._bstLabel end

	l:ClearAllPoints()
	l:SetPoint("LEFT", cb, "RIGHT", 6, 1)
	l:SetJustifyH("LEFT")
	l:SetWordWrap(false)
	l:SetMaxLines(1)
	if labelWidth then l:SetWidth(labelWidth) end
	l:SetText(text)

	return cb
end

local function SetIfNotFocused(editBox, text)
	if editBox and editBox.HasFocus and editBox:HasFocus() then return end
	if editBox and editBox.GetText and editBox:GetText() ~= text then
		editBox:SetText(text)
	end
end

local function ClampInt(n, lo, hi)
	n = tonumber(n)
	if not n then return 0 end
	n = math.floor(n + 0.5)
	if n < lo then n = lo end
	if n > hi then n = hi end
	return n
end

local function CreateAnchorDropdown(parent, width)
	local dd = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
	UIDropDownMenu_SetWidth(dd, width or 140)
	UIDropDownMenu_JustifyText(dd, "LEFT")
	return dd
end

local function EnableDropDown(dd)
	if UIDropDownMenu_EnableDropDown then UIDropDownMenu_EnableDropDown(dd) end
	if dd and dd.Button then dd.Button:Enable() end
end

local function DisableDropDown(dd)
	if UIDropDownMenu_DisableDropDown then UIDropDownMenu_DisableDropDown(dd) end
	if dd and dd.Button then dd.Button:Disable() end
end

function BST:RefreshConfigIfOpen()
	if self.configFrame and self.configFrame:IsShown() then
		self:RefreshConfig()
	end
end

function BST:SetUseCharacterSettings(flag)
	self:EnsureInit()
	local c = self:GetCharDB()
	if not c then return end
	c.useCharacterSettings = not not flag

	local a = self:GetAccountDB()
	EnsureTables(a); EnsureTables(c)
	for vn in pairs(a.knownViewers) do c.knownViewers[vn] = true end
	for vn in pairs(c.knownViewers) do a.knownViewers[vn] = true end

	self:UpdateMinimapButton()
	self:RefreshConfigIfOpen()
	self:ApplyAllKnownCooldowns()
end

function BST:SetSelectedViewer(vn)
	local db = self:GetActiveDB(); EnsureTables(db)
	db.ui.selectedViewer = vn or ""
	self:RefreshConfigIfOpen()
end

function BST:SetSwipeEnabled(vn, flag)
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	db.swipe[vn] = not not flag
	self:ApplyViewerCooldowns(vn)
	self:RefreshConfigIfOpen()
end

function BST:SetMoveDurationEnabled(vn, flag)
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	db.moveDuration[vn] = not not flag
	self:ApplyViewerCooldowns(vn)
	self:RefreshConfigIfOpen()
end

function BST:SetMoveStacksEnabled(vn, flag)
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	db.moveStacks[vn] = not not flag
	self:ApplyViewerCooldowns(vn)
	self:RefreshConfigIfOpen()
end

function BST:SetDurationPos(vn, anchor, x, y)
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	local p = db.durationPos[vn]
	p.anchor, p.x, p.y = SafeAnchor(anchor), tonumber(x) or 0, tonumber(y) or 0
	self:ApplyViewerCooldowns(vn)
	self:RefreshConfigIfOpen()
end

function BST:SetStackPos(vn, anchor, x, y)
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	local p = db.stackPos[vn]
	p.anchor, p.x, p.y = SafeAnchor(anchor), tonumber(x) or 0, tonumber(y) or 0
	self:ApplyViewerCooldowns(vn)
	self:RefreshConfigIfOpen()
end

function BST:ResetDurationPos(vn) self:SetDurationPos(vn, "CENTER", 0, 0) end
function BST:ResetStackPos(vn) self:SetStackPos(vn, "BOTTOMRIGHT", 0, 0) end

function BST:SetAllSwipe(flag)
	local db = self:GetActiveDB(); EnsureTables(db)
	local val = not not flag
	for vn in pairs(db.knownViewers) do
		self:EnsureViewerDefaults(vn)
		db.swipe[vn] = val
	end
	self:ApplyAllKnownCooldowns()
	self:RefreshConfigIfOpen()
end

function BST:ResetAllOffsets()
	local db = self:GetActiveDB(); EnsureTables(db)
	for vn in pairs(db.knownViewers) do
		self:EnsureViewerDefaults(vn)
		db.durationPos[vn].anchor, db.durationPos[vn].x, db.durationPos[vn].y = "CENTER", 0, 0
		db.stackPos[vn].anchor, db.stackPos[vn].x, db.stackPos[vn].y = "BOTTOMRIGHT", 0, 0
	end
	self:ApplyAllKnownCooldowns()
	self:RefreshConfigIfOpen()
end

function BST:BuildConfigWindow()
	if self.configFrame then return end
	self:EnsureInit()

	local f = CreateFrame("Frame", "BuffSwipeToggleFrame", UIParent)
	f:SetSize(920, 610)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:Hide()
	f:EnableMouse(true)
	f:SetMovable(true)
	SkinCell(f, { 0.20, 0.20, 0.20, 1.0 }, true)

	-- ESC closes
	do
		local fname = f:GetName()
		if fname and type(UISpecialFrames) == "table" then
			local exists = false
			for i = 1, #UISpecialFrames do
				if UISpecialFrames[i] == fname then exists = true break end
			end
			if not exists then tinsert(UISpecialFrames, fname) end
		end
	end

	local titleBar = CreateFrame("Frame", nil, f)
	titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
	titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
	titleBar:SetHeight(28)
	SkinCell(titleBar, { 0.18, 0.18, 0.18, 1.0 }, true)

	MakeLabel(titleBar, "Buff Swipe Toggle", "GameFontNormal"):SetPoint("CENTER", titleBar, "CENTER", 0, 0)

	local closeBtn = CreateFrame("Button", nil, titleBar, "UIPanelButtonTemplate")
	closeBtn:SetSize(24, 20)
	closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
	closeBtn:SetText("X")
	StyleGreyButton(closeBtn)
	closeBtn:SetScript("OnClick", function() f:Hide() end)

	local mmLabel = MakeLabel(titleBar, "Minimap", "GameFontNormalSmall")
	mmLabel:SetPoint("RIGHT", closeBtn, "LEFT", -10, 0)

	local mmCheck = CreateFrame("CheckButton", nil, titleBar, "UICheckButtonTemplate")
	mmCheck:SetSize(24, 24)
	mmCheck:SetPoint("RIGHT", mmLabel, "LEFT", -4, 0)

	local drag = CreateFrame("Frame", nil, titleBar)
	drag:SetPoint("TOPLEFT", titleBar, "TOPLEFT", 6, 0)
	drag:SetPoint("BOTTOMRIGHT", mmCheck, "BOTTOMLEFT", -10, 0)
	drag:EnableMouse(true)
	drag:RegisterForDrag("LeftButton")
	drag:SetScript("OnDragStart", function() f:StartMoving() end)
	drag:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

	local container = CreateFrame("Frame", nil, f)
	container:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -40)
	container:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)
	SkinCell(container, { 0.24, 0.24, 0.24, 1.0 }, true)

	local leftPane = CreateFrame("Frame", nil, container)
	leftPane:SetPoint("TOPLEFT", container, "TOPLEFT", 10, -10)
	leftPane:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 10, 10)
	leftPane:SetWidth(320)
	SkinCell(leftPane, { 0.20, 0.20, 0.20, 1.0 }, true)

	local rightPane = CreateFrame("Frame", nil, container)
	rightPane:SetPoint("TOPLEFT", leftPane, "TOPRIGHT", 12, 0)
	rightPane:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -10, 10)
	SkinCell(rightPane, { 0.20, 0.20, 0.20, 1.0 }, true)

	MakeLabel(leftPane, "CooldownViewers", "GameFontNormal"):SetPoint("TOPLEFT", leftPane, "TOPLEFT", 12, -12)

	local leftListCell = CreateFrame("Frame", nil, leftPane)
	leftListCell:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 12, -44)
	leftListCell:SetPoint("BOTTOMRIGHT", leftPane, "BOTTOMRIGHT", -12, 40)
	SkinCell(leftListCell, { 0.16, 0.16, 0.16, 1.0 }, true)

	local listScroll = CreateFrame("ScrollFrame", nil, leftListCell, "UIPanelScrollFrameTemplate")
	listScroll:SetPoint("TOPLEFT", leftListCell, "TOPLEFT", 8, -8)
	listScroll:SetPoint("BOTTOMRIGHT", leftListCell, "BOTTOMRIGHT", -30, 8)

	local listContent = CreateFrame("Frame", nil, listScroll)
	listContent:SetSize(1, 1)
	listScroll:SetScrollChild(listContent)

	local status = MakeLabel(leftPane, "", "GameFontDisableSmall")
	status:SetPoint("BOTTOMLEFT", leftPane, "BOTTOMLEFT", 14, 12)

	local generalCell = CreateFrame("Frame", nil, rightPane)
	generalCell:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 12, -12)
	generalCell:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -12, -12)
	generalCell:SetHeight(150)
	SkinCell(generalCell, { 0.16, 0.16, 0.16, 1.0 }, true)

	local viewerCell = CreateFrame("Frame", nil, rightPane)
	viewerCell:SetPoint("TOPLEFT", generalCell, "BOTTOMLEFT", 0, -12)
	viewerCell:SetPoint("TOPRIGHT", generalCell, "BOTTOMRIGHT", 0, -12)
	viewerCell:SetPoint("BOTTOMLEFT", rightPane, "BOTTOMLEFT", 12, 62)
	viewerCell:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -12, 62)
	SkinCell(viewerCell, { 0.16, 0.16, 0.16, 1.0 }, true)

	local buttonsCell = CreateFrame("Frame", nil, rightPane)
	buttonsCell:SetPoint("BOTTOMLEFT", rightPane, "BOTTOMLEFT", 12, 12)
	buttonsCell:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -12, 12)
	buttonsCell:SetHeight(38)
	SkinCell(buttonsCell, { 0.16, 0.16, 0.16, 1.0 }, true)

	MakeLabel(generalCell, "General", "GameFontNormal"):SetPoint("TOPLEFT", generalCell, "TOPLEFT", 12, -10)

	local refreshBtn = CreateFrame("Button", nil, generalCell, "UIPanelButtonTemplate")
	refreshBtn:SetSize(170, 22)
	refreshBtn:SetPoint("TOPRIGHT", generalCell, "TOPRIGHT", -12, -10)
	refreshBtn:SetText("Scan for viewers")
	StyleGreyButton(refreshBtn)

	local useChar = CreateCheck(generalCell, "Use character-specific settings", "TOPLEFT", generalCell, 12, -38, 280)
	local defaultNew = CreateCheck(generalCell, "New viewers default to swipe ON", "TOPLEFT", generalCell, 12, -66, 280)
	local compactCB = CreateCheck(generalCell, "Compact rows", "TOPLEFT", generalCell, 12, -94, 280)

	MakeLabel(viewerCell, "Viewer settings", "GameFontNormal"):SetPoint("TOPLEFT", viewerCell, "TOPLEFT", 12, -10)

	local selLabel = MakeLabel(viewerCell, "Selected viewer:", "GameFontNormalSmall")
	selLabel:SetPoint("TOPLEFT", viewerCell, "TOPLEFT", 12, -36)
	local selName = MakeLabel(viewerCell, "None", "GameFontHighlight")
	selName:SetPoint("LEFT", selLabel, "RIGHT", 8, 0)

	local swipeCB = CreateCheck(viewerCell, "Enable swipe", "TOPLEFT", viewerCell, 12, -64, 220)
	local moveDurCB = CreateCheck(viewerCell, "Move duration text", "TOPLEFT", viewerCell, 12, -88, 220)
	local moveStkCB = CreateCheck(viewerCell, "Move stack text", "TOPLEFT", viewerCell, 260, -88, 200)

	MakeLabel(viewerCell, "Duration", "GameFontNormalSmall"):SetPoint("TOPLEFT", viewerCell, "TOPLEFT", 12, -120)

	local durRow = CreateFrame("Frame", nil, viewerCell)
	durRow:SetPoint("TOPLEFT", viewerCell, "TOPLEFT", 12, -138)
	durRow:SetPoint("TOPRIGHT", viewerCell, "TOPRIGHT", -12, -138)
	durRow:SetHeight(32)

	MakeLabel(durRow, "Anchor:", "GameFontNormalSmall"):SetPoint("LEFT", durRow, "LEFT", 0, 0)
	local durAnchorDD = CreateAnchorDropdown(durRow, 140)
	durAnchorDD:SetPoint("LEFT", durRow, "LEFT", 52, -2)

	MakeLabel(durRow, "X:", "GameFontNormalSmall"):SetPoint("LEFT", durAnchorDD, "RIGHT", -2, 0)
	local durXBox = MakeNumberBox(durRow, 56)
	durXBox:SetPoint("LEFT", durAnchorDD, "RIGHT", 18, 0)

	MakeLabel(durRow, "Y:", "GameFontNormalSmall"):SetPoint("LEFT", durXBox, "RIGHT", 10, 0)
	local durYBox = MakeNumberBox(durRow, 56)
	durYBox:SetPoint("LEFT", durXBox, "RIGHT", 28, 0)

	local durResetBtn = CreateFrame("Button", nil, durRow, "UIPanelButtonTemplate")
	durResetBtn:SetSize(80, 22)
	durResetBtn:SetPoint("LEFT", durYBox, "RIGHT", 12, 0)
	durResetBtn:SetText("Reset")
	StyleGreyButton(durResetBtn)

	MakeLabel(viewerCell, "Stacks", "GameFontNormalSmall"):SetPoint("TOPLEFT", durRow, "BOTTOMLEFT", 0, -14)

	local stkRow = CreateFrame("Frame", nil, viewerCell)
	stkRow:SetPoint("TOPLEFT", viewerCell, "TOPLEFT", 12, -206)
	stkRow:SetPoint("TOPRIGHT", viewerCell, "TOPRIGHT", -12, -206)
	stkRow:SetHeight(32)

	MakeLabel(stkRow, "Anchor:", "GameFontNormalSmall"):SetPoint("LEFT", stkRow, "LEFT", 0, 0)
	local stkAnchorDD = CreateAnchorDropdown(stkRow, 140)
	stkAnchorDD:SetPoint("LEFT", stkRow, "LEFT", 52, -2)

	MakeLabel(stkRow, "X:", "GameFontNormalSmall"):SetPoint("LEFT", stkAnchorDD, "RIGHT", -2, 0)
	local stkXBox = MakeNumberBox(stkRow, 56)
	stkXBox:SetPoint("LEFT", stkAnchorDD, "RIGHT", 18, 0)

	MakeLabel(stkRow, "Y:", "GameFontNormalSmall"):SetPoint("LEFT", stkXBox, "RIGHT", 10, 0)
	local stkYBox = MakeNumberBox(stkRow, 56)
	stkYBox:SetPoint("LEFT", stkXBox, "RIGHT", 28, 0)

	local stkResetBtn = CreateFrame("Button", nil, stkRow, "UIPanelButtonTemplate")
	stkResetBtn:SetSize(80, 22)
	stkResetBtn:SetPoint("LEFT", stkYBox, "RIGHT", 12, 0)
	stkResetBtn:SetText("Reset")
	StyleGreyButton(stkResetBtn)

	local enableAllBtn = CreateFrame("Button", nil, buttonsCell, "UIPanelButtonTemplate")
	enableAllBtn:SetText("Enable all"); StyleGreyButton(enableAllBtn)
	local disableAllBtn = CreateFrame("Button", nil, buttonsCell, "UIPanelButtonTemplate")
	disableAllBtn:SetText("Disable all"); StyleGreyButton(disableAllBtn)
	local resetAllBtn = CreateFrame("Button", nil, buttonsCell, "UIPanelButtonTemplate")
	resetAllBtn:SetText("Reset all offsets"); StyleGreyButton(resetAllBtn)

	local function LayoutBottomButtons()
		local w = buttonsCell:GetWidth() or 0
		if w <= 0 then return end
		local gap, bh, inset = 12, 20, 12
		local bw = math.floor((w - (inset * 2) - (gap * 2)) / 3)
		if bw > 150 then bw = 150 end
		if bw < 90 then bw = 90 end
		local groupW = (bw * 3) + (gap * 2)
		local startX = math.floor((w - groupW) / 2)
		if startX < inset then startX = inset end

		enableAllBtn:SetSize(bw, bh)
		disableAllBtn:SetSize(bw, bh)
		resetAllBtn:SetSize(bw, bh)

		enableAllBtn:ClearAllPoints()
		disableAllBtn:ClearAllPoints()
		resetAllBtn:ClearAllPoints()

		enableAllBtn:SetPoint("LEFT", buttonsCell, "LEFT", startX, 0)
		disableAllBtn:SetPoint("LEFT", enableAllBtn, "RIGHT", gap, 0)
		resetAllBtn:SetPoint("LEFT", disableAllBtn, "RIGHT", gap, 0)
	end
	buttonsCell:SetScript("OnSizeChanged", LayoutBottomButtons)
	C_Timer.After(0, LayoutBottomButtons)

	local function SelectedViewer()
		local db = BST:GetActiveDB(); EnsureTables(db)
		local vn = db.ui.selectedViewer
		if not vn or vn == "" then return nil end
		return vn
	end

	local function InitAnchorDropdown(dd, getter, setter)
		UIDropDownMenu_Initialize(dd, function(_, level)
			local info = UIDropDownMenu_CreateInfo()
			for i = 1, #ANCHORS do
				local key = ANCHORS[i].key
				info.text = ANCHORS[i].text
				info.checked = (getter() == key)
				info.func = function()
					setter(key)
					UIDropDownMenu_SetText(dd, ANCHOR_TEXT[key] or key)
				end
				UIDropDownMenu_AddButton(info, level)
			end
		end)
	end

	InitAnchorDropdown(durAnchorDD,
		function()
			local vn = SelectedViewer(); if not vn then return "CENTER" end
			return (select(1, BST:GetDurationPos(vn)))
		end,
		function(newAnchor)
			local vn = SelectedViewer(); if not vn then return end
			local _, x, y = BST:GetDurationPos(vn)
			BST:SetDurationPos(vn, newAnchor, x, y)
		end
	)

	InitAnchorDropdown(stkAnchorDD,
		function()
			local vn = SelectedViewer(); if not vn then return "BOTTOMRIGHT" end
			return (select(1, BST:GetStackPos(vn)))
		end,
		function(newAnchor)
			local vn = SelectedViewer(); if not vn then return end
			local _, x, y = BST:GetStackPos(vn)
			BST:SetStackPos(vn, newAnchor, x, y)
		end
	)

	mmCheck:SetScript("OnClick", function(btn)
		local db = BST:GetActiveDB(); EnsureTables(db)
		db.minimap.show = not not btn:GetChecked()
		BST:UpdateMinimapButton()
	end)

	useChar:SetScript("OnClick", function(btn) BST:SetUseCharacterSettings(btn:GetChecked()) end)

	defaultNew:SetScript("OnClick", function(btn)
		local db = BST:GetActiveDB(); EnsureTables(db)
		db.defaultNewViewerSwipe = not not btn:GetChecked()
	end)

	compactCB:SetScript("OnClick", function(btn)
		local db = BST:GetActiveDB(); EnsureTables(db)
		db.ui.compact = not not btn:GetChecked()
		BST:RefreshConfigIfOpen()
	end)

	refreshBtn:SetScript("OnClick", function()
		BST:DiscoverViewersGlobal(true)
		BST:RefreshConfigIfOpen()
		BST:StartScan("MANUAL", 12, 0.03, 0.35)
	end)

	enableAllBtn:SetScript("OnClick", function() BST:SetAllSwipe(true) end)
	disableAllBtn:SetScript("OnClick", function() BST:SetAllSwipe(false) end)
	resetAllBtn:SetScript("OnClick", function() BST:ResetAllOffsets() end)

	swipeCB:SetScript("OnClick", function(btn)
		local vn = SelectedViewer()
		if not vn then btn:SetChecked(false); return end
		BST:SetSwipeEnabled(vn, btn:GetChecked())
	end)

	moveDurCB:SetScript("OnClick", function(btn)
		local vn = SelectedViewer()
		if not vn then btn:SetChecked(false); return end
		BST:SetMoveDurationEnabled(vn, btn:GetChecked())
	end)

	moveStkCB:SetScript("OnClick", function(btn)
		local vn = SelectedViewer()
		if not vn then btn:SetChecked(false); return end
		BST:SetMoveStacksEnabled(vn, btn:GetChecked())
	end)

	local function CommitDurXY()
		local vn = SelectedViewer(); if not vn then return end
		local a = select(1, BST:GetDurationPos(vn))
		local newX = ClampInt(durXBox:GetText(), -200, 200)
		local newY = ClampInt(durYBox:GetText(), -200, 200)
		BST:SetDurationPos(vn, a, newX, newY)
	end
	durXBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); CommitDurXY() end)
	durYBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); CommitDurXY() end)
	durXBox:SetScript("OnEditFocusLost", CommitDurXY)
	durYBox:SetScript("OnEditFocusLost", CommitDurXY)

	local function CommitStkXY()
		local vn = SelectedViewer(); if not vn then return end
		local a = select(1, BST:GetStackPos(vn))
		local newX = ClampInt(stkXBox:GetText(), -200, 200)
		local newY = ClampInt(stkYBox:GetText(), -200, 200)
		BST:SetStackPos(vn, a, newX, newY)
	end
	stkXBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); CommitStkXY() end)
	stkYBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); CommitStkXY() end)
	stkXBox:SetScript("OnEditFocusLost", CommitStkXY)
	stkYBox:SetScript("OnEditFocusLost", CommitStkXY)

	durResetBtn:SetScript("OnClick", function()
		local vn = SelectedViewer(); if not vn then return end
		BST:ResetDurationPos(vn)
	end)
	stkResetBtn:SetScript("OnClick", function()
		local vn = SelectedViewer(); if not vn then return end
		BST:ResetStackPos(vn)
	end)

	self.configFrame = f
	self.ui = {
		mmCheck = mmCheck,
		status = status,
		listScroll = listScroll,
		listContent = listContent,
		listButtons = {},
		useChar = useChar,
		defaultNew = defaultNew,
		compact = compactCB,
		selName = selName,
		swipeCB = swipeCB,
		moveDurCB = moveDurCB,
		moveStkCB = moveStkCB,
		durAnchorDD = durAnchorDD,
		durXBox = durXBox,
		durYBox = durYBox,
		durResetBtn = durResetBtn,
		stkAnchorDD = stkAnchorDD,
		stkXBox = stkXBox,
		stkYBox = stkYBox,
		stkResetBtn = stkResetBtn,
	}

	f:SetScript("OnShow", function()
		BST:DiscoverViewersFast()
		BST:RefreshConfig()
	end)
end

function BST:RefreshConfig()
	if not self.configFrame or not self.ui then return end
	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)

	self:DiscoverViewersFast()
	self.ui.mmCheck:SetChecked(not not db.minimap.show)
	self.ui.useChar:SetChecked(self:UseCharSettings())
	self.ui.defaultNew:SetChecked(not not db.defaultNewViewerSwipe)
	self.ui.compact:SetChecked(not not db.ui.compact)

	local names = self:GetSortedViewerNames()
	self.ui.status:SetText(("Viewers: %d"):format(#names))

	if db.ui.selectedViewer == "" and #names > 0 then
		db.ui.selectedViewer = names[1]
	elseif db.ui.selectedViewer ~= "" then
		local ok = false
		for i = 1, #names do if names[i] == db.ui.selectedViewer then ok = true break end end
		if not ok then db.ui.selectedViewer = (#names > 0) and names[1] or "" end
	end

	local ROW_H = db.ui.compact and 20 or 24
	local content = self.ui.listContent
	for _, b in ipairs(self.ui.listButtons) do b:Hide() end

	local y = -2
	local width = content:GetWidth()
	if not width or width < 40 then width = 260 end

	for i = 1, #names do
		local vn = names[i]
		local btn = self.ui.listButtons[i]
		if not btn then
			btn = CreateFrame("Button", nil, content)
			btn:EnableMouse(true)
			btn:RegisterForClicks("LeftButtonUp")
			btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
			btn:GetHighlightTexture():SetAlpha(0.18)

			btn.sel = btn:CreateTexture(nil, "BACKGROUND")
			btn.sel:SetAllPoints()
			btn.sel:SetColorTexture(1, 1, 1, 0.06)
			btn.sel:Hide()

			btn.dot = btn:CreateTexture(nil, "ARTWORK")
			btn.dot:SetSize(8, 8)
			btn.dot:SetPoint("LEFT", 8, 0)

			btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			btn.text:SetPoint("LEFT", btn.dot, "RIGHT", 8, 0)
			btn.text:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
			btn.text:SetJustifyH("LEFT")
			btn.text:SetWordWrap(false)
			btn.text:SetMaxLines(1)

			self.ui.listButtons[i] = btn
		end

		btn:ClearAllPoints()
		btn:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
		btn:SetSize(width, ROW_H)

		if vn == db.ui.selectedViewer then btn.sel:Show() else btn.sel:Hide() end
		if self:IsSwipeEnabled(vn) then btn.dot:SetColorTexture(0.10, 0.90, 0.20, 0.95)
		else btn.dot:SetColorTexture(0.90, 0.20, 0.20, 0.95) end

		btn.text:SetText(vn)
		btn:SetScript("OnClick", function() BST:SetSelectedViewer(vn) end)
		btn:Show()

		y = y - ROW_H
	end

	content:SetHeight(math.max(1, (#names * ROW_H) + 4))

	local selected = db.ui.selectedViewer
	if selected == "" then
		self.ui.selName:SetText("None")
		self.ui.swipeCB:SetChecked(false)
		self.ui.moveDurCB:SetChecked(false)
		self.ui.moveStkCB:SetChecked(false)

		self.ui.swipeCB:Disable()
		self.ui.moveDurCB:Disable()
		self.ui.moveStkCB:Disable()

		DisableDropDown(self.ui.durAnchorDD)
		DisableDropDown(self.ui.stkAnchorDD)
		self.ui.durXBox:Disable(); self.ui.durYBox:Disable(); self.ui.durResetBtn:Disable()
		self.ui.stkXBox:Disable(); self.ui.stkYBox:Disable(); self.ui.stkResetBtn:Disable()
	else
		self.ui.selName:SetText(selected)

		self.ui.swipeCB:Enable()
		self.ui.moveDurCB:Enable()
		self.ui.moveStkCB:Enable()

		self.ui.swipeCB:SetChecked(self:IsSwipeEnabled(selected))
		local md = self:IsMoveDurationEnabled(selected)
		local ms = self:IsMoveStacksEnabled(selected)
		self.ui.moveDurCB:SetChecked(md)
		self.ui.moveStkCB:SetChecked(ms)

		local da, dx, dy = self:GetDurationPos(selected)
		UIDropDownMenu_SetText(self.ui.durAnchorDD, ANCHOR_TEXT[da] or da)
		SetIfNotFocused(self.ui.durXBox, tostring(dx))
		SetIfNotFocused(self.ui.durYBox, tostring(dy))

		local sa, sx, sy = self:GetStackPos(selected)
		UIDropDownMenu_SetText(self.ui.stkAnchorDD, ANCHOR_TEXT[sa] or sa)
		SetIfNotFocused(self.ui.stkXBox, tostring(sx))
		SetIfNotFocused(self.ui.stkYBox, tostring(sy))

		if md then
			EnableDropDown(self.ui.durAnchorDD)
			self.ui.durXBox:Enable(); self.ui.durYBox:Enable(); self.ui.durResetBtn:Enable()
		else
			DisableDropDown(self.ui.durAnchorDD)
			self.ui.durXBox:Disable(); self.ui.durYBox:Disable(); self.ui.durResetBtn:Disable()
		end

		if ms then
			EnableDropDown(self.ui.stkAnchorDD)
			self.ui.stkXBox:Enable(); self.ui.stkYBox:Enable(); self.ui.stkResetBtn:Enable()
		else
			DisableDropDown(self.ui.stkAnchorDD)
			self.ui.stkXBox:Disable(); self.ui.stkYBox:Disable(); self.ui.stkResetBtn:Disable()
		end
	end
end

function BST:OpenConfig()
	SafeCall(function()
		self:BuildConfigWindow()
		self.configFrame:Show()
		self.configFrame:Raise()
	end)
end

function BST:ToggleConfig()
	SafeCall(function()
		self:BuildConfigWindow()
		if self.configFrame:IsShown() then self.configFrame:Hide() else self:OpenConfig() end
	end)
end

-- -------------------------------------------------------
-- Settings category
-- -------------------------------------------------------
function BST:RegisterSettingsCategory()
	if _G.Settings and type(_G.Settings.RegisterCanvasLayoutCategory) == "function" then
		local panel = CreateFrame("Frame"); panel:Hide()
		local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		btn:SetSize(220, 24)
		btn:SetPoint("TOPLEFT", 16, -16)
		btn:SetText("Open Buff Swipe Toggle")
		StyleGreyButton(btn)
		btn:SetScript("OnClick", function() BST:ToggleConfig() end)

		local cat = _G.Settings.RegisterCanvasLayoutCategory(panel, "Buff Swipe Toggle")
		_G.Settings.RegisterAddOnCategory(cat)
	end
end

-- -------------------------------------------------------
-- Minimap button
-- -------------------------------------------------------
function BST:GetMinimapDB()
	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)
	return db.minimap
end

function BST:UpdateMinimapButtonPosition()
	if not self.minimapButton then return end
	local mm = self:GetMinimapDB()
	local angle = (mm.angle or 220) * math.pi / 180
	local radius = 80
	local x = math.cos(angle) * radius
	local y = math.sin(angle) * radius
	self.minimapButton:ClearAllPoints()
	self.minimapButton:SetPoint("CENTER", _G.Minimap, "CENTER", x, y)
end

function BST:UpdateMinimapButton()
	if not self.minimapButton then return end
	local mm = self:GetMinimapDB()
	if mm.show then
		self.minimapButton:Show()
		self:UpdateMinimapButtonPosition()
	else
		self.minimapButton:Hide()
	end
end

function BST:CreateMinimapButton()
	if self.minimapButton or not _G.Minimap then return end

	local b = CreateFrame("Button", "BuffSwipeToggleMinimapButton", _G.Minimap)
	b:SetSize(32, 32)
	b:SetFrameStrata("MEDIUM")
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetClampedToScreen(true)

	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	icon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")

	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	hl:SetBlendMode("ADD")

	b:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
		GameTooltip:AddLine("Buff Swipe Toggle")
		GameTooltip:AddLine("Click: Toggle window", 0.9, 0.9, 0.9)
		GameTooltip:AddLine("Drag: Move", 0.9, 0.9, 0.9)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)

	b:SetScript("OnClick", function() BST:ToggleConfig() end)

	b:SetScript("OnDragStart", function(btn)
		btn:SetScript("OnUpdate", function()
			local cx, cy = GetCursorPosition()
			local scale = _G.UIParent:GetScale()
			cx, cy = cx / scale, cy / scale
			local mx, my = _G.Minimap:GetCenter()
			local dx, dy = cx - mx, cy - my
			local ang = math.atan(dy, dx)
			local deg = ang * 180 / math.pi
			local mm = BST:GetMinimapDB()
			mm.angle = deg
			BST:UpdateMinimapButtonPosition()
		end)
	end)
	b:SetScript("OnDragStop", function(btn) btn:SetScript("OnUpdate", nil) end)

	self.minimapButton = b
	self:UpdateMinimapButton()
end

-- -------------------------------------------------------
-- Addon Compartment
-- -------------------------------------------------------
function BuffSwipeToggle_OnAddonCompartmentClick()
	BST:ToggleConfig()
end

-- -------------------------------------------------------
-- Slash
-- -------------------------------------------------------
SLASH_BUFFSWIPETOGGLE1 = "/bst"
SlashCmdList["BUFFSWIPETOGGLE"] = function()
	SafeCall(function()
		BST:EnsureInit()
		BST:ToggleConfig()
	end)
end

-- -------------------------------------------------------
-- Events
-- -------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
		SafeCall(function() BST:InitDB() end)
		return
	end

	if event == "PLAYER_LOGIN" then
		SafeCall(function()
			BST:RegisterSettingsCategory()
			BST:CreateMinimapButton()
			BST:TryHookCooldownSetters()

			BST:DiscoverViewersFast()

			C_Timer.After(1.0, function()
				if InCombat() then return end
				BST:DiscoverViewersGlobal(false)
				BST:StartScan("LOGIN", 12, 0.03, 0.55)
			end)

			BST:Print("Loaded. Use /bst to open.")
		end)
		return
	end

	if event == "COOLDOWN_VIEWER_DATA_LOADED" then
		SafeCall(function()
			if InCombat() then return end
			BST:DiscoverViewersFast()
			BST:StartScan("CVDATA", 12, 0.03, 0.45)
		end)
		return
	end

	if event == "PLAYER_REGEN_DISABLED" then
		SafeCall(function()
			BST:CancelPostCombat()
			BST:StopScan()
		end)
		return
	end

	if event == "PLAYER_REGEN_ENABLED" then
		SafeCall(function()
			BST:PostCombatUpdate()
		end)
		return
	end
end)
