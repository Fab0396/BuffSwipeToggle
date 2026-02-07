-- BuffSwipeToggle.lua
-- Fix for: "attempt to compare local 'p' (a secret value)"
-- Changes:
-- - NEVER directly compare GetPoint() returns (p/rp/ox/oy) with == anymore.
-- - PointName() no longer calls :find() on secret strings (uses safe tostring).
-- - IsFSAtDesired() uses SafeEq for p/rp and SafeNum for ox/oy.
-- - Keeps the “don’t reposition text in combat” safeguard + re-apply after combat.

local ADDON_NAME = ...
local BST = {}
_G.BuffSwipeToggle = BST

BuffSwipeToggleDB = BuffSwipeToggleDB or nil
BuffSwipeToggleCharDB = BuffSwipeToggleCharDB or nil

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

local DEFAULTS = {
	minimap = { show = true, angle = 220 },
	useCharacterSettings = false,
	defaultNewViewerSwipe = true,

	knownViewers = {},
	swipe = {},

	durationPos = {},
	stackPos = {},

	textPos = {}, -- legacy
	lastSeen = {},

	ui = {
		compact = false,
		selectedViewer = "",
	},
}

BST._viewerByCooldown   = setmetatable({}, { __mode = "k" })
BST._appliedByCooldown  = setmetatable({}, { __mode = "k" })
BST._cooldownsByViewer  = {}
BST._fullScanPending    = false
BST._lastFullScan       = 0

-- -------------------------------------------------------
-- Utilities
-- -------------------------------------------------------

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
	db.durationPos = db.durationPos or {}
	db.stackPos = db.stackPos or {}
	db.textPos = db.textPos or {}
	db.lastSeen = db.lastSeen or {}
	db.ui = db.ui or {}
	if db.ui.compact == nil then db.ui.compact = false end
	if db.ui.selectedViewer == nil then db.ui.selectedViewer = "" end
end

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

local function IsFrame(v)
	return type(v) == "table" and type(v.GetObjectType) == "function" and v:GetObjectType() == "Frame"
end

local function IsFontString(o)
	return type(o) == "table" and type(o.GetObjectType) == "function" and o:GetObjectType() == "FontString"
end

local function ClampInt(n, lo, hi)
	n = tonumber(n)
	if not n then return 0 end
	n = math.floor(n + 0.5)
	if n < lo then n = lo end
	if n > hi then n = hi end
	return n
end

local function IsNumericText(s)
	return type(s) == "string" and s ~= "" and s:match("%d")
end

-- Backwards compat: old "EDGE" -> EDGETOP
local function SafeAnchor(a)
	if a == "EDGE" then return "EDGETOP" end
	if ANCHOR_TEXT[a] then return a end
	return "CENTER"
end

-- Safe equality (secret-value safe)
local function SafeEq(a, b)
	local ok, res = pcall(function() return a == b end)
	return ok and res or false
end

-- Safe tostring (secret-value safe)
local function SafeToString(v)
	if v == nil then return "" end
	local ok, s = pcall(function() return tostring(v) end)
	if ok and type(s) == "string" then return s end
	return ""
end

-- Safe tonumber (secret-value safe)
local function SafeNum(v)
	if v == nil then return 0 end
	local ok, n = pcall(function() return tonumber(v) end)
	if ok and n then return n end
	return 0
end

-- Safe GetPoint
local function SafeGetPoint(fs)
	if not fs or type(fs.GetPoint) ~= "function" then return nil end
	local ok, p, rel, rp, ox, oy = pcall(fs.GetPoint, fs, 1)
	if not ok then return nil end
	return p, rel, rp, ox, oy
end

-- Edge Top/Bottom: text CENTER sits on the edge line
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

-- -------------------------------------------------------
-- DB / active profile
-- -------------------------------------------------------

function BST:GetAccountDB() return BuffSwipeToggleDB end
function BST:GetCharDB() return BuffSwipeToggleCharDB end

function BST:UseCharSettings()
	local c = self:GetCharDB()
	return c and c.useCharacterSettings
end

function BST:GetActiveDB()
	return self:UseCharSettings() and self:GetCharDB() or self:GetAccountDB()
end

function BST:InitDB()
	BuffSwipeToggleDB = DeepCopyDefaults(BuffSwipeToggleDB or {}, DEFAULTS)
	BuffSwipeToggleCharDB = DeepCopyDefaults(BuffSwipeToggleCharDB or {}, DEFAULTS)
	EnsureTables(BuffSwipeToggleDB)
	EnsureTables(BuffSwipeToggleCharDB)
	self._dbReady = true
end

function BST:EnsureInit()
	if not self._dbReady then self:InitDB() end
end

-- -------------------------------------------------------
-- Viewer defaults + settings
-- -------------------------------------------------------

function BST:EnsureViewerDefaults(vn)
	if not vn or vn == "" then return end
	self:EnsureInit()
	local db = self:GetActiveDB()
	if not db then return end
	EnsureTables(db)

	db.knownViewers[vn] = true

	if db.swipe[vn] == nil then
		db.swipe[vn] = not not db.defaultNewViewerSwipe
	end

	-- legacy migrate
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

	if db.lastSeen[vn] == nil then
		db.lastSeen[vn] = 0
	end

	if not self._cooldownsByViewer[vn] then
		self._cooldownsByViewer[vn] = setmetatable({}, { __mode = "k" })
	end
end

function BST:MarkSeen(vn)
	if not vn or vn == "" then return end
	local db = self:GetActiveDB()
	if not db then return end
	EnsureTables(db)
	db.lastSeen[vn] = time()
end

function BST:IsSwipeEnabled(vn)
	self:EnsureInit()
	local db = self:GetActiveDB()
	if not db then return false end
	EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	return not not db.swipe[vn]
end

function BST:GetDurationPos(vn)
	self:EnsureInit()
	local db = self:GetActiveDB(); if not db then return "CENTER", 0, 0 end
	EnsureTables(db); self:EnsureViewerDefaults(vn)
	local p = db.durationPos[vn]
	return SafeAnchor(p.anchor), tonumber(p.x) or 0, tonumber(p.y) or 0
end

function BST:GetStackPos(vn)
	self:EnsureInit()
	local db = self:GetActiveDB(); if not db then return "BOTTOMRIGHT", 0, 0 end
	EnsureTables(db); self:EnsureViewerDefaults(vn)
	local p = db.stackPos[vn]
	return SafeAnchor(p.anchor), tonumber(p.x) or 0, tonumber(p.y) or 0
end

function BST:SetDurationPos(vn, anchor, x, y)
	self:EnsureInit()
	local db = self:GetActiveDB(); if not db then return end
	EnsureTables(db); self:EnsureViewerDefaults(vn)
	local p = db.durationPos[vn]
	anchor = SafeAnchor(anchor)
	x = tonumber(x) or 0
	y = tonumber(y) or 0
	if p.anchor == anchor and p.x == x and p.y == y then return end
	p.anchor, p.x, p.y = anchor, x, y
	self:ApplyViewerCooldowns(vn)
	self:RefreshConfig()
end

function BST:SetStackPos(vn, anchor, x, y)
	self:EnsureInit()
	local db = self:GetActiveDB(); if not db then return end
	EnsureTables(db); self:EnsureViewerDefaults(vn)
	local p = db.stackPos[vn]
	anchor = SafeAnchor(anchor)
	x = tonumber(x) or 0
	y = tonumber(y) or 0
	if p.anchor == anchor and p.x == x and p.y == y then return end
	p.anchor, p.x, p.y = anchor, x, y
	self:ApplyViewerCooldowns(vn)
	self:RefreshConfig()
end

function BST:ResetDurationPos(vn) self:SetDurationPos(vn, "CENTER", 0, 0) end
function BST:ResetStackPos(vn) self:SetStackPos(vn, "BOTTOMRIGHT", 0, 0) end

function BST:SetUseCharacterSettings(flag)
	self:EnsureInit()
	local c = self:GetCharDB()
	if not c then return end
	c.useCharacterSettings = not not flag

	if c.useCharacterSettings then
		local a = self:GetAccountDB()
		EnsureTables(a); EnsureTables(c)
		if c.defaultNewViewerSwipe == nil then c.defaultNewViewerSwipe = a.defaultNewViewerSwipe end
		if c.minimap.show == nil then c.minimap.show = a.minimap.show end
		if c.minimap.angle == nil then c.minimap.angle = a.minimap.angle end
		if c.ui.compact == nil then c.ui.compact = a.ui.compact end
		if c.ui.selectedViewer == nil then c.ui.selectedViewer = a.ui.selectedViewer end
	end

	self:UpdateMinimapButton()
	self:RefreshConfig()
	self:ApplyAllKnownCooldowns()
end

function BST:SetSwipeEnabled(vn, flag)
	self:EnsureInit()
	local db = self:GetActiveDB()
	EnsureTables(db)
	self:EnsureViewerDefaults(vn)

	local newVal = not not flag
	if db.swipe[vn] == newVal then
		self:RefreshConfig()
		return
	end

	db.swipe[vn] = newVal
	self:ApplyViewerCooldowns(vn)
	self:RefreshConfig()
end

function BST:SetAllSwipe(flag)
	self:EnsureInit()
	local db = self:GetActiveDB()
	EnsureTables(db)

	local val = not not flag
	for vn in pairs(db.knownViewers) do
		self:EnsureViewerDefaults(vn)
		db.swipe[vn] = val
	end

	self:ApplyAllKnownCooldowns()
	self:RefreshConfig()
end

function BST:ResetAllOffsets()
	self:EnsureInit()
	local db = self:GetActiveDB(); EnsureTables(db)
	for vn in pairs(db.knownViewers) do
		self:EnsureViewerDefaults(vn)
		db.durationPos[vn].anchor, db.durationPos[vn].x, db.durationPos[vn].y = "CENTER", 0, 0
		db.stackPos[vn].anchor, db.stackPos[vn].x, db.stackPos[vn].y = "BOTTOMRIGHT", 0, 0
	end
	self:ApplyAllKnownCooldowns()
	self:RefreshConfig()
end

-- -------------------------------------------------------
-- Viewer discovery
-- -------------------------------------------------------

function BST:DiscoverViewersCheap()
	self:EnsureInit()
	local db = self:GetActiveDB()
	EnsureTables(db)

	for _, name in ipairs({ "BuffIconCooldownViewer", "EssentialCooldownViewer", "UtilityCooldownViewer" }) do
		if _G[name] and IsFrame(_G[name]) then
			self:EnsureViewerDefaults(name)
			self:MarkSeen(name)
		end
	end

	for k, v in pairs(_G) do
		if type(k) == "string" and k:match("CooldownViewer$") and IsFrame(v) then
			self:EnsureViewerDefaults(k)
			self:MarkSeen(k)
		end
	end
end

function BST:GetViewerNamesRaw()
	self:EnsureInit()
	local db = self:GetActiveDB()
	EnsureTables(db)
	local t = {}
	for vn in pairs(db.knownViewers) do t[#t + 1] = vn end
	return t
end

function BST:GetSortedViewerNames()
	self:DiscoverViewersCheap()
	local names = self:GetViewerNamesRaw()
	table.sort(names)
	return names
end

-- -------------------------------------------------------
-- Resolve viewer from chain
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
				if db and db.knownViewers and db.knownViewers[name] then
					return name
				end
				if name:match("CooldownViewer$") and _G[name] and IsFrame(_G[name]) then
					return name
				end
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
-- Find duration / stacks FontStrings
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
	local _, size = fs.GetFont and fs:GetFont()
	return tonumber(size) or 0
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
			if pName:find("CENTER") then score = score + 25 end
			if pName:find("TOP") then score = score + 10 end
			if pName:find("BOTTOMRIGHT") then score = score - 35 end

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

			if pName:find("BOTTOMRIGHT") then score = score + 40 end
			if pName:find("BOTTOM") then score = score + 15 end
			if pName:find("RIGHT") then score = score + 10 end
			if pName:find("CENTER") then score = score - 10 end
			if pName:find("TOP") then score = score - 20 end

			local _, rel = SafeGetPoint(fs)
			if rel and parent and SafeEq(rel, parent) then score = score + 15 end
			if rel and SafeEq(rel, cooldown) then score = score + 10 end

			if score > bestScore then best, bestScore = fs, score end
		end
	end
	return best
end

-- -------------------------------------------------------
-- Enforcers
-- -------------------------------------------------------

function BST:_EnsureSwipeEnforcer(cooldown)
	if cooldown._bstSwipeHooked then return end
	if type(cooldown.SetDrawSwipe) ~= "function" then return end
	cooldown._bstSwipeHooked = true

	hooksecurefunc(cooldown, "SetDrawSwipe", function(cd, val)
		if cd._bstSwipeGuard then return end
		local db = BST:GetActiveDB(); EnsureTables(db)
		local vn = BST._viewerByCooldown[cd] or ResolveViewerNameFromChain(cd, db)
		if not vn then return end

		BST:EnsureViewerDefaults(vn)
		local desired = BST:IsSwipeEnabled(vn)

		if val ~= desired then
			cd._bstSwipeGuard = true
			pcall(cd.SetDrawSwipe, cd, desired)
			cd._bstSwipeGuard = false
		end
	end)
end

-- Secret-safe "already positioned?" check (no direct == on GetPoint returns)
local function IsFSAtDesired(fs, cooldown, anchor, x, y)
	local pWant, rpWant, dxWant, dyWant = GetDesiredPoint(anchor, x, y)
	local p, rel, rp, ox, oy = SafeGetPoint(fs)
	if p == nil then return false end

	-- rel compare can be done safely
	if not SafeEq(rel, cooldown) then return false end

	-- p/rp may be secret strings: SafeEq handles that
	if not SafeEq(p, pWant) then return false end
	if not SafeEq(rp, rpWant) then return false end

	-- ox/oy may be secret numeric: SafeNum handles that
	if SafeNum(ox) ~= dxWant then return false end
	if SafeNum(oy) ~= dyWant then return false end

	return true
end

function BST:_EnsureTextEnforcer(cooldown, fs, which)
	if not cooldown or not fs or not IsFontString(fs) then return end
	if fs._bstTextHooked and fs._bstHookWhich == which and fs._bstHookCooldown == cooldown then
		return
	end

	fs._bstTextHooked = true
	fs._bstHookWhich = which
	fs._bstHookCooldown = cooldown

	hooksecurefunc(fs, "SetPoint", function(font)
		-- Still avoid enforcement in combat (safe + prevents taint/blocked ops)
		if type(InCombatLockdown) == "function" and InCombatLockdown() then return end

		if font._bstTextGuard then return end
		if font._bstHookCooldown ~= cooldown then return end
		if font._bstHookWhich ~= which then return end

		local db = BST:GetActiveDB(); EnsureTables(db)
		local vn = BST._viewerByCooldown[cooldown] or ResolveViewerNameFromChain(cooldown, db)
		if not vn then return end

		local a, x2, y2
		if which == "duration" then
			a, x2, y2 = BST:GetDurationPos(vn)
		else
			a, x2, y2 = BST:GetStackPos(vn)
		end

		if IsFSAtDesired(font, cooldown, a, x2, y2) then return end

		font._bstTextGuard = true
		pcall(ApplyFS, font, cooldown, a, x2, y2)
		font._bstTextGuard = false
	end)
end

-- -------------------------------------------------------
-- Apply to cooldowns
-- -------------------------------------------------------

function BST:ApplyToCooldown(cooldown, viewerName)
	if not cooldown or type(cooldown.SetDrawSwipe) ~= "function" then return end

	self:EnsureInit()
	local db = self:GetActiveDB()
	EnsureTables(db)

	local vn = viewerName or self._viewerByCooldown[cooldown] or ResolveViewerNameFromChain(cooldown, db)
	if not vn then return end

	self:EnsureViewerDefaults(vn)
	self:MarkSeen(vn)
	self:_TrackCooldown(cooldown, vn)

	local st = self._appliedByCooldown[cooldown]
	if not st then st = {}; self._appliedByCooldown[cooldown] = st end

	-- Swipe always enforced (even in combat)
	self:_EnsureSwipeEnforcer(cooldown)
	local desiredSwipe = self:IsSwipeEnabled(vn)
	if st.swipe ~= desiredSwipe then
		cooldown._bstSwipeGuard = true
		pcall(cooldown.SetDrawSwipe, cooldown, desiredSwipe)
		cooldown._bstSwipeGuard = false
		st.swipe = desiredSwipe
	end

	-- If in combat: do not reposition duration/stacks
	local inCombat = (type(InCombatLockdown) == "function") and InCombatLockdown()
	if inCombat then return end

	-- Duration
	local durA, durX, durY = self:GetDurationPos(vn)
	local durFS = st.durFS
	if not (durFS and IsFontString(durFS)) then
		durFS = self:FindDurationText(cooldown)
	end
	if durFS then
		self:_EnsureTextEnforcer(cooldown, durFS, "duration")
		if st.durFS ~= durFS or st.durA ~= durA or st.durX ~= durX or st.durY ~= durY or not IsFSAtDesired(durFS, cooldown, durA, durX, durY) then
			durFS._bstTextGuard = true
			pcall(ApplyFS, durFS, cooldown, durA, durX, durY)
			durFS._bstTextGuard = false
			st.durFS, st.durA, st.durX, st.durY = durFS, durA, durX, durY
		end
	end

	-- Stacks
	local stkA, stkX, stkY = self:GetStackPos(vn)
	local stkFS = st.stkFS
	if not (stkFS and IsFontString(stkFS)) then
		stkFS = self:FindStackText(cooldown, durFS)
	end
	if stkFS then
		self:_EnsureTextEnforcer(cooldown, stkFS, "stack")
		if st.stkFS ~= stkFS or st.stkA ~= stkA or st.stkX ~= stkX or st.stkY ~= stkY or not IsFSAtDesired(stkFS, cooldown, stkA, stkX, stkY) then
			stkFS._bstTextGuard = true
			pcall(ApplyFS, stkFS, cooldown, stkA, stkX, stkY)
			stkFS._bstTextGuard = false
			st.stkFS, st.stkA, st.stkX, st.stkY = stkFS, stkA, stkX, stkY
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
-- Scanning / hooking
-- -------------------------------------------------------

function BST:ApplyToExistingFrames()
	local now = GetTime()
	if (now - (self._lastFullScan or 0)) < 0.25 then return end
	self._lastFullScan = now

	self:DiscoverViewersCheap()

	local f = EnumerateFrames()
	while f do
		if f.viewerFrame and IsFrame(f.viewerFrame) and f.Cooldown and type(f.Cooldown.SetDrawSwipe) == "function" then
			local vn = (type(f.viewerFrame.GetName) == "function") and f.viewerFrame:GetName() or nil
			if vn then self:ApplyToCooldown(f.Cooldown, vn) end
		end
		if type(f.SetDrawSwipe) == "function" then
			self:ApplyToCooldown(f, nil)
		end
		f = EnumerateFrames(f)
	end
end

function BST:RequestFullScan()
	if self._fullScanPending then return end
	self._fullScanPending = true
	C_Timer.After(0.05, function()
		BST._fullScanPending = false
		BST:ApplyToExistingFrames()
		BST:RefreshConfig()
	end)
end

function BST:TryHookCooldownSetters()
	if self._hookedCooldownSetters then return end
	self._hookedCooldownSetters = true

	local function OnCooldownTouched(cooldown)
		SafeCall(function() BST:ApplyToCooldown(cooldown, nil) end)
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
-- UI styling helpers
-- (UNCHANGED from your working build)
-- -------------------------------------------------------

local function MakeLabel(parent, text, template)
	local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
	fs:SetText(text)
	return fs
end

local function MakeNumberBox(parent, w)
	local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	eb:SetAutoFocus(false)
	eb:SetSize(w or 70, 20)
	eb:SetJustifyH("CENTER")
	eb:SetTextInsets(8, 8, 0, 0)
	return eb
end

local function SetIfNotFocused(editBox, text)
	if editBox and editBox.HasFocus and editBox:HasFocus() then return end
	if editBox and editBox.GetText and editBox:GetText() ~= text then
		editBox:SetText(text)
	end
end

local function GetCheckLabel(cb) return cb and (cb.Text or cb.text) end

local function CreateCheck(parent, text, anchor, rel, x, y, labelWidth)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetSize(24, 24)
	cb:SetPoint(anchor, rel, anchor, x, y)
	local l = GetCheckLabel(cb)
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

local function Border2px(frame)
	if frame._bstBorder then return end
	frame._bstBorder = true
	local border = 2
	local function mk()
		local x = frame:CreateTexture(nil, "BORDER")
		x:SetColorTexture(0, 0, 0, 1)
		return x
	end
	local top = mk()
	top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
	top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
	top:SetHeight(border)
	local bottom = mk()
	bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
	bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
	bottom:SetHeight(border)
	local left = mk()
	left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
	left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
	left:SetWidth(border)
	local right = mk()
	right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
	right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
	right:SetWidth(border)
end

local function FillOnly(frame, bg)
	if frame._bstFill then return end
	frame._bstFill = true
	local bgc = bg or { 0.22, 0.22, 0.22, 1.0 }
	local t = frame:CreateTexture(nil, "BACKGROUND")
	t:SetAllPoints()
	t:SetColorTexture(bgc[1], bgc[2], bgc[3], bgc[4])
	local shade = frame:CreateTexture(nil, "BACKGROUND")
	shade:SetAllPoints()
	shade:SetColorTexture(0, 0, 0, 0.06)
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
	shade:SetPoint("TOPLEFT", t, "TOPLEFT", 0, 0)
	shade:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", 0, 0)
	shade:SetColorTexture(0, 0, 0, 0.06)

	Border2px(frame)
end

local function StyleGreyButton(btn)
	if not btn or btn._bstGrey then return end
	btn._bstGrey = true

	local n = btn:CreateTexture(nil, "BACKGROUND")
	n:SetAllPoints()
	n:SetColorTexture(0.30, 0.30, 0.30, 1.0)

	local p = btn:CreateTexture(nil, "BACKGROUND")
	p:SetAllPoints()
	p:SetColorTexture(0.22, 0.22, 0.22, 1.0)

	local h = btn:CreateTexture(nil, "HIGHLIGHT")
	h:SetAllPoints()
	h:SetColorTexture(1, 1, 1, 0.08)

	btn:SetNormalTexture(n)
	btn:SetPushedTexture(p)
	btn:SetHighlightTexture(h)

	Border2px(btn)

	local fs = btn.GetFontString and btn:GetFontString()
	if fs then fs:SetTextColor(1, 1, 1) end
end

local function CreateAnchorDropdown(parent, width)
	local dd = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
	UIDropDownMenu_SetWidth(dd, width or 140)
	UIDropDownMenu_JustifyText(dd, "LEFT")
	return dd
end

-- -------------------------------------------------------
-- Config UI (same layout you had working)
-- -------------------------------------------------------

function BST:BuildConfigWindow()
	if self.configFrame then return end
	self:EnsureInit()

	local f = CreateFrame("Frame", "BuffSwipeToggleFrame", UIParent)
	f:SetSize(920, 570)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:Hide()
	f:EnableMouse(true)
	f:SetMovable(true)

	SkinCell(f, { 0.20, 0.20, 0.20, 1.0 }, true)

	-- ESC closes it
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

	-- Titlebar
	local titleBar = CreateFrame("Frame", nil, f)
	titleBar:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
	titleBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
	titleBar:SetHeight(28)
	FillOnly(titleBar, { 0.18, 0.18, 0.18, 1.0 })
	titleBar:EnableMouse(true)

	local sep = titleBar:CreateTexture(nil, "BORDER")
	sep:SetColorTexture(0, 0, 0, 1)
	sep:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
	sep:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
	sep:SetHeight(2)

	local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	titleText:SetPoint("CENTER", titleBar, "CENTER", 0, 0)
	titleText:SetText("Buff Swipe Toggle")

	local closeBtn = CreateFrame("Button", nil, titleBar, "UIPanelButtonTemplate")
	closeBtn:SetSize(24, 20)
	closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
	closeBtn:SetText("X")
	StyleGreyButton(closeBtn)
	closeBtn:SetScript("OnClick", function() f:Hide() end)

	local mmLabel = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	mmLabel:SetPoint("RIGHT", closeBtn, "LEFT", -10, 0)
	mmLabel:SetText("Minimap")

	local mmCheck = CreateFrame("CheckButton", nil, titleBar, "UICheckButtonTemplate")
	mmCheck:SetSize(24, 24)
	mmCheck:SetPoint("RIGHT", mmLabel, "LEFT", -4, 0)
	if mmCheck.SetFrameLevel then mmCheck:SetFrameLevel(titleBar:GetFrameLevel() + 5) end

	-- Drag region
	local drag = CreateFrame("Frame", nil, titleBar)
	drag:SetPoint("TOPLEFT", titleBar, "TOPLEFT", 6, 0)
	drag:SetPoint("BOTTOMRIGHT", mmCheck, "BOTTOMLEFT", -10, 0)
	drag:EnableMouse(true)
	drag:RegisterForDrag("LeftButton")
	drag:SetScript("OnDragStart", function() f:StartMoving() end)
	drag:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

	-- Container
	local container = CreateFrame("Frame", nil, f)
	container:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -40)
	container:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)
	SkinCell(container, { 0.24, 0.24, 0.24, 1.0 })

	-- Left pane
	local leftPane = CreateFrame("Frame", nil, container)
	leftPane:SetPoint("TOPLEFT", container, "TOPLEFT", 10, -10)
	leftPane:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 10, 10)
	leftPane:SetWidth(320)
	SkinCell(leftPane, { 0.20, 0.20, 0.20, 1.0 })

	-- Right pane
	local rightPane = CreateFrame("Frame", nil, container)
	rightPane:SetPoint("TOPLEFT", leftPane, "TOPRIGHT", 12, 0)
	rightPane:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -10, 10)
	SkinCell(rightPane, { 0.20, 0.20, 0.20, 1.0 })

	-- Left header
	local leftHeader = CreateFrame("Frame", nil, leftPane)
	leftHeader:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 12, -12)
	leftHeader:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -12, -12)
	leftHeader:SetHeight(26)

	local leftTitle = MakeLabel(leftHeader, "CooldownViewers", "GameFontNormal")
	leftTitle:SetPoint("LEFT", leftHeader, "LEFT", 0, 0)

	-- Left list cell
	local leftListCell = CreateFrame("Frame", nil, leftPane)
	leftListCell:SetPoint("TOPLEFT", leftHeader, "BOTTOMLEFT", 0, -10)
	leftListCell:SetPoint("BOTTOMLEFT", leftPane, "BOTTOMLEFT", 12, 40)
	leftListCell:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -12, -52)
	leftListCell:SetPoint("BOTTOMRIGHT", leftPane, "BOTTOMRIGHT", -12, 40)
	SkinCell(leftListCell, { 0.16, 0.16, 0.16, 1.0 })

	local listScroll = CreateFrame("ScrollFrame", nil, leftListCell, "UIPanelScrollFrameTemplate")
	listScroll:SetPoint("TOPLEFT", leftListCell, "TOPLEFT", 8, -8)
	listScroll:SetPoint("BOTTOMRIGHT", leftListCell, "BOTTOMRIGHT", -30, 8)
	listScroll:EnableMouseWheel(true)

	local listContent = CreateFrame("Frame", nil, listScroll)
	listContent:SetSize(1, 1)
	listScroll:SetScrollChild(listContent)

	listScroll:SetScript("OnMouseWheel", function(_, delta)
		local step = 24
		local cur = listScroll:GetVerticalScroll() or 0
		local max = listScroll:GetVerticalScrollRange() or 0
		local next = cur - (delta * step)
		if next < 0 then next = 0 end
		if next > max then next = max end
		listScroll:SetVerticalScroll(next)
	end)

	local function SyncListWidth()
		local w = listScroll:GetWidth()
		if w and w > 1 then listContent:SetWidth(w) end
	end
	listScroll:SetScript("OnSizeChanged", SyncListWidth)

	local status = MakeLabel(leftPane, "", "GameFontDisableSmall")
	status:SetPoint("BOTTOMLEFT", leftPane, "BOTTOMLEFT", 14, 12)

	-- Right cells
	local generalCell = CreateFrame("Frame", nil, rightPane)
	generalCell:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 12, -12)
	generalCell:SetPoint("TOPRIGHT", rightPane, "TOPRIGHT", -12, -12)
	generalCell:SetHeight(150)
	SkinCell(generalCell, { 0.16, 0.16, 0.16, 1.0 })

	local viewerCell = CreateFrame("Frame", nil, rightPane)
	viewerCell:SetPoint("TOPLEFT", generalCell, "BOTTOMLEFT", 0, -12)
	viewerCell:SetPoint("TOPRIGHT", generalCell, "BOTTOMRIGHT", 0, -12)
	viewerCell:SetPoint("BOTTOMLEFT", rightPane, "BOTTOMLEFT", 12, 62)
	viewerCell:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -12, 62)
	SkinCell(viewerCell, { 0.16, 0.16, 0.16, 1.0 })

	local buttonsCell = CreateFrame("Frame", nil, rightPane)
	buttonsCell:SetPoint("BOTTOMLEFT", rightPane, "BOTTOMLEFT", 12, 12)
	buttonsCell:SetPoint("BOTTOMRIGHT", rightPane, "BOTTOMRIGHT", -12, 12)
	buttonsCell:SetHeight(38)
	SkinCell(buttonsCell, { 0.16, 0.16, 0.16, 1.0 })

	-- GENERAL
	local generalTitle = MakeLabel(generalCell, "General", "GameFontNormal")
	generalTitle:SetPoint("TOPLEFT", generalCell, "TOPLEFT", 12, -10)

	local refreshBtn = CreateFrame("Button", nil, generalCell, "UIPanelButtonTemplate")
	refreshBtn:SetSize(150, 22)
	refreshBtn:SetPoint("TOPRIGHT", generalCell, "TOPRIGHT", -12, -10)
	refreshBtn:SetText("Refresh viewers")
	StyleGreyButton(refreshBtn)

	local useChar = CreateCheck(generalCell, "Use character-specific settings", "TOPLEFT", generalCell, 12, -38, 260)
	local defaultNew = CreateCheck(generalCell, "New viewers default to swipe ON", "TOPLEFT", generalCell, 12, -66, 260)
	local compactCB = CreateCheck(generalCell, "Compact rows", "TOPLEFT", generalCell, 12, -94, 260)

	-- VIEWER
	local viewerTitle = MakeLabel(viewerCell, "Viewer settings", "GameFontNormal")
	viewerTitle:SetPoint("TOPLEFT", viewerCell, "TOPLEFT", 12, -10)

	local selLabel = MakeLabel(viewerCell, "Selected viewer:", "GameFontNormalSmall")
	selLabel:SetPoint("TOPLEFT", viewerTitle, "BOTTOMLEFT", 0, -12)

	local selName = MakeLabel(viewerCell, "None", "GameFontHighlight")
	selName:SetPoint("LEFT", selLabel, "RIGHT", 8, 0)
	selName:SetPoint("RIGHT", viewerCell, "RIGHT", -12, 0)
	selName:SetJustifyH("LEFT")
	selName:SetWordWrap(false)
	selName:SetMaxLines(1)

	local swipeCB = CreateCheck(viewerCell, "Enable swipe", "TOPLEFT", viewerCell, 12, -64, 220)

	-- Duration
	local durHeader = MakeLabel(viewerCell, "Duration", "GameFontNormalSmall")
	durHeader:SetPoint("TOPLEFT", viewerCell, "TOPLEFT", 12, -96)

	local durRow = CreateFrame("Frame", nil, viewerCell)
	durRow:SetPoint("TOPLEFT", viewerCell, "TOPLEFT", 12, -114)
	durRow:SetPoint("TOPRIGHT", viewerCell, "TOPRIGHT", -12, -114)
	durRow:SetHeight(32)

	local durAnchorLabel = MakeLabel(durRow, "Anchor:", "GameFontNormalSmall")
	durAnchorLabel:SetPoint("LEFT", durRow, "LEFT", 0, 0)

	local durAnchorDD = CreateAnchorDropdown(durRow, 140)
	durAnchorDD:SetPoint("LEFT", durAnchorLabel, "RIGHT", -10, -2)

	local durXLabel = MakeLabel(durRow, "X:", "GameFontNormalSmall")
	durXLabel:SetPoint("LEFT", durAnchorDD, "RIGHT", -2, 0)
	local durXBox = MakeNumberBox(durRow, 56)
	durXBox:SetPoint("LEFT", durXLabel, "RIGHT", 6, 0)

	local durYLabel = MakeLabel(durRow, "Y:", "GameFontNormalSmall")
	durYLabel:SetPoint("LEFT", durXBox, "RIGHT", 10, 0)
	local durYBox = MakeNumberBox(durRow, 56)
	durYBox:SetPoint("LEFT", durYLabel, "RIGHT", 6, 0)

	local durResetBtn = CreateFrame("Button", nil, durRow, "UIPanelButtonTemplate")
	durResetBtn:SetSize(80, 22)
	durResetBtn:SetPoint("LEFT", durYBox, "RIGHT", 12, 0)
	durResetBtn:SetText("Reset")
	StyleGreyButton(durResetBtn)

	-- Stacks
	local stkHeader = MakeLabel(viewerCell, "Stacks", "GameFontNormalSmall")
	stkHeader:SetPoint("TOPLEFT", durRow, "BOTTOMLEFT", 0, -14)

	local stkRow = CreateFrame("Frame", nil, viewerCell)
	stkRow:SetPoint("TOPLEFT", stkHeader, "BOTTOMLEFT", 0, -6)
	stkRow:SetPoint("TOPRIGHT", viewerCell, "TOPRIGHT", -12, -166)
	stkRow:SetHeight(32)

	local stkAnchorLabel = MakeLabel(stkRow, "Anchor:", "GameFontNormalSmall")
	stkAnchorLabel:SetPoint("LEFT", stkRow, "LEFT", 0, 0)

	local stkAnchorDD = CreateAnchorDropdown(stkRow, 140)
	stkAnchorDD:SetPoint("LEFT", stkAnchorLabel, "RIGHT", -10, -2)

	local stkXLabel = MakeLabel(stkRow, "X:", "GameFontNormalSmall")
	stkXLabel:SetPoint("LEFT", stkAnchorDD, "RIGHT", -2, 0)
	local stkXBox = MakeNumberBox(stkRow, 56)
	stkXBox:SetPoint("LEFT", stkXLabel, "RIGHT", 6, 0)

	local stkYLabel = MakeLabel(stkRow, "Y:", "GameFontNormalSmall")
	stkYLabel:SetPoint("LEFT", stkXBox, "RIGHT", 10, 0)
	local stkYBox = MakeNumberBox(stkRow, 56)
	stkYBox:SetPoint("LEFT", stkYLabel, "RIGHT", 6, 0)

	local stkResetBtn = CreateFrame("Button", nil, stkRow, "UIPanelButtonTemplate")
	stkResetBtn:SetSize(80, 22)
	stkResetBtn:SetPoint("LEFT", stkYBox, "RIGHT", 12, 0)
	stkResetBtn:SetText("Reset")
	StyleGreyButton(stkResetBtn)

	local hint = viewerCell:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", stkRow, "BOTTOMLEFT", 0, -10)
	hint:SetPoint("TOPRIGHT", viewerCell, "TOPRIGHT", -12, 0)
	hint:SetJustifyH("LEFT")
	hint:SetText("Tip: Change Anchor/X/Y then press Enter or click away. Edge Top/Bottom puts the TEXT CENTER on the icon edge line. (Offsets apply out of combat if restricted.)")

	-- Bottom buttons
	local enableAllBtn = CreateFrame("Button", nil, buttonsCell, "UIPanelButtonTemplate")
	enableAllBtn:SetText("Enable all")
	StyleGreyButton(enableAllBtn)

	local disableAllBtn = CreateFrame("Button", nil, buttonsCell, "UIPanelButtonTemplate")
	disableAllBtn:SetText("Disable all")
	StyleGreyButton(disableAllBtn)

	local resetAllBtn = CreateFrame("Button", nil, buttonsCell, "UIPanelButtonTemplate")
	resetAllBtn:SetText("Reset all offsets")
	StyleGreyButton(resetAllBtn)

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

	-- Save UI refs
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
		refreshBtn = refreshBtn,
		selName = selName,
		swipeCB = swipeCB,

		durAnchorDD = durAnchorDD,
		durXBox = durXBox,
		durYBox = durYBox,
		durResetBtn = durResetBtn,

		stkAnchorDD = stkAnchorDD,
		stkXBox = stkXBox,
		stkYBox = stkYBox,
		stkResetBtn = stkResetBtn,

		enableAllBtn = enableAllBtn,
		disableAllBtn = disableAllBtn,
		resetAllBtn = resetAllBtn,

		_syncListWidth = SyncListWidth,
		_layoutBottom = LayoutBottomButtons,
	}

	-- Dropdown init
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

	-- Handlers
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
		BST:RefreshConfig()
	end)

	refreshBtn:SetScript("OnClick", function()
		BST:DiscoverViewersCheap()
		BST:RequestFullScan()
	end)

	enableAllBtn:SetScript("OnClick", function() BST:SetAllSwipe(true) end)
	disableAllBtn:SetScript("OnClick", function() BST:SetAllSwipe(false) end)
	resetAllBtn:SetScript("OnClick", function() BST:ResetAllOffsets() end)

	local function SelectedViewer()
		local db = BST:GetActiveDB(); EnsureTables(db)
		local vn = db.ui.selectedViewer
		if not vn or vn == "" then return nil end
		return vn
	end

	local function CommitDurationXY()
		local vn = SelectedViewer(); if not vn then return end
		local a, curX, curY = BST:GetDurationPos(vn)
		local newX = ClampInt(tonumber(durXBox:GetText()) or curX, -200, 200)
		local newY = ClampInt(tonumber(durYBox:GetText()) or curY, -200, 200)
		BST:SetDurationPos(vn, a, newX, newY)
	end
	local function CommitStackXY()
		local vn = SelectedViewer(); if not vn then return end
		local a, curX, curY = BST:GetStackPos(vn)
		local newX = ClampInt(tonumber(stkXBox:GetText()) or curX, -200, 200)
		local newY = ClampInt(tonumber(stkYBox:GetText()) or curY, -200, 200)
		BST:SetStackPos(vn, a, newX, newY)
	end

	durXBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); CommitDurationXY() end)
	durYBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); CommitDurationXY() end)
	durXBox:SetScript("OnEditFocusLost", CommitDurationXY)
	durYBox:SetScript("OnEditFocusLost", CommitDurationXY)

	stkXBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); CommitStackXY() end)
	stkYBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); CommitStackXY() end)
	stkXBox:SetScript("OnEditFocusLost", CommitStackXY)
	stkYBox:SetScript("OnEditFocusLost", CommitStackXY)

	swipeCB:SetScript("OnClick", function(btn)
		local vn = SelectedViewer()
		if not vn then btn:SetChecked(false); return end
		BST:SetSwipeEnabled(vn, btn:GetChecked())
	end)

	durResetBtn:SetScript("OnClick", function()
		local vn = SelectedViewer(); if not vn then return end
		BST:ResetDurationPos(vn)
	end)
	stkResetBtn:SetScript("OnClick", function()
		local vn = SelectedViewer(); if not vn then return end
		BST:ResetStackPos(vn)
	end)

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

	f:SetScript("OnShow", function()
		BST:DiscoverViewersCheap()
		SyncListWidth()
		LayoutBottomButtons()
		BST:RefreshConfig()
		BST:RequestFullScan()
	end)
end

function BST:SetSelectedViewer(vn)
	local db = self:GetActiveDB(); EnsureTables(db)
	db.ui.selectedViewer = vn or ""
	self:RefreshConfig()
end

function BST:RefreshConfig()
	if not self.configFrame or not self.ui then return end
	self:EnsureInit()

	local db = self:GetActiveDB()
	EnsureTables(db)

	self:DiscoverViewersCheap()

	self.ui.mmCheck:SetChecked(not not db.minimap.show)
	self.ui.useChar:SetChecked(self:UseCharSettings())
	self.ui.defaultNew:SetChecked(not not db.defaultNewViewerSwipe)
	self.ui.compact:SetChecked(not not db.ui.compact)

	local names = self:GetSortedViewerNames()
	self.ui.status:SetText(("Viewers: %d  •  Showing: %d"):format(#names, #names))

	if db.ui.selectedViewer == "" and #names > 0 then
		db.ui.selectedViewer = names[1]
	elseif db.ui.selectedViewer ~= "" then
		local ok = false
		for i = 1, #names do
			if names[i] == db.ui.selectedViewer then ok = true break end
		end
		if not ok then db.ui.selectedViewer = (#names > 0) and names[1] or "" end
	end

	if self.ui._syncListWidth then self.ui._syncListWidth() end
	if self.ui._layoutBottom then self.ui._layoutBottom() end

	-- Left list
	local ROW_H = db.ui.compact and 20 or 24
	local PAD = 2
	local content = self.ui.listContent

	for _, b in ipairs(self.ui.listButtons) do b:Hide() end

	local y = -PAD
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

			btn:SetScript("OnEnter", function(b)
				GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
				GameTooltip:AddLine(b._vn or "", 1, 1, 1, true)
				GameTooltip:Show()
			end)
			btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

			self.ui.listButtons[i] = btn
		end

		btn._vn = vn
		btn:ClearAllPoints()
		btn:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
		btn:SetSize(width, ROW_H)

		if vn == db.ui.selectedViewer then btn.sel:Show() else btn.sel:Hide() end

		if self:IsSwipeEnabled(vn) then
			btn.dot:SetColorTexture(0.10, 0.90, 0.20, 0.95)
		else
			btn.dot:SetColorTexture(0.90, 0.20, 0.20, 0.95)
		end

		btn.text:SetText(vn)
		btn:SetScript("OnClick", function() BST:SetSelectedViewer(vn) end)

		btn:Show()
		y = y - ROW_H
	end

	content:SetHeight(math.max(1, (#names * ROW_H) + (PAD * 2)))

	-- Right details
	local selected = db.ui.selectedViewer
	if selected == "" then
		self.ui.selName:SetText("None")
		self.ui.swipeCB:SetChecked(false)

		UIDropDownMenu_SetText(self.ui.durAnchorDD, ANCHOR_TEXT["CENTER"])
		UIDropDownMenu_SetText(self.ui.stkAnchorDD, ANCHOR_TEXT["BOTTOMRIGHT"])

		SetIfNotFocused(self.ui.durXBox, "")
		SetIfNotFocused(self.ui.durYBox, "")
		SetIfNotFocused(self.ui.stkXBox, "")
		SetIfNotFocused(self.ui.stkYBox, "")

		self.ui.swipeCB:Disable()
		self.ui.durXBox:Disable(); self.ui.durYBox:Disable(); self.ui.durResetBtn:Disable()
		self.ui.stkXBox:Disable(); self.ui.stkYBox:Disable(); self.ui.stkResetBtn:Disable()
	else
		self.ui.selName:SetText(selected)
		self.ui.swipeCB:Enable()
		self.ui.durXBox:Enable(); self.ui.durYBox:Enable(); self.ui.durResetBtn:Enable()
		self.ui.stkXBox:Enable(); self.ui.stkYBox:Enable(); self.ui.stkResetBtn:Enable()

		self.ui.swipeCB:SetChecked(self:IsSwipeEnabled(selected))

		local da, dx, dy = self:GetDurationPos(selected)
		UIDropDownMenu_SetText(self.ui.durAnchorDD, ANCHOR_TEXT[da] or da)
		SetIfNotFocused(self.ui.durXBox, tostring(dx))
		SetIfNotFocused(self.ui.durYBox, tostring(dy))

		local sa, sx, sy = self:GetStackPos(selected)
		UIDropDownMenu_SetText(self.ui.stkAnchorDD, ANCHOR_TEXT[sa] or sa)
		SetIfNotFocused(self.ui.stkXBox, tostring(sx))
		SetIfNotFocused(self.ui.stkYBox, tostring(sy))
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
		if self.configFrame:IsShown() then
			self.configFrame:Hide()
		else
			self:OpenConfig()
		end
	end)
end

-- -------------------------------------------------------
-- Settings category (Settings / Edit Mode)
-- -------------------------------------------------------

function BST:RegisterSettingsCategory()
	if _G.Settings and type(_G.Settings.RegisterCanvasLayoutCategory) == "function" then
		local panel = CreateFrame("Frame")
		panel:Hide()
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
	local db = self:GetActiveDB()
	EnsureTables(db)
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

function BuffSwipeToggle_OnAddonCompartmentClick(addonName, buttonName)
	BST:ToggleConfig()
end

-- -------------------------------------------------------
-- Slash command
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
			BST:DiscoverViewersCheap()
			BST:RequestFullScan()
			BST:Print("Loaded. Use /bst to open.")
		end)
		return
	end

	if event == "COOLDOWN_VIEWER_DATA_LOADED" then
		SafeCall(function() BST:RequestFullScan() end)
		return
	end

	if event == "PLAYER_REGEN_ENABLED" then
		SafeCall(function() BST:RequestFullScan() end)
		return
	end
end)
