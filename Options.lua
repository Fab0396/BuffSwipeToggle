-- Options.lua
-- UI and settings for BuffSwipeToggle (loaded after core).

local BST = _G.BuffSwipeToggle
if not BST then return end

-- Pull shared constants from core
local ANCHORS = BST.ANCHORS or {}
local ANCHOR_TEXT = BST.ANCHOR_TEXT or {}
local SafeAnchor = BST.SafeAnchor or function(a) return a or "CENTER" end

-- EnsureTables proxy to core; safe if core updates later
local function EnsureTables(db)
	if BST and BST.EnsureTables then
		BST.EnsureTables(db)
	end
end


local function SafeCall(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		DEFAULT_CHAT_FRAME:AddMessage(("|cffff5555[BuffSwipeToggle]|r %s"):format(tostring(err)))
	end
	return ok
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