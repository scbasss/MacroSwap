-- Generic target-based macro swapper, supports multiple independent
-- target -> (original macro / swap-in macro) profiles.
-- For each profile: while targeting its configured unit, the original macro
-- (already on your bar) has its text swapped for the swap-in macro's text,
-- then restored when you stop targeting it. Uses EditMacro only (not
-- PlaceAction/PickupMacro), which is why this keeps working in combat -
-- except EditMacro itself is blocked by the game while you're in combat;
-- when that happens the pending change is retried automatically as soon as
-- combat ends.

-- IMPORTANT: do not do `local db = MacroSwapDB` here. At the point this file
-- executes, the client hasn't restored the saved table into the global yet -
-- that happens right before ADDON_LOADED fires for this addon. Grabbing it
-- now would alias `db` to a throwaway empty table forever, silently
-- discarding every read/write. `db` is wired up for real in the ADDON_LOADED
-- handler below.
local db

-- Per-profile "last body we successfully saw applied" tracking. Keyed by the
-- profile table itself (not index), so adding/removing/reordering profiles
-- can't scramble it. Intentionally not persisted - it's just runtime dedup.
local lastAppliedMap = {}

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("ADDON_LOADED")
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:RegisterEvent("PLAYER_TARGET_CHANGED")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:RegisterEvent("PLAYER_REGEN_ENABLED") -- combat ends; catch up on any swap that got blocked mid-fight

-- GetMacroIndexByName is case-sensitive; scan manually (global + per-character
-- macro slots) so macro names, like target names, can be typed in any case.
local function FindMacroIndex(name)
    if not name then return 0 end
    local lname = name:lower()
    local numGlobal, numPerChar = GetNumMacros()
    for i = 1, numGlobal do
        local n = GetMacroInfo(i)
        if n and n:lower() == lname then return i end
    end
    for i = MAX_ACCOUNT_MACROS + 1, MAX_ACCOUNT_MACROS + numPerChar do
        local n = GetMacroInfo(i)
        if n and n:lower() == lname then return i end
    end
    return 0
end

local function dprint(...)
    if not db or not db.debug then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
    end
    print("|cff33ff99MacroSwap debug:|r " .. table.concat(parts, " "))
end

local function UpdateProfile(profile, label)
    if not profile.target or not profile.originalMacro or not profile.swapMacro then
        return
    end

    local origIdx = FindMacroIndex(profile.originalMacro)
    if origIdx == 0 then
        dprint(label .. ": original macro '" .. profile.originalMacro .. "' not found (index 0)")
        return
    end

    if not profile.originalBody then
        local name, icon, body = GetMacroInfo(origIdx)
        profile.originalName, profile.originalIcon, profile.originalBody = name, icon, body
        dprint(label .. ": captured original '" .. name .. "', body length " .. #body)
    end

    local curTarget = UnitExists("target") and UnitName("target") or nil
    local onTarget = curTarget ~= nil and curTarget:lower() == profile.target:lower()

    local swapIdx = FindMacroIndex(profile.swapMacro)
    local swapBody = swapIdx ~= 0 and select(3, GetMacroInfo(swapIdx)) or nil

    if not onTarget then
        -- Off-target, so whatever the macro's real content is right now IS
        -- the resting state - either we already restored it correctly, or
        -- the user hand-edited the macro since. Adopt it live so there's
        -- never a stale cache to manually fix.
        local curName, curIcon, curBody = GetMacroInfo(origIdx)
        if curBody ~= swapBody and curBody ~= profile.originalBody then
            dprint(label .. ": original macro content changed since last seen, auto-recapturing")
            profile.originalName, profile.originalIcon, profile.originalBody = curName, curIcon, curBody
        end
    end

    local wantIcon, wantBody
    if onTarget then
        if swapIdx == 0 then
            dprint(label .. ": swap macro '" .. profile.swapMacro .. "' not found (index 0), using original")
            wantIcon, wantBody = profile.originalIcon, profile.originalBody
        else
            wantIcon, wantBody = select(2, GetMacroInfo(swapIdx)), swapBody
        end
    else
        wantIcon, wantBody = profile.originalIcon, profile.originalBody
    end

    if wantBody ~= lastAppliedMap[profile] then
        dprint(label .. ": current target='" .. tostring(curTarget) .. "' onTarget=" .. tostring(onTarget) .. ", calling EditMacro")
        EditMacro(origIdx, profile.originalName, wantIcon, wantBody)

        -- Don't assume EditMacro succeeded (it's blocked in combat) - read
        -- the macro back and track what's ACTUALLY there, so a blocked edit
        -- gets retried next time instead of being considered "done" forever.
        local _, _, actualBody = GetMacroInfo(origIdx)
        lastAppliedMap[profile] = actualBody
        if actualBody ~= wantBody then
            dprint(label .. ": EditMacro did not take (probably combat-blocked) - will retry on next event")
        end
    end
end

local function UpdateAllMacros()
    if not db or not db.profiles then return end
    for i, profile in ipairs(db.profiles) do
        UpdateProfile(profile, "Macro " .. i)
    end
end

-- General pattern for any future storage change (renaming the saved
-- variable, switching between account-wide/per-character, changing shape,
-- etc.): keep BOTH the old and new `.toc` declarations around using
-- DIFFERENT global names (never reuse the same name for both - the second
-- one to load silently overwrites the first before this code ever runs, so
-- there'd be nothing left to migrate from). Then do a one-time copy here,
-- guarded by a flag on the new table so it only ever runs once per
-- destination. The old declaration can stay in the .toc indefinitely - it's
-- just an unused leftover file after migration, harmless to leave.
local function MigrateAccountWideToPerCharacter()
    MacroSwapDBChar = MacroSwapDBChar or {}
    if not MacroSwapDBChar.migratedFromAccountWide and MacroSwapDB then
        for k, v in pairs(MacroSwapDB) do
            if MacroSwapDBChar[k] == nil then
                MacroSwapDBChar[k] = v
            end
        end
        MacroSwapDBChar.migratedFromAccountWide = true
    end
    return MacroSwapDBChar
end

local function MigrateOldSingleProfile()
    if db.profiles then return end
    db.profiles = {}
    if db.target or db.originalMacro or db.swapMacro then
        table.insert(db.profiles, {
            target = db.target,
            originalMacro = db.originalMacro,
            swapMacro = db.swapMacro,
            originalName = db.originalName,
            originalIcon = db.originalIcon,
            originalBody = db.originalBody,
        })
        db.target, db.originalMacro, db.swapMacro = nil, nil, nil
        db.originalName, db.originalIcon, db.originalBody = nil, nil, nil
    end
end

watcher:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" then
        if addonName ~= "MacroSwap" then return end
        db = MigrateAccountWideToPerCharacter()
        MigrateOldSingleProfile()
        if #db.profiles == 0 then
            table.insert(db.profiles, {})
        end
        if not db.selectedProfile or db.selectedProfile > #db.profiles then
            db.selectedProfile = 1
        end
        self:UnregisterEvent("ADDON_LOADED")
        return
    end
    UpdateAllMacros()
end)

-- ===================== Standalone options window =====================

local win = CreateFrame("Frame", "MacroSwapWindow", UIParent, "BackdropTemplate")
win:SetSize(380, 260)
win:SetPoint("CENTER")
win:SetMovable(true)
win:EnableMouse(true)
win:RegisterForDrag("LeftButton")
win:SetScript("OnDragStart", win.StartMoving)
win:SetScript("OnDragStop", win.StopMovingOrSizing)
win:SetFrameStrata("DIALOG")
win:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
win:Hide()

local title = win:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -16)
title:SetText("MacroSwap")

local closeBtn = CreateFrame("Button", nil, win, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -4, -4)
closeBtn:SetScript("OnClick", function() win:Hide() end)

tinsert(UISpecialFrames, "MacroSwapWindow") -- lets Escape close it like any Blizzard panel

local subtitle = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", 16, -40)
subtitle:SetWidth(348)
subtitle:SetJustifyH("LEFT")
subtitle:SetText("Each tab is its own target -> macro swap. While targeting the unit, " ..
    "the original macro's text is swapped for the swap-in macro's text.")

-- Tab row (rebuilt whenever profiles are added/removed)
local tabRow = CreateFrame("Frame", nil, win)
tabRow:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -18)
tabRow:SetPoint("TOPRIGHT", subtitle, "BOTTOMRIGHT", 0, -18)
tabRow:SetHeight(50)

local TAB_WIDTH, TAB_HEIGHT, TAB_GAP = 62, 22, 6
local ROW_PAD = 26 -- extra breathing room below the last tab/remove row
local tabPool = {}
local plusBtn = CreateFrame("Button", nil, tabRow, "UIPanelButtonTemplate")
plusBtn:SetSize(28, TAB_HEIGHT)
plusBtn:SetText("+")

local removeBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
removeBtn:SetSize(120, TAB_HEIGHT)
removeBtn:SetText("Remove This Tab")

local function MakeLabeledEditBox(anchorTo, label)
    local fs = win:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -16)
    fs:SetText(label)

    local edit = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
    edit:SetSize(300, 20)
    edit:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 6, -4)
    edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", edit.ClearFocus)

    return edit, fs
end

local originalEdit = MakeLabeledEditBox(tabRow, "Original macro (already on your bar)")
local swapEdit = MakeLabeledEditBox(originalEdit, "Swap-in macro (doesn't need to be on a bar)")
local targetEdit = MakeLabeledEditBox(swapEdit, "Target name")

local status = win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
status:SetPoint("TOPLEFT", targetEdit, "BOTTOMLEFT", -6, -14)
status:SetWidth(348)
status:SetJustifyH("LEFT")

local function CurrentProfile()
    return db.profiles[db.selectedProfile]
end

local function RefreshStatus()
    local profile = CurrentProfile()
    local lines = {}
    if profile.originalMacro and FindMacroIndex(profile.originalMacro) == 0 then
        table.insert(lines, "|cffff0000Original macro '" .. profile.originalMacro .. "' not found - create it first.|r")
    end
    if profile.swapMacro and FindMacroIndex(profile.swapMacro) == 0 then
        table.insert(lines, "|cffff0000Swap-in macro '" .. profile.swapMacro .. "' not found - create it first.|r")
    end
    if #lines == 0 and profile.originalMacro and profile.swapMacro and profile.target then
        table.insert(lines, "|cff33ff99Ready.|r")
    end
    status:SetText(table.concat(lines, "\n"))
end

local RebuildTabs -- forward declare

local function SelectProfile(idx)
    db.selectedProfile = idx
    local profile = CurrentProfile()
    originalEdit:SetText(profile.originalMacro or "")
    swapEdit:SetText(profile.swapMacro or "")
    targetEdit:SetText(profile.target or "")
    RefreshStatus()
    RebuildTabs()
end

function RebuildTabs()
    local x, y = 0, 0
    local rowWidth = tabRow:GetWidth()

    for i, profile in ipairs(db.profiles) do
        local btn = tabPool[i]
        if not btn then
            btn = CreateFrame("Button", nil, tabRow, "UIPanelButtonTemplate")
            btn:SetSize(TAB_WIDTH, TAB_HEIGHT)
            tabPool[i] = btn
        end
        btn:SetText("Macro " .. i)
        btn:SetEnabled(i ~= db.selectedProfile)
        btn:ClearAllPoints()
        if x + TAB_WIDTH > rowWidth then
            x = 0
            y = y - (TAB_HEIGHT + TAB_GAP)
        end
        btn:SetPoint("TOPLEFT", tabRow, "TOPLEFT", x, y)
        btn:Show()
        btn:SetScript("OnClick", function() SelectProfile(i) end)
        x = x + TAB_WIDTH + TAB_GAP
    end

    for i = #db.profiles + 1, #tabPool do
        tabPool[i]:Hide()
    end

    if x + plusBtn:GetWidth() > rowWidth then
        x = 0
        y = y - (TAB_HEIGHT + TAB_GAP)
    end
    plusBtn:ClearAllPoints()
    plusBtn:SetPoint("TOPLEFT", tabRow, "TOPLEFT", x, y)

    removeBtn:ClearAllPoints()
    removeBtn:SetPoint("TOPLEFT", tabRow, "TOPLEFT", 0, y - (TAB_HEIGHT + TAB_GAP))
    removeBtn:SetEnabled(#db.profiles > 1)

    -- Everything anchored below tabRow (the edit boxes) needs to move down
    -- as it grows taller from wrapped tab rows.
    local extraRows = -y / (TAB_HEIGHT + TAB_GAP)
    tabRow:SetHeight((TAB_HEIGHT + TAB_GAP) * (extraRows + 2))

    -- Resize the window to actually fit everything, rather than guessing a
    -- fixed pixel height that breaks whenever tabs wrap to extra rows. This
    -- works even though win is CENTER-anchored: everything above is anchored
    -- top-down off win's top edge, so the measured content span is stable
    -- regardless of win's current (possibly wrong) height.
    if win:IsShown() then
        local top, bottom = win:GetTop(), status:GetBottom()
        if top and bottom then
            win:SetHeight((top - bottom) + 20)
        end
    end
end

plusBtn:SetScript("OnClick", function()
    table.insert(db.profiles, {})
    SelectProfile(#db.profiles)
end)

removeBtn:SetScript("OnClick", function()
    if #db.profiles <= 1 then return end
    local profile = CurrentProfile()
    lastAppliedMap[profile] = nil
    table.remove(db.profiles, db.selectedProfile)
    SelectProfile(math.min(db.selectedProfile, #db.profiles))
end)

local function CommitOriginal(text)
    local profile = CurrentProfile()
    text = text ~= "" and text or nil
    if text == profile.originalMacro then return end
    profile.originalMacro = text
    profile.originalName, profile.originalIcon, profile.originalBody = nil, nil, nil
    lastAppliedMap[profile] = nil
    RefreshStatus()
    UpdateAllMacros()
end

local function CommitSwap(text)
    local profile = CurrentProfile()
    text = text ~= "" and text or nil
    if text == profile.swapMacro then return end
    profile.swapMacro = text
    lastAppliedMap[profile] = nil
    RefreshStatus()
    UpdateAllMacros()
end

local function CommitTarget(text)
    local profile = CurrentProfile()
    text = text ~= "" and text or nil
    if text == profile.target then return end
    profile.target = text
    lastAppliedMap[profile] = nil
    RefreshStatus()
    UpdateAllMacros()
end

-- Commit on every keystroke (not just Enter/focus-lost) so a value typed and
-- then left as-is (window closed, UI reloaded, logged out) is never lost
-- waiting on a focus event that might not fire in time.
originalEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
originalEdit:SetScript("OnEditFocusLost", function(self) CommitOriginal(self:GetText()) end)
originalEdit:SetScript("OnTextChanged", function(self) CommitOriginal(self:GetText()) end)

swapEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
swapEdit:SetScript("OnEditFocusLost", function(self) CommitSwap(self:GetText()) end)
swapEdit:SetScript("OnTextChanged", function(self) CommitSwap(self:GetText()) end)

targetEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
targetEdit:SetScript("OnEditFocusLost", function(self) CommitTarget(self:GetText()) end)
targetEdit:SetScript("OnTextChanged", function(self) CommitTarget(self:GetText()) end)

win:SetScript("OnShow", function()
    local profile = CurrentProfile()
    originalEdit:SetText(profile.originalMacro or "")
    swapEdit:SetText(profile.swapMacro or "")
    targetEdit:SetText(profile.target or "")
    RefreshStatus()
    RebuildTabs()
end)

SLASH_MACROSWAP1 = "/macroswap"
SlashCmdList["MACROSWAP"] = function(msg)
    msg = (msg or ""):lower():trim()

    if msg == "debug" then
        db.debug = not db.debug
        print("|cff33ff99MacroSwap:|r debug " .. (db.debug and "ON" or "OFF"))
        return
    end

    if msg == "status" then
        for i, profile in ipairs(db.profiles) do
            dprint("Macro " .. i .. ": target='" .. tostring(profile.target) ..
                "' original='" .. tostring(profile.originalMacro) ..
                "' swap='" .. tostring(profile.swapMacro) .. "'")
        end
        UpdateAllMacros()
        return
    end

    if win:IsShown() then
        win:Hide()
    else
        win:Show()
    end
end
