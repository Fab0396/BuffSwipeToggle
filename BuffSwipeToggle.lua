-- BuffSwipeToggle.lua
-- Fixes:
--  - Removes invalid SetPoint anchoring button to itself (was breaking UI + hiding viewer list)
--  - Bottom row buttons remain centered group layout
--  - Close "X" uses UIPanelButtonTemplate so it renders
--  - Clean top border (main border only) + titlebar fill + bottom separator
--  - Grey theme + 2px black borders + grey buttons w/ white text

local ADDON_NAME = ...
local BST = {}
_G.BuffSwipeToggle = BST

BuffSwipeToggleDB = BuffSwipeToggleDB or nil
BuffSwipeToggleCharDB = BuffSwipeToggleCharDB or nil

local DEFAULTS = {
	minimap = { show = true, angle = 220 },
	useCharacterSettings = false,
	defaultNewViewerSwipe = true,

	knownViewers = {},
	swipe = {},
	textPos = {},
	lastSeen = {},

	ui = {
		compact = false,
		selectedViewer = "",
	},
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

		for vn in pairs(a.knownViewers) do
			c.knownViewers[vn] = true
			if c.swipe[vn] == nil and a.swipe[vn] ~= nil then c.swipe[vn] = a.swipe[vn] end
			if c.textPos[vn] == nil and a.textPos[vn] ~= nil then
				c.textPos[vn] = { x = a.textPos[vn].x or 0, y = a.textPos[vn].y or 0 }
			end
			if c.lastSeen[vn] == nil and a.lastSeen[vn] ~= nil then
				c.lastSeen[vn] = a.lastSeen[vn]
			end
		end
	end

	self:RefreshAll()
	self:RefreshConfig()
end

-- ---------- Viewer discovery ----------

local function IsFrame(v)
	return type(v) == "table" and type(v.GetObjectType) == "function" and v:GetObjectType() == "Frame"
end

function BST:EnsureViewerDefaults(vn)
	if not vn then return end
	self:EnsureInit()
	local db = self:GetActiveDB()
	if not db then return end
	EnsureTables(db)

	db.knownViewers[vn] = true
	if db.swipe[vn] == nil then db.swipe[vn] = not not db.defaultNewViewerSwipe end

	if db.textPos[vn] == nil then
		db.textPos[vn] = { x = 0, y = 0 }
	else
		db.textPos[vn].x = tonumber(db.textPos[vn].x) or 0
		db.textPos[vn].y = tonumber(db.textPos[vn].y) or 0
	end

	if db.lastSeen[vn] == nil then db.lastSeen[vn] = 0 end
end

function BST:MarkSeen(vn)
	if not vn then return end
	self:EnsureInit()
	local db = self:GetActiveDB()
	if not db then return end
	EnsureTables(db)
	db.lastSeen[vn] = time()
end

function BST:DiscoverViewers()
	self:EnsureInit()
	local db = self:GetActiveDB()
	if not db then return end
	EnsureTables(db)

	local found = {}

	for _, name in ipairs({ "BuffIconCooldownViewer", "EssentialCooldownViewer", "UtilityCooldownViewer" }) do
		if _G[name] and IsFrame(_G[name]) then found[name] = true end
	end

	for k, v in pairs(_G) do
		if type(k) == "string" and k:match("CooldownViewer$") and IsFrame(v) then
			found[k] = true
		end
	end

	local f = EnumerateFrames()
	while f do
		if f.viewerFrame and IsFrame(f.viewerFrame) and type(f.viewerFrame.GetName) == "function" then
			local vn = f.viewerFrame:GetName()
			if vn then found[vn] = true end
		end
		f = EnumerateFrames(f)
	end

	for vn in pairs(found) do
		self:EnsureViewerDefaults(vn)
		self:MarkSeen(vn)
	end
end

function BST:GetViewerNamesRaw()
	self:EnsureInit()
	local db = self:GetActiveDB()
	if not db then return {} end
	EnsureTables(db)
	local t = {}
	for vn in pairs(db.knownViewers) do t[#t + 1] = vn end
	return t
end

-- ---------- Per viewer settings ----------

function BST:IsSwipeEnabled(vn)
	self:EnsureInit()
	local db = self:GetActiveDB()
	if not db then return false end
	EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	return not not db.swipe[vn]
end

function BST:SetSwipeEnabled(vn, flag)
	self:EnsureInit()
	local db = self:GetActiveDB()
	if not db then return end
	EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	db.swipe[vn] = not not flag
	self:RefreshAll()
	self:RefreshConfig()
end

function BST:GetTextPos(vn)
	self:EnsureInit()
	local db = self:GetActiveDB()
	if not db then return 0, 0 end
	EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	local p = db.textPos[vn]
	return tonumber(p.x) or 0, tonumber(p.y) or 0
end

function BST:SetTextPos(vn, x, y)
	self:EnsureInit()
	local db = self:GetActiveDB()
	if not db then return end
	EnsureTables(db)
	self:EnsureViewerDefaults(vn)
	db.textPos[vn].x = tonumber(x) or 0
	db.textPos[vn].y = tonumber(y) or 0
	self:RefreshAll()
	self:RefreshConfig()
end

function BST:ResetTextPos(vn) self:SetTextPos(vn, 0, 0) end

function BST:SetAllSwipe(flag)
	self:DiscoverViewers()
	local db = self:GetActiveDB()
	EnsureTables(db)
	for _, vn in ipairs(self:GetViewerNamesRaw()) do
		self:EnsureViewerDefaults(vn)
		db.swipe[vn] = not not flag
	end
	self:RefreshAll()
	self:RefreshConfig()
end

function BST:ResetAllTextOffsets()
	self:DiscoverViewers()
	local db = self:GetActiveDB()
	EnsureTables(db)
	for _, vn in ipairs(self:GetViewerNamesRaw()) do
		self:EnsureViewerDefaults(vn)
		db.textPos[vn].x = 0
		db.textPos[vn].y = 0
	end
	self:RefreshAll()
	self:RefreshConfig()
end

-- ---------- Apply swipe + text pos ----------

local function FindViewerNameFromRegion(region)
	local p = region
	for _ = 1, 10 do
		if not p then break end
		if p.viewerFrame and IsFrame(p.viewerFrame) and type(p.viewerFrame.GetName) == "function" then
			local vn = p.viewerFrame:GetName()
			if vn then return vn end
		end
		p = (type(p.GetParent) == "function") and p:GetParent() or nil
	end
	return nil
end

local function IsFontString(o)
	return type(o) == "table" and type(o.GetObjectType) == "function" and o:GetObjectType() == "FontString"
end

function BST:FindCooldownCountdownText(cooldown)
	if not cooldown then return nil end
	if IsFontString(cooldown.text) then return cooldown.text end
	if IsFontString(cooldown.Text) then return cooldown.Text end
	if IsFontString(cooldown.CountdownText) then return cooldown.CountdownText end
	if IsFontString(cooldown.CooldownText) then return cooldown.CooldownText end

	if type(cooldown.GetRegions) == "function" then
		local regions = { cooldown:GetRegions() }
		for i = 1, #regions do
			if IsFontString(regions[i]) then return regions[i] end
		end
	end
	return nil
end

function BST:ApplyToCooldown(cooldown, viewerName)
	if not cooldown or type(cooldown.SetDrawSwipe) ~= "function" then return end
	if not viewerName then viewerName = FindViewerNameFromRegion(cooldown) end
	if not viewerName then return end

	self:EnsureViewerDefaults(viewerName)
	self:MarkSeen(viewerName)

	cooldown:SetDrawSwipe(self:IsSwipeEnabled(viewerName))

	local fs = self:FindCooldownCountdownText(cooldown)
	if fs then
		local x, y = self:GetTextPos(viewerName)
		fs:ClearAllPoints()
		fs:SetPoint("CENTER", cooldown, "CENTER", x, y)
	end
end

function BST:ApplyToExistingFrames()
	self:DiscoverViewers()
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

function BST:Apply() self:ApplyToExistingFrames() end

function BST:ScheduleApplyRetries()
	local tries = 0
	local function tick()
		tries = tries + 1
		BST:Apply()
		if tries < 10 then C_Timer.After(0.6, tick) end
	end
	tick()
end

function BST:TryHookCooldownFrameSet()
	if self._hookedCooldownFrameSet then return end
	if type(_G.CooldownFrame_Set) ~= "function" then return end
	hooksecurefunc("CooldownFrame_Set", function(cooldown) BST:ApplyToCooldown(cooldown, nil) end)
	self._hookedCooldownFrameSet = true
end

-- ---------- UI helpers ----------

local function ClampInt(n, lo, hi)
	n = tonumber(n)
	if not n then return 0 end
	n = math.floor(n + 0.5)
	if n < lo then n = lo end
	if n > hi then n = hi end
	return n
end

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

	btn:HookScript("OnEnable", function(b)
		local fss = b.GetFontString and b:GetFontString()
		if fss then fss:SetTextColor(1, 1, 1) end
	end)
	btn:HookScript("OnDisable", function(b)
		local fss = b.GetFontString and b:GetFontString()
		if fss then fss:SetTextColor(0.65, 0.65, 0.65) end
	end)
end

-- ---------- Config window ----------

function BST:BuildConfigWindow()
	if self.configFrame then return end
	self:EnsureInit()

	local f = CreateFrame("Frame", "BuffSwipeToggleFrame", UIParent)
	f:SetSize(840, 570)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:Hide()
	f:EnableMouse(true)
	f:SetMovable(true)

	SkinCell(f, { 0.20, 0.20, 0.20, 1.0 }, true)

	-- Titlebar (fill only + bottom separator)
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

	-- Close button
	local closeBtn = CreateFrame("Button", nil, titleBar, "UIPanelButtonTemplate")
	closeBtn:SetSize(24, 20)
	closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
	closeBtn:SetText("X")
	StyleGreyButton(closeBtn)
	closeBtn:SetScript("OnClick", function() f:Hide() end)

	-- Minimap label + checkbox
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
	leftPane:SetWidth(300)
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
	leftListCell:SetPoint("TOPRIGHT", leftPane, "TOPRIGHT", -12, -52)
	leftListCell:SetPoint("BOTTOMLEFT", leftPane, "BOTTOMLEFT", 12, 40)
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

	local row = CreateFrame("Frame", nil, viewerCell)
	row:SetPoint("TOPLEFT", viewerCell, "TOPLEFT", 12, -92)
	row:SetPoint("TOPRIGHT", viewerCell, "TOPRIGHT", -12, -92)
	row:SetHeight(26)

	local xLabel = MakeLabel(row, "Text X:", "GameFontNormalSmall")
	xLabel:SetPoint("LEFT", row, "LEFT", 0, 0)
	local xBox = MakeNumberBox(row, 70)
	xBox:SetPoint("LEFT", xLabel, "RIGHT", 8, 0)

	local yLabel = MakeLabel(row, "Text Y:", "GameFontNormalSmall")
	yLabel:SetPoint("LEFT", xBox, "RIGHT", 18, 0)
	local yBox = MakeNumberBox(row, 70)
	yBox:SetPoint("LEFT", yLabel, "RIGHT", 8, 0)

	local resetViewerBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	resetViewerBtn:SetSize(90, 22)
	resetViewerBtn:SetPoint("LEFT", yBox, "RIGHT", 18, 0)
	resetViewerBtn:SetText("Reset")
	StyleGreyButton(resetViewerBtn)

	local hint = viewerCell:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -10)
	hint:SetPoint("TOPRIGHT", viewerCell, "TOPRIGHT", -12, 0)
	hint:SetJustifyH("LEFT")
	hint:SetText("Tip: Change X/Y then press Enter or click away. Viewer list shows swipe state on the left.")

	-- BOTTOM BUTTONS (centered group layout) - FIXED (no self-anchoring)
	local enableAllBtn = CreateFrame("Button", nil, buttonsCell, "UIPanelButtonTemplate")
	enableAllBtn:SetText("Enable all")
	StyleGreyButton(enableAllBtn)

	local disableAllBtn = CreateFrame("Button", nil, buttonsCell, "UIPanelButtonTemplate")
	disableAllBtn:SetText("Disable all")
	StyleGreyButton(disableAllBtn)

	local resetAllBtn = CreateFrame("Button", nil, buttonsCell, "UIPanelButtonTemplate")
	resetAllBtn:SetText("Reset all X/Y")
	StyleGreyButton(resetAllBtn)

	local function LayoutBottomButtons()
		local w = buttonsCell:GetWidth() or 0
		if w <= 0 then return end

		local gap = 12
		local bh = 20
		local yOff = 0
		local minSideInset = 12

		local bw = math.floor((w - (minSideInset * 2) - (gap * 2)) / 3)
		if bw > 125 then bw = 125 end
		if bw < 75 then bw = 75 end

		local groupW = (bw * 3) + (gap * 2)
		local startX = math.floor((w - groupW) / 2)
		if startX < minSideInset then startX = minSideInset end

		enableAllBtn:SetSize(bw, bh)
		disableAllBtn:SetSize(bw, bh)
		resetAllBtn:SetSize(bw, bh)

		enableAllBtn:ClearAllPoints()
		disableAllBtn:ClearAllPoints()
		resetAllBtn:ClearAllPoints()

		enableAllBtn:SetPoint("LEFT", buttonsCell, "LEFT", startX, yOff)
		disableAllBtn:SetPoint("LEFT", enableAllBtn, "RIGHT", gap, 0)
		resetAllBtn:SetPoint("LEFT", disableAllBtn, "RIGHT", gap, 0)
	end

	buttonsCell:SetScript("OnSizeChanged", LayoutBottomButtons)
	C_Timer.After(0, LayoutBottomButtons)

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
		xBox = xBox,
		yBox = yBox,
		resetViewerBtn = resetViewerBtn,

		enableAllBtn = enableAllBtn,
		disableAllBtn = disableAllBtn,
		resetAllBtn = resetAllBtn,

		_syncListWidth = SyncListWidth,
		_layoutBottom = LayoutBottomButtons,
	}

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
		BST:DiscoverViewers()
		BST:RefreshConfig()
	end)

	enableAllBtn:SetScript("OnClick", function() BST:SetAllSwipe(true) end)
	disableAllBtn:SetScript("OnClick", function() BST:SetAllSwipe(false) end)
	resetAllBtn:SetScript("OnClick", function() BST:ResetAllTextOffsets() end)

	local function CommitXY()
		local db = BST:GetActiveDB(); EnsureTables(db)
		local vn = db.ui.selectedViewer
		if not vn or vn == "" then return end
		local curX, curY = BST:GetTextPos(vn)
		local newX = ClampInt(tonumber(xBox:GetText()) or curX, -200, 200)
		local newY = ClampInt(tonumber(yBox:GetText()) or curY, -200, 200)
		BST:SetTextPos(vn, newX, newY)
	end

	xBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); CommitXY() end)
	yBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); CommitXY() end)
	xBox:SetScript("OnEditFocusLost", CommitXY)
	yBox:SetScript("OnEditFocusLost", CommitXY)

	swipeCB:SetScript("OnClick", function(btn)
		local db = BST:GetActiveDB(); EnsureTables(db)
		local vn = db.ui.selectedViewer
		if not vn or vn == "" then
			btn:SetChecked(false)
			return
		end
		BST:SetSwipeEnabled(vn, btn:GetChecked())
	end)

	resetViewerBtn:SetScript("OnClick", function()
		local db = BST:GetActiveDB(); EnsureTables(db)
		local vn = db.ui.selectedViewer
		if not vn or vn == "" then return end
		BST:ResetTextPos(vn)
	end)

	f:SetScript("OnShow", function()
		BST:DiscoverViewers()
		SyncListWidth()
		LayoutBottomButtons()
		BST:RefreshConfig()
	end)
end

function BST:GetSortedViewerNames()
	self:DiscoverViewers()
	local names = self:GetViewerNamesRaw()
	table.sort(names)
	return names
end

function BST:SetSelectedViewer(vn)
	local db = self:GetActiveDB(); EnsureTables(db)
	db.ui.selectedViewer = vn or ""
	self:RefreshConfig()
end

function BST:RefreshConfig()
	if not self.configFrame or not self.ui then return end
	self:EnsureInit()

	local db = self:GetActiveDB(); EnsureTables(db)
	self:DiscoverViewers()

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
		if not ok then
			db.ui.selectedViewer = (#names > 0) and names[1] or ""
		end
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
	if not width or width < 40 then width = 240 end

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
		SetIfNotFocused(self.ui.xBox, "")
		SetIfNotFocused(self.ui.yBox, "")
		self.ui.swipeCB:Disable()
		self.ui.xBox:Disable()
		self.ui.yBox:Disable()
		self.ui.resetViewerBtn:Disable()
	else
		self.ui.selName:SetText(selected)
		self.ui.swipeCB:Enable()
		self.ui.xBox:Enable()
		self.ui.yBox:Enable()
		self.ui.resetViewerBtn:Enable()

		self.ui.swipeCB:SetChecked(self:IsSwipeEnabled(selected))
		local x, yy = self:GetTextPos(selected)
		SetIfNotFocused(self.ui.xBox, tostring(x))
		SetIfNotFocused(self.ui.yBox, tostring(yy))
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

-- ---------- Settings entry ----------
function BST:RegisterSettingsCategory()
	if _G.Settings and type(_G.Settings.RegisterCanvasLayoutCategory) == "function" then
		local panel = CreateFrame("Frame")
		panel:Hide()
		local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		btn:SetSize(220, 24)
		btn:SetPoint("TOPLEFT", 16, -16)
		btn:SetText("Open Buff Swipe Toggle")
		StyleGreyButton(btn)
		btn:SetScript("OnClick", function() BST:OpenConfig() end)
		local cat = _G.Settings.RegisterCanvasLayoutCategory(panel, "Buff Swipe Toggle")
		_G.Settings.RegisterAddOnCategory(cat)
	end
end

-- ---------- Minimap button ----------
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
		GameTooltip:AddLine("Click: Open", 0.9, 0.9, 0.9)
		GameTooltip:AddLine("Drag: Move", 0.9, 0.9, 0.9)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	b:SetScript("OnClick", function() BST:OpenConfig() end)

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

-- ---------- Addon Compartment ----------
function BuffSwipeToggle_OnAddonCompartmentClick(addonName, buttonName) BST:OpenConfig() end

-- ---------- Refresh ----------
function BST:RefreshAll()
	self:Apply()
	self:UpdateMinimapButton()
end

-- ---------- Slash command ----------
SLASH_BUFFSWIPETOGGLE1 = "/bst"
SlashCmdList["BUFFSWIPETOGGLE"] = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	SafeCall(function()
		BST:EnsureInit()
		BST:ToggleConfig()
	end)
end

-- ---------- Events ----------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("COOLDOWN_VIEWER_DATA_LOADED")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
		SafeCall(function() BST:InitDB() end)
		return
	end

	if event == "PLAYER_LOGIN" then
		SafeCall(function()
			BST:RegisterSettingsCategory()
			BST:CreateMinimapButton()
			BST:TryHookCooldownFrameSet()
			BST:ScheduleApplyRetries()
			BST:DiscoverViewers()
			BST:Print("Loaded. Use /bst to open.")
		end)
		return
	end

	if event == "COOLDOWN_VIEWER_DATA_LOADED" then
		SafeCall(function() BST:Apply() end)
	end
end)
