-- ZoneRecipeWaypoints: on zone entry, TomTom waypoints for recipe trainers/vendors of your professions (data: RecipeRadar)

local ADDON = "ZoneRecipeWaypoints"
local RR = _G.RecipeRadar
local PREFIX = "|cff33ccff" .. ADDON .. "|r: "
local MAX_LABEL_RECIPES = 6

local defaults = { enabled = true, learnableOnly = true, max = 12, verbose = true, hideSeasonal = true }
local placed = {}
local lastZoneId

local function Print(msg) print(PREFIX .. msg) end

local function Settings()
    ZoneRecipeWaypointsDB = ZoneRecipeWaypointsDB or {}
    for k, v in pairs(defaults) do
        if ZoneRecipeWaypointsDB[k] == nil then ZoneRecipeWaypointsDB[k] = v end
    end
    return ZoneRecipeWaypointsDB
end

-- Winter Veil patterns that RecipeRadar's data does not flag as holiday recipes
local SEASONAL_IDS = { [44950] = true, [44953] = true, [44958] = true }

local function IsSeasonal(recipe)
    if recipe.holiday or SEASONAL_IDS[recipe.id] then return true end
    for _, itemId in ipairs(type(recipe.items) == "table" and recipe.items or {}) do
        local item = RR.DB:GetItem(itemId)
        if item and item.holiday then return true end
    end
    return false
end

-- RecipeRadar's list and counts and our waypoints all read recipes through this one function,
-- so filtering it here hides seasonal recipes everywhere without editing RecipeRadar's files
if RR and RR.DB and RR.DB.GetRecipesForProfession then
    local allRecipes = RR.DB.GetRecipesForProfession
    local filtered = setmetatable({}, { __mode = "k" })
    RR.DB.GetRecipesForProfession = function(db, profession)
        local list = allRecipes(db, profession)
        if #list == 0 or not Settings().hideSeasonal then return list end
        if not filtered[list] then
            local kept = {}
            for _, recipe in ipairs(list) do
                if not IsSeasonal(recipe) then kept[#kept + 1] = recipe end
            end
            filtered[list] = kept
        end
        return filtered[list]
    end
end

local function ClearWaypoints()
    local tomtom = _G.TomTom
    if tomtom and tomtom.RemoveWaypoint then
        for _, uid in ipairs(placed) do pcall(tomtom.RemoveWaypoint, tomtom, uid) end
    end
    wipe(placed)
end

-- Adds every npc id in a source list to the zone's candidate table.
-- pickup = { key, name, skill } describes the recipe this npc offers.
local function CollectNpcs(list, zoneId, ownFaction, out, prof, pickup)
    if type(list) ~= "table" then return end
    for _, npcId in ipairs(list) do
        local npc = RR.DB:GetNPC(npcId)
        if npc then
            local npcZone = (npc.location and npc.location.zone_id) or npc.zone_id
            local reacts = npc.reacts
            local hostile = reacts == "Hostile" or (reacts and reacts ~= "Neutral" and reacts ~= ownFaction and (reacts == "Alliance" or reacts == "Horde"))
            local x = npc.location and tonumber(npc.location.x)
            local y = npc.location and tonumber(npc.location.y)
            if npcZone == zoneId and not hostile and x and y then
                local entry = out[npcId]
                if not entry then
                    entry = { npc = npc, x = x, y = y, profs = {}, seen = {}, pickups = {} }
                    out[npcId] = entry
                end
                -- one npc can be listed twice for a recipe (recipe and recipe item)
                if not entry.seen[pickup.key] then
                    entry.seen[pickup.key] = true
                    entry.pickups[#entry.pickups + 1] = pickup
                end
                entry.profs[prof] = true
            end
        end
    end
end

local function SourceList(src)
    if type(src) ~= "table" then return nil end
    return src.sources or src
end

-- Waypoint label: npc and professions, then one line per recipe to pick up there
local function BuildTitle(entry)
    local profNames = {}
    for p in pairs(entry.profs) do profNames[#profNames + 1] = p end
    table.sort(profNames)
    table.sort(entry.pickups, function(a, b)
        if (a.skill or 0) ~= (b.skill or 0) then return (a.skill or 0) < (b.skill or 0) end
        return a.name < b.name
    end)

    local lines = { string.format("%s (%s)", RR.DB:GetLocalizedText(entry.npc.name), table.concat(profNames, ", ")) }
    for i = 1, math.min(#entry.pickups, MAX_LABEL_RECIPES) do
        local p = entry.pickups[i]
        lines[#lines + 1] = p.skill and string.format("%s (%d)", p.name, p.skill) or p.name
    end
    if #entry.pickups > MAX_LABEL_RECIPES then
        lines[#lines + 1] = string.format("+%d more", #entry.pickups - MAX_LABEL_RECIPES)
    end
    return table.concat(lines, "\n")
end

-- True when the client itself says this character already has the spell or recipe
local function ClientKnows(spellId)
    if not spellId then return false end
    local isKnown = (C_SpellBook and C_SpellBook.IsSpellKnown) or IsPlayerSpell
    if isKnown then
        local ok, known = pcall(isKnown, spellId)
        if ok and known == true then return true end
    end
    if C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
        local ok, learned = pcall(function() return C_TradeSkillUI.GetRecipeInfo(spellId).learned == true end)
        if ok and learned then return true end
    end
    return false
end

-- True when the teaching item is already in this character's bags or bank
local function HasRecipeItem(recipe)
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    if not count or type(recipe.items) ~= "table" then return false end
    for _, itemId in ipairs(recipe.items) do
        local ok, n = pcall(count, itemId, true)
        if ok and (tonumber(n) or 0) > 0 then return true end
    end
    return false
end

local function ClassAllowed(recipe)
    if type(recipe.classes) ~= "table" then return true end
    local _, class = UnitClass("player")
    for _, c in ipairs(recipe.classes) do
        if c:upper():gsub("%s", "") == class then return true end
    end
    return false
end

-- True only for a recipe this character can still use and does not have yet
local function IsNeeded(prof, recipe, spellId, name)
    if RR.Scanner:IsRecipeKnown(prof, spellId, name) or ClientKnows(spellId) then return false end
    if not ClassAllowed(recipe) then return false end
    if recipe.specialisation and recipe.specialisation ~= 0 and not ClientKnows(recipe.specialisation) then return false end
    return not HasRecipeItem(recipe)
end

-- False until RecipeRadar has recorded known recipes; without that every recipe would look missing
local function HasKnownList(prof)
    local data = RR.Scanner:GetProfessionData(RR.Config:GetCurrentChar(), prof)
    return data ~= nil and type(data.known) == "table" and next(data.known) ~= nil
end

-- Skill points above the current rank to include: none unless RecipeRadar's "Learnable Soon" is ticked
local function SoonMargin()
    if RR.Config:GetFilterSetting("learnableSoon") ~= true then return 0 end
    return RR.LEARNABLE_SOON_MARGIN or 25
end

local function Run(force)
    local cfg = Settings()
    if not cfg.enabled or not (RR and RR.DB and RR.Scanner and RR.Config and RR.DB.npcMap) then return end

    local zoneId = RR.DB:GetCurrentZoneId()
    if not zoneId or (zoneId == lastZoneId and not force) then return end
    lastZoneId = zoneId

    local tomtom = _G.TomTom
    if not (tomtom and tomtom.AddWaypoint) then
        if cfg.verbose then Print("TomTom is not loaded, no waypoints set.") end
        return
    end

    local okProfs, learned = pcall(RR.Scanner.GetLearnedProfessions, RR.Scanner)
    if not okProfs or type(learned) ~= "table" or #learned == 0 then return end

    local ownFaction = UnitFactionGroup("player") or "Neutral"
    local zoneName = RR.DB:GetZoneName(zoneId)
    local candidates = {}

    local unscanned = {}
    local level = UnitLevel("player")

    for _, prof in ipairs(learned) do
        local scanned = HasKnownList(prof)
        if not scanned then unscanned[#unscanned + 1] = prof end
        local rank = RR.Scanner:GetSkillRank(prof)
        local maxSkill = rank and (rank + SoonMargin())
        for _, recipe in ipairs(scanned and RR.DB:GetRecipesForProfession(prof) or {}) do
            local spellId = recipe.id or recipe.spell_id
            local name = RR.DB:GetLocalizedText(recipe.name)
            local needed = IsNeeded(prof, recipe, spellId, name)
            if needed and cfg.learnableOnly then
                -- like RecipeRadar's filter, an unknown requirement does not count as learnable
                if maxSkill and (not recipe.min_skill or recipe.min_skill > maxSkill) then needed = false end
                if recipe.min_xp_level and recipe.min_xp_level > level then needed = false end
            end
            if needed then
                local label = name or ("spell " .. tostring(spellId))
                local pickup = { key = prof .. ":" .. tostring(spellId or label), name = label, skill = recipe.min_skill }
                if recipe.trainers then CollectNpcs(SourceList(recipe.trainers), zoneId, ownFaction, candidates, prof, pickup) end
                if recipe.vendors then CollectNpcs(SourceList(recipe.vendors), zoneId, ownFaction, candidates, prof, pickup) end
                if type(recipe.items) == "table" then
                    for _, itemId in ipairs(recipe.items) do
                        local item = RR.DB:GetItem(itemId)
                        if item and item.vendors then CollectNpcs(SourceList(item.vendors), zoneId, ownFaction, candidates, prof, pickup) end
                    end
                end
            end
        end
    end

    local list = {}
    for _, entry in pairs(candidates) do list[#list + 1] = entry end
    table.sort(list, function(a, b)
        if #a.pickups ~= #b.pickups then return #a.pickups > #b.pickups end
        return a.npc.id < b.npc.id
    end)

    if cfg.verbose and #unscanned > 0 then
        Print("skipped " .. table.concat(unscanned, ", ") .. ": open that profession window once so known recipes can be read.")
    end

    ClearWaypoints()
    local mapId = RR.Utils:FindMapIdByName(zoneName) or (C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"))
    if not mapId or #list == 0 then
        if cfg.verbose and #list == 0 then Print("No missing recipe trainers or vendors in " .. zoneName .. ".") end
        return
    end

    local shown = 0
    for _, entry in ipairs(list) do
        if shown >= cfg.max then break end
        local title = BuildTitle(entry)
        local ok, uid = pcall(tomtom.AddWaypoint, tomtom, mapId, entry.x / 100, entry.y / 100,
            { title = title, from = ADDON, persistent = false })
        if ok and uid then placed[#placed + 1] = uid end
        shown = shown + 1
    end

    if cfg.verbose then
        Print(string.format("%d waypoint(s) for %s%s.", shown, zoneName, #list > shown and string.format(" (%d more, raise with /zrw max)", #list - shown) or ""))
    end
end

local pending, pendingForce
local function Schedule(force)
    pendingForce = pendingForce or force
    if pending then return end
    pending = true
    C_Timer.After(2, function()
        local forced = pendingForce
        pending, pendingForce = nil, nil
        local ok, err = pcall(Run, forced)
        if not ok then Print("error: " .. tostring(err)) end
    end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
pcall(frame.RegisterEvent, frame, "NEW_RECIPE_LEARNED")
-- learning a recipe refreshes the zone, so a waypoint that is no longer needed goes away
frame:SetScript("OnEvent", function(_, event) Schedule(event == "NEW_RECIPE_LEARNED") end)

-- ticking or clearing "Learnable Soon" in RecipeRadar refreshes the waypoints
if hooksecurefunc and RR and RR.Config and RR.Config.SetFilterSetting then
    hooksecurefunc(RR.Config, "SetFilterSetting", function(_, key)
        if key == "learnableSoon" then Schedule(true) end
    end)
end

SLASH_ZONERECIPEWAYPOINTS1 = "/zrw"
SlashCmdList["ZONERECIPEWAYPOINTS"] = function(msg)
    local cfg = Settings()
    local cmd, arg = (msg or ""):lower():match("^(%S*)%s*(.-)$")
    if cmd == "on" or cmd == "off" then
        cfg.enabled = cmd == "on"
        if not cfg.enabled then ClearWaypoints() end
        Print(cfg.enabled and "enabled." or "disabled, waypoints cleared.")
    elseif cmd == "all" then
        cfg.learnableOnly = false
        Print("all missing recipes in the zone. Run /zrw to refresh.")
    elseif cmd == "learnable" then
        cfg.learnableOnly = true
        Print("only recipes learnable now, plus soon ones if \"Learnable Soon\" is ticked in RecipeRadar. Run /zrw to refresh.")
    elseif cmd == "max" and tonumber(arg) then
        cfg.max = math.max(1, math.min(60, math.floor(tonumber(arg))))
        Print("max waypoints per zone: " .. cfg.max)
    elseif cmd == "seasonal" then
        cfg.hideSeasonal = not cfg.hideSeasonal
        if RR and RR.DB then RR.DB.totalRecipesCache = nil end
        local window = RR and RR.UI and RR.UI.MainWindow
        if window and window.IsShown and window:IsShown() then window:Refresh() end
        Print(cfg.hideSeasonal and "seasonal recipes hidden." or "seasonal recipes shown.")
        Schedule(true)
    elseif cmd == "quiet" then
        cfg.verbose = not cfg.verbose
        Print(cfg.verbose and "chat messages on." or "chat messages off.")
    elseif cmd == "clear" then
        ClearWaypoints()
        Print("waypoints cleared.")
    elseif cmd == "" or cmd == "run" then
        Schedule(true)
    else
        Print("/zrw [run] | on | off | all | learnable | max N | seasonal | quiet | clear")
    end
end
