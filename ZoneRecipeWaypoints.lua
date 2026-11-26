-- ZoneRecipeWaypoints: on zone entry, TomTom waypoints for recipe trainers/vendors of your professions (data: RecipeRadar)

local ADDON = "ZoneRecipeWaypoints"
local RR = _G.RecipeRadar
local PREFIX = "|cff33ccff" .. ADDON .. "|r: "

local defaults = { enabled = true, learnableOnly = true, max = 12, verbose = true }
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

local function ClearWaypoints()
    local tomtom = _G.TomTom
    if tomtom and tomtom.RemoveWaypoint then
        for _, uid in ipairs(placed) do pcall(tomtom.RemoveWaypoint, tomtom, uid) end
    end
    wipe(placed)
end

-- Adds every npc id in a source list to the zone's candidate table
local function CollectNpcs(list, zoneId, ownFaction, out, prof)
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
                    entry = { npc = npc, x = x, y = y, count = 0, profs = {} }
                    out[npcId] = entry
                end
                entry.count = entry.count + 1
                entry.profs[prof] = true
            end
        end
    end
end

local function SourceList(src)
    if type(src) ~= "table" then return nil end
    return src.sources or src
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

    for _, prof in ipairs(learned) do
        local rank = RR.Scanner:GetSkillRank(prof)
        local maxSkill = rank and (rank + (RR.LEARNABLE_SOON_MARGIN or 25))
        for _, recipe in ipairs(RR.DB:GetRecipesForProfession(prof)) do
            local spellId = recipe.id or recipe.spell_id
            local name = RR.DB:GetLocalizedText(recipe.name)
            local needed = not RR.Scanner:IsRecipeKnown(prof, spellId, name)
            if needed and cfg.learnableOnly and recipe.min_skill and maxSkill and recipe.min_skill > maxSkill then
                needed = false
            end
            if needed then
                if recipe.trainers then CollectNpcs(SourceList(recipe.trainers), zoneId, ownFaction, candidates, prof) end
                if recipe.vendors then CollectNpcs(SourceList(recipe.vendors), zoneId, ownFaction, candidates, prof) end
                if type(recipe.items) == "table" then
                    for _, itemId in ipairs(recipe.items) do
                        local item = RR.DB:GetItem(itemId)
                        if item and item.vendors then CollectNpcs(SourceList(item.vendors), zoneId, ownFaction, candidates, prof) end
                    end
                end
            end
        end
    end

    local list = {}
    for _, entry in pairs(candidates) do list[#list + 1] = entry end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.npc.id < b.npc.id
    end)

    ClearWaypoints()
    local mapId = RR.Utils:FindMapIdByName(zoneName) or (C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"))
    if not mapId or #list == 0 then
        if cfg.verbose and #list == 0 then Print("No missing recipe trainers or vendors in " .. zoneName .. ".") end
        return
    end

    local shown = 0
    for _, entry in ipairs(list) do
        if shown >= cfg.max then break end
        local profNames = {}
        for p in pairs(entry.profs) do profNames[#profNames + 1] = p end
        table.sort(profNames)
        local title = string.format("%s (%d: %s)", RR.DB:GetLocalizedText(entry.npc.name), entry.count, table.concat(profNames, ", "))
        local ok, uid = pcall(tomtom.AddWaypoint, tomtom, mapId, entry.x / 100, entry.y / 100,
            { title = title, from = ADDON, persistent = false })
        if ok and uid then placed[#placed + 1] = uid end
        shown = shown + 1
    end

    if cfg.verbose then
        Print(string.format("%d waypoint(s) for %s%s.", shown, zoneName, #list > shown and string.format(" (%d more, raise with /zrw max)", #list - shown) or ""))
    end
end

local pending
local function Schedule(force)
    if pending then return end
    pending = true
    C_Timer.After(2, function()
        pending = nil
        local ok, err = pcall(Run, force)
        if not ok then Print("error: " .. tostring(err)) end
    end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:SetScript("OnEvent", function() Schedule(false) end)

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
        Print("only recipes learnable now or within " .. (RR and RR.LEARNABLE_SOON_MARGIN or 25) .. " skill points. Run /zrw to refresh.")
    elseif cmd == "max" and tonumber(arg) then
        cfg.max = math.max(1, math.min(60, math.floor(tonumber(arg))))
        Print("max waypoints per zone: " .. cfg.max)
    elseif cmd == "quiet" then
        cfg.verbose = not cfg.verbose
        Print(cfg.verbose and "chat messages on." or "chat messages off.")
    elseif cmd == "clear" then
        ClearWaypoints()
        Print("waypoints cleared.")
    elseif cmd == "" or cmd == "run" then
        Schedule(true)
    else
        Print("/zrw [run] | on | off | all | learnable | max N | quiet | clear")
    end
end
