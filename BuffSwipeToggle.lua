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

-- Expose anchors to Options.lua
BST.ANCHORS = ANCHORS
BST.ANCHOR_TEXT = ANCHOR_TEXT

local function SafeAnchor(a)
	if a == "EDGE" then return "EDGETOP" end
	if ANCHOR_TEXT[a] then return a end
	return "CENTER"
end

BST.SafeAnchor = SafeAnchor

-- Safe frame name getter (prevents "calling GetName on bad self" from mixed objects)
local function SafeGetName(obj)
	if not obj then return nil end
	local fn = obj.GetName
	if type(fn) ~= "function" then return nil end
	local ok, name = pcall(fn, obj)
	if ok and type(name) == "string" and name ~= "" then
		return name
	end
	return nil
end

-- -------------------------------------------------------
-- Viewer name normalization (prevents random key swaps on reload)
-- -------------------------------------------------------
local function LooksLikeViewerName(name)
	return type(name) == "string" and name:find("CooldownViewer", 1, true) ~= nil
end

local function CanonicalViewerName(name)
	if type(name) ~= "string" then return nil end
	local n = name
	-- strip common prefixes from other addons
	n = n:gsub("^BCDM_", ""):gsub("^CDM_", ""):gsub("^CooldownManager_", "")
	-- strip overlay suffixes + numeric suffixes
	n = n:gsub("_?Overlay%d*$", "")
	n = n:gsub("%d+$", "")
	-- trim trailing underscores
	n = n:gsub("_+$", "")
	return n
end

function BST:NormalizeViewerName(vn)
	local c = CanonicalViewerName(vn)
	return c or vn
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
BST.EnsureTables = EnsureTables

local function NormalizeDBKeys(db)
	if type(db) ~= "table" then return end

	local function normKey(k)
		local c = CanonicalViewerName(k)
		return c or k
	end

	local function mergeMapField(field)
		local t = db[field]
		if type(t) ~= "table" then return end
		for k, v in pairs(t) do
			if type(k) == "string" then
				local nk = normKey(k)
				if nk ~= k then
					if t[nk] == nil then
						t[nk] = v
					elseif field == "knownViewers" then
						t[nk] = true
					end
					t[k] = nil
				end
			end
		end
	end

	for _, field in ipairs({ "knownViewers", "swipe", "moveDuration", "moveStacks", "durationPos", "stackPos", "textPos", "lastSeen" }) do
		mergeMapField(field)
	end

	if type(db.ui) == "table" and type(db.ui.selectedViewer) == "string" then
		db.ui.selectedViewer = normKey(db.ui.selectedViewer)
	end
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
	NormalizeDBKeys(BuffSwipeToggleDB)
	NormalizeDBKeys(BuffSwipeToggleCharDB)
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
	vn = self:NormalizeViewerName(vn)
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
	vn = self:NormalizeViewerName(vn)
	local db = self:GetActiveDB(); if not db then return end
	EnsureTables(db)
	db.lastSeen[vn] = time()
end

function BST:IsSwipeEnabled(vn)
	vn = self:NormalizeViewerName(vn)
	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	return not not db.swipe[vn]
end

function BST:IsMoveDurationEnabled(vn)
	vn = self:NormalizeViewerName(vn)
	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	return not not db.moveDuration[vn]
end

function BST:IsMoveStacksEnabled(vn)
	vn = self:NormalizeViewerName(vn)
	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	return not not db.moveStacks[vn]
end

function BST:GetDurationPos(vn)
	vn = self:NormalizeViewerName(vn)
	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	local p = db.durationPos[vn]
	return SafeAnchor(p.anchor), tonumber(p.x) or 0, tonumber(p.y) or 0
end

function BST:GetStackPos(vn)
	vn = self:NormalizeViewerName(vn)
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
		if type(k) == "string" and k:find("CooldownViewer", 1, true) and IsFrame(v) then
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
	for _ = 1, 18 do
		if not p then break end

		-- Most reliable: explicit viewerFrame field
		local vf = rawget(p, "viewerFrame")
		if vf and IsFrame(vf) and type(vf.GetName) == "function" then
			local vn = SafeGetName(vf)
			if vn and vn ~= "" then
				vn = CanonicalViewerName(vn) or vn
				if LooksLikeViewerName(vn) or (db and db.knownViewers and db.knownViewers[vn]) then
					return vn
				end
			end
		end

		-- Other common references
		for _, key in ipairs({ "cooldownViewer", "CooldownViewer", "viewer", "Viewer" }) do
			local ref = rawget(p, key)
			if ref and IsFrame(ref) and type(ref.GetName) == "function" then
				local vn = SafeGetName(ref)
				if vn and vn ~= "" then
					vn = CanonicalViewerName(vn) or vn
					if LooksLikeViewerName(vn) or (db and db.knownViewers and db.knownViewers[vn]) then
						return vn
					end
				end
			end
		end

		-- Name-based: accept *any* frame name that contains "CooldownViewer"
		if type(p.GetName) == "function" then
			local name = SafeGetName(p)
			if name and name ~= "" then
				local vn = CanonicalViewerName(name) or name
				if (db and db.knownViewers and db.knownViewers[vn]) then return vn end
				if LooksLikeViewerName(vn) then return vn end
			end
		end

		p = (type(p.GetParent) == "function") and p:GetParent() or nil
	end
	return nil
end

function BST:_TrackCooldown(cooldown, vn)
	vn = self:NormalizeViewerName(vn)
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
	vn = self:NormalizeViewerName(vn)
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
				-- Robust: catch both "item.Cooldown" patterns and direct Cooldown frames.
				local cd = nil

				-- Common item patterns
				cd = rawget(f, "Cooldown") or rawget(f, "cooldown") or rawget(f, "CooldownFrame") or rawget(f, "cooldownFrame")

				-- Sometimes the enumerated frame *is* the Cooldown
				if (not cd) and type(f.SetDrawSwipe) == "function" then
					cd = f
				end

				if cd and type(cd.SetDrawSwipe) == "function" then
					local vn = nil

					-- Prefer explicit viewerFrame links
					local vf = rawget(f, "viewerFrame") or rawget(cd, "viewerFrame")
					if vf and IsFrame(vf) and type(vf.GetName) == "function" then
						vn = SafeGetName(vf)
					end

					-- Fallback: parent-chain resolve (accepts Overlay + prefixed names)
					if not vn then
						vn = ResolveViewerNameFromChain(cd, db) or ResolveViewerNameFromChain(f, db)
					end

					if vn then
						BST:ApplyToCooldown(cd, vn)
					end
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
-- UI stubs (implemented in Options.lua)
-- -------------------------------------------------------
function BST:RegisterSettingsCategory() end

function BST:ToggleConfig()
	if type(self.OpenConfig) == "function" then
		return self:OpenConfig()
	end
	self:Print("Options.lua is not loaded (UI unavailable).")
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

			-- Early scan + late rescan (avoids "sometimes works" when viewers build late / use Overlay variants)
			C_Timer.After(0.45, function()
				if InCombat() then return end
				BST:DiscoverViewersGlobal(true)
				if not BST._scanTicker then
					BST:StartScan("LOGIN", 36, 0.02, 0.05)
				end
			end)

			C_Timer.After(6.0, function()
				if InCombat() then return end
				BST:DiscoverViewersGlobal(true)
				if not BST._scanTicker then
					BST:StartScan("LOGIN_LATE", 36, 0.02, 0.05)
				end
			end)

			BST:Print("Loaded. Use /bst to open.")
		end)
		return
	end

	if event == "COOLDOWN_VIEWER_DATA_LOADED" then
		SafeCall(function()
			if InCombat() then return end
			BST:DiscoverViewersFast()
			BST:StartScan("CVDATA", 36, 0.02, 0.10)
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