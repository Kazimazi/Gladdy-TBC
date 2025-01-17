local select, string_gsub, tostring, pairs = select, string.gsub, tostring, pairs

local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
local AURA_TYPE_DEBUFF = AURA_TYPE_DEBUFF
local AURA_TYPE_BUFF = AURA_TYPE_BUFF

local UnitName, UnitAura, UnitRace, UnitClass, UnitGUID, UnitIsUnit, UnitExists = UnitName, UnitAura, UnitRace, UnitClass, UnitGUID, UnitIsUnit, UnitExists
local UnitCastingInfo, UnitChannelInfo = UnitCastingInfo, UnitChannelInfo
local GetSpellInfo = GetSpellInfo
local FindAuraByName = AuraUtil.FindAuraByName
local GetTime = GetTime

local Gladdy = LibStub("Gladdy")
local Cooldowns = Gladdy.modules["Cooldowns"]
local Diminishings = Gladdy.modules["Diminishings"]

local EventListener = Gladdy:NewModule("EventListener", nil, {
    test = true,
})

function EventListener:Initialize()
    self:RegisterMessage("JOINED_ARENA")
end

function EventListener.OnEvent(self, event, ...)
    EventListener[event](self, ...)
end

function EventListener:JOINED_ARENA()
    self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    self:RegisterEvent("ARENA_OPPONENT_UPDATE")
    self:RegisterEvent("UNIT_AURA")
    self:RegisterEvent("UNIT_SPELLCAST_START")
    self:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    self:SetScript("OnEvent", EventListener.OnEvent)

    -- in case arena has started already we check for units
    for i=1,Gladdy.curBracket do
        if UnitExists("arena" .. i) then
            Gladdy:SpotEnemy("arena" .. i, true)
        end
        if UnitExists("arenapet" .. i) then
            Gladdy:SendMessage("PET_SPOTTED", "arenapet" .. i)
        end
    end
end

function EventListener:Reset()
    self:UnregisterAllEvents()
    self:SetScript("OnEvent", nil)
end

function Gladdy:DetectSpec(unit, spec)
    if spec then
        self.modules["Cooldowns"]:DetectSpec(unit, spec)
    end
end

function Gladdy:SpotEnemy(unit, auraScan)
    local button = self.buttons[unit]
    if not unit or not button then
        return
    end
    button.raceLoc = UnitRace(unit)
    button.race = select(2, UnitRace(unit))
    button.classLoc = select(1, UnitClass(unit))
    button.class = select(2, UnitClass(unit))
    button.name = UnitName(unit)
    button.stealthed = false
    Gladdy.guids[UnitGUID(unit)] = unit
    if button.class and button.race then
        Gladdy:SendMessage("ENEMY_SPOTTED", unit)
    end
    if auraScan and not button.spec then
        for n = 1, 30 do
            local spellName,_,_,_,_,expirationTime,unitCaster = UnitAura(unit, n, "HELPFUL")
            if ( not spellName ) then
                break
            end
            if Gladdy.cooldownBuffs[spellName] then -- Check for auras that detect used CDs (like Fear Ward)
                for arenaUnit,v in pairs(self.buttons) do
                    if (UnitIsUnit(arenaUnit, unitCaster)) then
                        Cooldowns:CooldownUsed(arenaUnit, v.class, Gladdy.cooldownBuffs[spellName].spellId, expirationTime - GetTime())
                        -- /run LibStub("Gladdy").modules["Cooldowns"]:CooldownUsed("arena5", "PRIEST", 6346, 10)
                    end
                end
            end
            if Gladdy.specBuffs[spellName] then -- Check for auras that detect a spec
                local unitPet = string_gsub(unit, "%d$", "pet%1")
                if UnitIsUnit(unit, unitCaster) or UnitIsUnit(unitPet, unitCaster) then
                    Gladdy:DetectSpec(unit, Gladdy.specBuffs[spellName])
                end
            end
        end
    end
end

function EventListener:COMBAT_LOG_EVENT_UNFILTERED()
    -- timestamp,eventType,hideCaster,sourceGUID,sourceName,sourceFlags,sourceRaidFlags,destGUID,destName,destFlags,destRaidFlags,spellId,spellName,spellSchool
    local _,eventType,_,sourceGUID,_,_,_,destGUID,_,_,_,spellID,spellName,spellSchool,extraSpellId,extraSpellName,extraSpellSchool = CombatLogGetCurrentEventInfo()
    local srcUnit = Gladdy.guids[sourceGUID] -- can be a PET
    local destUnit = Gladdy.guids[destGUID] -- can be a PET
    if (Gladdy.db.shadowsightTimerEnabled and eventType == "SPELL_AURA_APPLIED" and spellID == 34709) then
        Gladdy.modules["Shadowsight Timer"]:AURA_GAIN(nil, nil, 34709)
    end

    if destUnit then
        -- diminish tracker
        if Gladdy.buttons[destUnit] and (Gladdy.db.drEnabled and (eventType == "SPELL_AURA_REMOVED" or eventType == "SPELL_AURA_REFRESH")) then
            Diminishings:AuraFade(destUnit, spellID)
        end
        -- death detection
        if (Gladdy.buttons[destUnit] and eventType == "UNIT_DIED" or eventType == "PARTY_KILL" or eventType == "SPELL_INSTAKILL") then
            Gladdy:SendMessage("UNIT_DEATH", destUnit)
        end
        -- spec detection
        if Gladdy.buttons[destUnit] and (not Gladdy.buttons[destUnit].class or not Gladdy.buttons[destUnit].race) then
            Gladdy:SpotEnemy(destUnit, true)
        end
        --interrupt detection
        if Gladdy.buttons[destUnit] and eventType == "SPELL_INTERRUPT" then
            Gladdy:SendMessage("SPELL_INTERRUPT", destUnit,spellID,spellName,spellSchool,extraSpellId,extraSpellName,extraSpellSchool)
        end
    end
    if srcUnit then
        srcUnit = string_gsub(srcUnit, "pet", "")
        if (not UnitExists(srcUnit)) then
            return
        end
        if (eventType == "SPELL_CAST_SUCCESS" or eventType == "SPELL_AURA_APPLIED") then
            local unitRace = Gladdy.buttons[srcUnit].race
            -- cooldown tracker
            if Gladdy.db.cooldown and Cooldowns.cooldownSpellIds[spellName] then
                local unitClass
                local spellId = Cooldowns.cooldownSpellIds[spellName] -- don't use spellId from combatlog, in case of different spellrank
                if Gladdy.db.cooldownCooldowns[tostring(spellId)] then
                    if (Gladdy:GetCooldownList()[Gladdy.buttons[srcUnit].class][spellId]) then
                        unitClass = Gladdy.buttons[srcUnit].class
                    else
                        unitClass = Gladdy.buttons[srcUnit].race
                    end
                    Cooldowns:CooldownUsed(srcUnit, unitClass, spellId)
                    Gladdy:DetectSpec(srcUnit, Gladdy.specSpells[spellName])
                end
            end

            if Gladdy.db.racialEnabled and Gladdy:Racials()[unitRace].spellName == spellName and Gladdy:Racials()[unitRace][spellID] then
                Gladdy:SendMessage("RACIAL_USED", srcUnit)
            end
        end

        if not Gladdy.buttons[srcUnit].class or not Gladdy.buttons[srcUnit].race then
            Gladdy:SpotEnemy(srcUnit, true)
        end
        if not Gladdy.buttons[srcUnit].spec then
            Gladdy:DetectSpec(srcUnit, Gladdy.specSpells[spellName])
        end
    end
end

function EventListener:ARENA_OPPONENT_UPDATE(unit, updateReason)
    --[[ updateReason: seen, unseen, destroyed, cleared ]]

    local button = Gladdy.buttons[unit]
    local pet = Gladdy.modules["Pets"].frames[unit]
    if button or pet then
        if updateReason == "seen" then
            -- ENEMY_SPOTTED
            if button then
                Gladdy:SendMessage("ENEMY_STEALTH", unit, false)
                if not button.class or not button.race then
                    Gladdy:SpotEnemy(unit, true)
                end
            end
            if pet then
                Gladdy:SendMessage("PET_SPOTTED", unit)
            end
        elseif updateReason == "unseen" then
            -- STEALTH
            if button then
                Gladdy:SendMessage("ENEMY_STEALTH", unit, true)
            end
            if pet then
                Gladdy:SendMessage("PET_STEALTH", unit)
            end
        elseif updateReason == "destroyed" then
            -- LEAVE
            if button then
                Gladdy:SendMessage("UNIT_DESTROYED", unit)
            end
            if pet then
                Gladdy:SendMessage("PET_DESTROYED", unit)
            end
        elseif updateReason == "cleared" then
            --Gladdy:Print("ARENA_OPPONENT_UPDATE", updateReason, unit)
        end
    end
end

Gladdy.exceptionNames = { -- TODO MOVE ME TO CLASSBUFFS LIB
    [31117] = GetSpellInfo(30405) .. " Silence", -- Unstable Affliction Silence
    [43523] = GetSpellInfo(30405) .. " Silence",
    [24131] = select(1, GetSpellInfo(19386)) .. " Dot", -- Wyvern Sting Dot
    [24134] = select(1, GetSpellInfo(19386)) .. " Dot",
    [24135] = select(1, GetSpellInfo(19386)) .. " Dot",
    [27069] = select(1, GetSpellInfo(19386)) .. " Dot",
    [19975] = select(1, GetSpellInfo(27010)) .. " " .. select(1, GetSpellInfo(16689)), -- Entangling Roots Nature's Grasp
    [19974] = select(1, GetSpellInfo(27010)) .. " " .. select(1, GetSpellInfo(16689)),
    [19973] = select(1, GetSpellInfo(27010)) .. " " .. select(1, GetSpellInfo(16689)),
    [19972] = select(1, GetSpellInfo(27010)) .. " " .. select(1, GetSpellInfo(16689)),
    [19971] = select(1, GetSpellInfo(27010)) .. " " .. select(1, GetSpellInfo(16689)),
    [19971] = select(1, GetSpellInfo(27010)) .. " " .. select(1, GetSpellInfo(16689)),
    [27010] = select(1, GetSpellInfo(27010)) .. " " .. select(1, GetSpellInfo(16689)),
}

Gladdy.cooldownBuffs = {
    [GetSpellInfo(6346)] = { cd = 180, spellId = 6346 }, -- Fear Ward
}

function EventListener:UNIT_AURA(unit)
    local button = Gladdy.buttons[unit]
    if not button then
        return
    end
    for i = 1, 2 do
        if not Gladdy.buttons[unit].class or not Gladdy.buttons[unit].race then
            Gladdy:SpotEnemy(unit, false)
        end
        local filter = (i == 1 and "HELPFUL" or "HARMFUL")
        local auraType = i == 1 and AURA_TYPE_BUFF or AURA_TYPE_DEBUFF
        Gladdy:SendMessage("AURA_FADE", unit, auraType)
        for n = 1, 30 do
            local spellName, texture, count, debuffType, duration, expirationTime, unitCaster, _, shouldConsolidate, spellID = UnitAura(unit, n, filter)
            if ( not spellID ) then
                Gladdy:SendMessage("AURA_GAIN_LIMIT", unit, auraType, n - 1)
                break
            end
            if Gladdy.cooldownBuffs[spellName] then -- Check for auras that hint used CDs (like Fear Ward)
                for arenaUnit,v in pairs(Gladdy.buttons) do
                    if (UnitIsUnit(arenaUnit, unitCaster)) then
                        Cooldowns:CooldownUsed(arenaUnit, v.class, Gladdy.cooldownBuffs[spellName].spellId, expirationTime - GetTime())
                    end
                end
            end
            if not button.spec and Gladdy.specBuffs[spellName] then
                local unitPet = string_gsub(unit, "%d$", "pet%1")
                if unitCaster and (UnitIsUnit(unit, unitCaster) or UnitIsUnit(unitPet, unitCaster)) then
                    Gladdy:DetectSpec(unit, Gladdy.specBuffs[spellName])
                end
            end
            if Gladdy.exceptionNames[spellID] then
                spellName = Gladdy.exceptionNames[spellID]
            end
            Gladdy:SendMessage("AURA_GAIN", unit, auraType, spellID, spellName, texture, duration, expirationTime, count, debuffType, i)
            Gladdy:Call("Announcements", "CheckDrink", unit, spellName)
        end
    end
end

function EventListener:UNIT_SPELLCAST_START(unit)
    if Gladdy.buttons[unit] then
        local spellName = UnitCastingInfo(unit)
        if Gladdy.specSpells[spellName] and not Gladdy.buttons[unit].spec then
            Gladdy:DetectSpec(unit, Gladdy.specSpells[spellName])
        end
    end
end

function EventListener:UNIT_SPELLCAST_CHANNEL_START(unit)
    if Gladdy.buttons[unit] then
        local spellName = UnitChannelInfo(unit)
        if Gladdy.specSpells[spellName] and not Gladdy.buttons[unit].spec then
            Gladdy:DetectSpec(unit, Gladdy.specSpells[spellName])
        end
    end
end

function EventListener:UNIT_SPELLCAST_SUCCEEDED(unit)
    if Gladdy.buttons[unit] then
        local spellName = UnitCastingInfo(unit)
        if Gladdy.specSpells[spellName] and not Gladdy.buttons[unit].spec then
            Gladdy:DetectSpec(unit, Gladdy.specSpells[spellName])
        end
    end
end
