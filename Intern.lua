-- Intern: opt-in daily-quest tracker with a floating tracker window.
-- See README/plan for the full design.

local addonName, Intern = ...
LibStub("AceAddon-3.0"):NewAddon(Intern, addonName, "AceConsole-3.0", "AceEvent-3.0")

local AceGUI    = LibStub("AceGUI-3.0")
local LDB       = LibStub("LibDataBroker-1.1")
local LibDBIcon = LibStub("LibDBIcon-1.0", true)

-- Per-character key used in Intern_Char.
local charKey = UnitName("player") .. "-" .. GetRealmName()

-- Module-local UI state (resets on /reload).
local mainFrame = nil
local browseCollapsed = {}

-- Cached at OnEnable.
local playerFaction = ""    -- "Horde" / "Alliance"
local isAldor       = false
local isScryer      = false

-- Standard Aldor/Scryer rep IDs.
local FACTION_ALDOR  = 932
local FACTION_SCRYER = 934

-- Zone-name -> uiMapID lookup. Built lazily by scanning C_Map.GetMapInfo at
-- first use because uiMapIDs differ between client flavors (Anniversary/TBC
-- Classic uses different values than retail), so a hardcoded table goes stale.
local _zoneNameToMapID = nil

local function buildZoneCache()
	_zoneNameToMapID = {}
	if not (C_Map and C_Map.GetMapInfo) then return end
	for id = 1, 3500 do
		local info = C_Map.GetMapInfo(id)
		if info and info.name and info.name ~= "" and info.mapType then
			-- Prefer Zone-type maps (mapType 3) over Continent (2) or others when
			-- the same name is used at multiple levels — the player's quest data
			-- always refers to a specific zone.
			local existing = _zoneNameToMapID[info.name]
			if not existing or info.mapType == 3 then
				_zoneNameToMapID[info.name] = id
			end
		end
	end
end

function Intern.GetUiMapIdForZone(zoneName)
	if not zoneName or zoneName == "" then return nil end
	if not _zoneNameToMapID then buildZoneCache() end
	return _zoneNameToMapID[zoneName]
end

-- Faction names for tooltip rep display. WoW's GetFactionInfoByID(id) only
-- returns a name for factions the player has discovered, so we keep our own
-- table for the TBC reps that show up in our quest data.
local FACTION_NAMES = {
	[47]   = "Ironforge",
	[54]   = "Gnomeregan Exiles",
	[68]   = "Undercity",
	[69]   = "Darnassus",
	[72]   = "Stormwind",
	[76]   = "Orgrimmar",
	[81]   = "Thunder Bluff",
	[530]  = "Darkspear Trolls",
	[729]  = "Frostwolf Clan",
	[730]  = "Stormpike Guard",
	[890]  = "Silvermoon City",
	[911]  = "Silvermoon City",
	[930]  = "Exodar",
	[932]  = "The Aldor",
	[933]  = "The Consortium",
	[934]  = "The Scryers",
	[935]  = "The Sha'tar",
	[941]  = "The Mag'har",
	[942]  = "Cenarion Expedition",
	[946]  = "Honor Hold",
	[947]  = "Thrallmar",
	[970]  = "Sporeggar",
	[978]  = "Kurenai",
	[989]  = "Keepers of Time",
	[1011] = "Lower City",
	[1012] = "The Ashtongue Deathsworn",
	[1015] = "Netherwing",
	[1031] = "Sha'tari Skyguard",
	[1038] = "Ogri'la",
	[1077] = "Shattered Sun Offensive",
}

local function getFactionName(id)
	local name = GetFactionInfoByID(id)
	return name or FACTION_NAMES[id] or ("Faction " .. id)
end

-- Public wrapper so InternTracker.lua / browse rendering can label rep
-- subheaders by faction name without duplicating the table.
function Intern.GetFactionName(id) return getFactionName(id) end

-- Pick the "primary" faction a quest rewards rep for — defined as the
-- highest-amount rep faction the player isn't yet capped on (per-quest cap
-- via REP_CAPS, default Exalted). Ties broken by lowest factionID for
-- determinism. This matches what's actually useful to the player: Fel
-- Armaments shows up under "The Sha'tar" (the rep still being earned)
-- once Aldor is Exalted, even though Aldor is the larger numeric reward.
-- If every rewarded faction is at cap, falls back to the highest overall —
-- so sub-grouping still has a sensible bucket when the at-cap filter is
-- disabled. Returns nil if the quest has no rep rewards.
function Intern.GetPrimaryRepFaction(qid)
	local info = Intern_Quests and Intern_Quests[qid]
	if not info or not info.reps then return nil end
	local bestFid, bestVal
	for fid, val in pairs(info.reps) do
		if not Intern.IsRepCapped(qid, fid) then
			if not bestFid or val > bestVal or (val == bestVal and fid < bestFid) then
				bestFid, bestVal = fid, val
			end
		end
	end
	if bestFid then return bestFid end
	-- Fallback: every rewarded faction is at cap; pick the highest overall.
	for fid, val in pairs(info.reps) do
		if not bestFid or val > bestVal or (val == bestVal and fid < bestFid) then
			bestFid, bestVal = fid, val
		end
	end
	return bestFid
end

-- Try to set a TomTom waypoint at the questgiver's location for `qid`. No-op
-- if TomTom isn't loaded or the quest has no usable coordinate data.
function Intern.SetWaypoint(qid)
	local TomTom = _G.TomTom
	if not TomTom or not TomTom.AddWaypoint then
		print("|cffff00ff[Intern]|r TomTom is not loaded; cannot set waypoint.")
		return
	end
	local info = Intern_Quests and Intern_Quests[qid]
	if not info then return end
	if not info.coords then
		print("|cffff00ff[Intern]|r No coordinates known for quest " .. (info.title or qid) .. ".")
		return
	end
	if not info.zone or info.zone == "" then
		print("|cffff00ff[Intern]|r No zone known for quest " .. (info.title or qid) .. ".")
		return
	end

	local mapID = Intern.GetUiMapIdForZone(info.zone)
	if not mapID then
		print("|cffff00ff[Intern]|r Couldn't resolve uiMapID for zone '" .. info.zone .. "'.")
		return
	end

	local title = info.title
	if info.npc and info.npc ~= "" then
		title = title .. " (" .. info.npc .. ")"
	end

	-- Mimic Questie's TomTom integration: pass crazy=true for the on-screen
	-- arrow, and let TomTom's profile defaults handle minimap/worldmap visibility.
	-- Track our last waypoint so subsequent Ctrl+Clicks replace it.
	if Intern_Char and Intern_Char[charKey] and Intern_Char[charKey]._tom_waypoint
	   and TomTom.RemoveWaypoint then
		pcall(function() TomTom:RemoveWaypoint(Intern_Char[charKey]._tom_waypoint) end)
		Intern_Char[charKey]._tom_waypoint = nil
	end

	local wp
	local ok, err = pcall(function()
		wp = TomTom:AddWaypoint(mapID, info.coords.x / 100, info.coords.y / 100, {
			title = title,
			from = "Intern",
			crazy = true,
		})
	end)
	if not ok then
		print("|cffff00ff[Intern]|r TomTom:AddWaypoint errored: " .. tostring(err))
		return
	end
	if Intern_Char and Intern_Char[charKey] then
		Intern_Char[charKey]._tom_waypoint = wp
	end
end

-- Build a multiline string of quest details for the GameTooltip.
function Intern.GetQuestTooltip(qid)
	local info = Intern_Quests and Intern_Quests[qid]
	if not info then return nil end

	local lines = {}
	table.insert(lines, "|cffffd100" .. info.title .. "|r")

	if info.npc and info.npc ~= "" then
		table.insert(lines, "|cff808080NPC:|r " .. info.npc)
	end

	local locline = info.zone or ""
	if info.subzone and info.subzone ~= "" then
		locline = locline ~= "" and (locline .. " - " .. info.subzone) or info.subzone
	end
	if locline ~= "" then
		table.insert(lines, "|cff808080Zone:|r " .. locline)
	end

	if info.coords then
		table.insert(lines, string.format("|cff808080Coords:|r %.1f, %.1f", info.coords.x, info.coords.y))
	end

	if info.faction then
		table.insert(lines, "|cff808080Faction:|r " .. info.faction)
	end

	if info.reps and next(info.reps) then
		table.insert(lines, "|cff808080Rep rewards:|r")
		for fid, val in pairs(info.reps) do
			table.insert(lines, string.format("  +%d %s", val, getFactionName(fid)))
		end
	end

	table.insert(lines, " ")
	if _G.TomTom then
		table.insert(lines, "|cff60c0ffCtrl+Click|r set TomTom waypoint")
	end
	table.insert(lines, "|cff60c0ffShift+Click|r untrack")

	return table.concat(lines, "\n")
end

-- Profession names by locale -- minimal subset matching what Dailies has.
-- We only need this if we later gate on professions; for now we read the player's
-- known professions via GetSkillLineInfo and stash them.
local PROF_NAMES_ENUS = {
	[129] = "First Aid",
	[164] = "Blacksmithing",
	[165] = "Leatherworking",
	[171] = "Alchemy",
	[182] = "Herbalism",
	[185] = "Cooking",
	[186] = "Mining",
	[197] = "Tailoring",
	[202] = "Engineering",
	[333] = "Enchanting",
	[356] = "Fishing",
	[393] = "Skinning",
	[755] = "Jewelcrafting",
	[773] = "Inscription",
}

-- Inverse name -> profession ID lookup, populated in OnEnable.
local profIdByName = {}

-- Quest IDs whose category is PvP but whose zone alone doesn't make that obvious.
-- (Hellfire Fortifications zone is "Hellfire Peninsula" which is shared with non-PvP
-- content; Halaa quests are zone "Nagrand"; Auchindoun ring towers are "Terokkar Forest".)
-- Quest IDs whose primary reward is honor — BG Call to Arms (handled also by
-- zone/NPC heuristics) plus tower-control / ring-tower / Halaa PvP dailies that
-- aren't in BG zones but reward honor as their headline reward.
Intern.HonorQuestIds = {
	[10110] = true, [10106] = true,                    -- Hellfire Fortifications H/A
	[10346] = true, [10347] = true,                    -- Return to the Abyssal Shelf
	[11502] = true, [11503] = true,                    -- Halaa offensive
	-- 10477/10478 (More Warbeads) deliberately NOT here — primary reward
	-- is faction reputation (Kurenai / The Mag'har), not honor.
	[11505] = true, [11506] = true,                    -- Spirits of Auchindoun (ring towers)
}

-- BG zones — quests sorted under these are inherently honor.
local HONOR_ZONES = {
	["Arathi Basin"]    = true,
	["Warsong Gulch"]   = true,
	["Alterac Valley"]  = true,
	["Eye of the Storm"] = true,
}

-- Cooking/Fishing daily NPCs. Used for category detection.
local COOKING_NPC = "The Rokk"
local FISHING_NPC = "Old Man Barlo"

-- NPC -> profession ID lookup, used by the "hide profession dailies the player
-- can't take" filter in QuestPassesFilters.
local TRADESKILL_BY_NPC = {
	[COOKING_NPC] = 185,
	[FISHING_NPC] = 356,
}

-- Render order for category buckets within a Section. Alphabetical for
-- predictability; the table makes it easy to special-case later if we want.
Intern.CATEGORY_ORDER = {
	cooking    = 1,
	fishing    = 2,
	gold       = 3,
	honor      = 4,
	reputation = 5,
	wanted     = 6,
}

-- Display labels for categories (Title Case — UI uses these instead of the
-- lowercase keys). The internal key for the Lower City heroic+normal dungeon
-- dailies is "wanted" (because every quest title in that pool starts with
-- "Wanted:") but the user-facing label reads as "Dungeons" since that's
-- what they actually are.
Intern.CATEGORY_LABEL = {
	cooking    = "Cooking",
	fishing    = "Fishing",
	gold       = "Gold",
	honor      = "Honor",
	reputation = "Reputation",
	wanted     = "Dungeons",
}

-- Profession daily cooldowns. Keyed by spellID. Each entry is shown in the
-- browse window as opt-in, and in the tracker as a "Cooldowns" section row
-- with state derived from GetSpellCooldown.
--
-- Scope today is TBC Alchemy — the only TBC profession with daily-CD recipes
-- the user has on their characters. Enchanting (Void Shatter), Leatherworking
-- (Ebonweave/Moonshroud/Spellweave), and Jewelcrafting (Brilliant Glass) all
-- got their daily CDs in Wrath; nothing to add for them in TBC. Tailoring's
-- specialty cloths (Mooncloth/Primal Mooncloth/Spellcloth/Shadowcloth) would
-- belong here too but the user has no tailor.
Intern.ProfessionCDs = {
	-- Elemental transmutes (Phase 1)
	[28566] = { name = "Transmute: Primal Air to Fire",    profession = "Alchemy" },
	[28567] = { name = "Transmute: Primal Earth to Water", profession = "Alchemy" },
	[28568] = { name = "Transmute: Primal Fire to Earth",  profession = "Alchemy" },
	[28569] = { name = "Transmute: Primal Water to Air",   profession = "Alchemy" },
	[28580] = { name = "Transmute: Primal Shadow to Water", profession = "Alchemy" },
	[28582] = { name = "Transmute: Primal Mana to Fire",   profession = "Alchemy" },
	[28583] = { name = "Transmute: Primal Fire to Mana",   profession = "Alchemy" },
	[28584] = { name = "Transmute: Primal Life to Earth",  profession = "Alchemy" },
	-- Meta gem transmutes
	[32765] = { name = "Transmute: Earthstorm Diamond",    profession = "Alchemy" },
	[32766] = { name = "Transmute: Skyfire Diamond",       profession = "Alchemy" },
	-- Master-level transmute (added in 2.1)
	[29688] = { name = "Transmute: Primal Might",          profession = "Alchemy" },
}

-- Profession -> display badge for the tracker, mirroring CATEGORY_BADGE
-- styling. (Single letter; we may want a real icon later.)
Intern.PROFESSION_BADGE = {
	Alchemy       = "|cff60ff60[A]|r",
	Tailoring     = "|cffff80ff[T]|r",
	Leatherworking = "|cffd0a070[L]|r",
	Enchanting    = "|cffaa00ff[E]|r",
	Jewelcrafting = "|cffffaa40[J]|r",
}

-- Compute current state of a profession-CD spell.
--   "ready"     -> off CD; can craft now
--   "completed" -> on CD; remaining seconds in second return value
function Intern.GetCDState(spellID)
	local start, duration = GetSpellCooldown(spellID)
	if not start or not duration or duration == 0 then
		return "ready", 0
	end
	local remaining = (start + duration) - GetTime()
	if remaining <= 0 then return "ready", 0 end
	-- Spell-CD-style transient cooldowns (GCD, etc.) are <= ~2s. Anything
	-- shorter than 60s is not a "daily" CD — treat as ready.
	if duration < 60 then return "ready", 0 end
	return "completed", remaining
end

-- Format a remaining-seconds value as "Hh Mm" / "Mm" for the tracker label.
function Intern.FormatCDRemaining(secs)
	if not secs or secs <= 0 then return "" end
	local h = math.floor(secs / 3600)
	local m = math.floor((secs % 3600) / 60)
	if h > 0 then return string.format("%dh %dm", h, m) end
	return string.format("%dm", m)
end

-- List of CD spellIDs the player actually knows. Used to drive both the
-- browse-window list (opt-in toggles) and the tracker.
function Intern.ListKnownCDs()
	local out = {}
	if not IsSpellKnown then return out end
	for spellID in pairs(Intern.ProfessionCDs) do
		if IsSpellKnown(spellID) then table.insert(out, spellID) end
	end
	table.sort(out, function(a, b)
		return (Intern.ProfessionCDs[a].name or "") < (Intern.ProfessionCDs[b].name or "")
	end)
	return out
end

-- True for Lower City heroic-dungeon Wanted dailies. The heroic pool is given
-- by Wind Trader Zhareem in Shattrath; the normal pool by Nether-Stalker
-- Mah'duun. Used to render an [H] tag so the player can tell at a glance
-- which Wanteds are heroic-only.
function Intern.IsHeroicWanted(qid)
	local info = Intern_Quests and Intern_Quests[qid]
	if not info or not info.title then return false end
	if info.title:sub(1, 7) ~= "Wanted:" then return false end
	return info.npc == "Wind Trader Zhareem"
end

-- Categorize a quest by its primary reward. Precedence:
--   cooking > fishing > wanted > honor > reputation > gold
-- The user explicitly grouped tower-control / ring-tower / Halaa PvP dailies
-- with BG Call to Arms here under "honor" because their headline reward is
-- honor, not rep — even though several also award faction city rep.
function Intern.GetQuestCategory(qid)
	local info = Intern_Quests and Intern_Quests[qid]
	if not info then return "gold" end

	if info.npc == COOKING_NPC then return "cooking" end
	if info.npc == FISHING_NPC then return "fishing" end

	if info.title and info.title:sub(1, 7) == "Wanted:" then return "wanted" end

	if Intern.HonorQuestIds[qid] then return "honor" end
	if info.zone and HONOR_ZONES[info.zone] then return "honor" end
	if info.npc and (info.npc:find("Warbringer") or info.npc:find("Brigadier General")) then
		return "honor"
	end

	if info.reps and next(info.reps) then return "reputation" end
	return "gold"
end

-- If the next-reset timestamp has passed, wipe the per-character "completed
-- today" set and recompute the next reset. The completedToday set exists
-- because C_QuestLog.IsQuestFlaggedCompleted is sticky for daily quests on
-- Classic/Anniversary clients (returns true for ANY daily ever completed,
-- not just today's). We track turn-ins ourselves via QUEST_TURNED_IN.
function Intern.MaybeRollDailyReset()
	if not (Intern_Char and Intern_Char[charKey]) then return end
	local now = time()
	local nr  = Intern_Char[charKey].nextReset or 0
	if now >= nr then
		Intern_Char[charKey].completedToday = {}
		local r = (GetQuestResetTime and GetQuestResetTime()) or 86400
		Intern_Char[charKey].nextReset = now + (r > 0 and r or 86400)
	end
end

-- Decide whether a monthly quest currently counts as "completed this cycle".
-- Auto-syncs the local timestamp record with the WoW client flag and ages it
-- out at 28 days as a safety net (in case the client API is sticky for
-- monthlies the way it is for dailies).
function Intern.IsCompletedThisMonth(qid)
	if not (Intern_Char and Intern_Char[charKey]) then return false end
	local cm = Intern_Char[charKey].completedMonthly
	if not cm then return false end
	local clientFlagged = C_QuestLog.IsQuestFlaggedCompleted(qid)
	if clientFlagged then
		-- Server says completed. If we don't have a local record (e.g. the
		-- player turned it in before installing Intern), start the timer
		-- from now so we can age it out later.
		if not cm[qid] then cm[qid] = time() end
	else
		-- Server says NOT completed → reset just happened (or never done).
		-- Clear our record so the row flips to "available".
		cm[qid] = nil
	end
	-- Age out stale records: 28 days is below any reasonable monthly cycle.
	if cm[qid] and (time() - cm[qid]) >= (28 * 86400) then
		cm[qid] = nil
	end
	return cm[qid] ~= nil
end

-- Determine the current state of a tracked quest from the WoW APIs.
-- Order:
--   * In log → in_progress / ready
--   * frequency=once + flagged completed → completed (e.g. seasonal one-shots)
--   * frequency=daily + we saw it turned in today → completed
--   * frequency=monthly + completed this monthly cycle → completed
--   * frequency=repeatable → never "completed" (you can do it again same day)
--   * fallback → available
function Intern.GetQuestState(qid)
	if C_QuestLog.IsOnQuest(qid) then
		-- Walk the log to find this quest's isComplete flag.
		-- GetQuestLogTitle's isComplete is 1 (complete), -1 (failed), or nil.
		for i = 1, GetNumQuestLogEntries() do
			local _, _, _, _, _, isComplete, _, id = GetQuestLogTitle(i)
			if id == qid then
				if isComplete == 1 then return "ready" end
				return "in_progress"
			end
		end
		return "in_progress"
	end

	local info = Intern_Quests and Intern_Quests[qid]
	if info and info.frequency == "once" and C_QuestLog.IsQuestFlaggedCompleted(qid) then
		return "completed"
	end

	local doneToday = Intern_Char[charKey] and Intern_Char[charKey].completedToday or {}
	if info and info.frequency == "daily" and doneToday[qid] then
		return "completed"
	end

	if info and info.frequency == "monthly" and Intern.IsCompletedThisMonth(qid) then
		return "completed"
	end

	return "available"
end

-- Per-quest rep cap overrides. Default cap for any (quest, faction) pair is
-- Exalted (8). Some quests have lower effective caps — Sha'tar rep on
-- Aldor/Scryer turn-ins is the canonical case: it's spillover that stops
-- accruing at Revered (7) regardless of how much you turn in.
-- Keyed REP_CAPS[qid][factionId] = standingId (1=Hated, 8=Exalted).
-- Filter logic treats "standing >= cap" as "no more useful rep available
-- from this source," and GetPrimaryRepFaction skips capped factions when
-- choosing which subheader to bucket the quest under.
Intern.REP_CAPS = {
	-- Aldor turn-ins: Sha'tar (935) is spillover, caps at Revered (7).
	[10421] = { [935] = 7 },  -- Fel Armaments
	[10326] = { [935] = 7 },  -- More Marks of Kil'jaeden
	[10327] = { [935] = 7 },  -- Single Mark of Kil'jaeden
	[10654] = { [935] = 7 },  -- More Marks of Sargeras (Adyen)
	[10655] = { [935] = 7 },  -- Single Mark of Sargeras (Adyen)
	[10827] = { [935] = 7 },  -- More Marks of Sargeras (Saronen)
	[10828] = { [935] = 7 },  -- Single Mark of Sargeras (Saronen)
	-- Scryer turn-ins: same Sha'tar spillover cap.
	[10419] = { [935] = 7 },  -- Arcane Tomes
	[10414] = { [935] = 7 },  -- More Firewing Signets
	[10415] = { [935] = 7 },  -- Single Firewing Signet
	[10658] = { [935] = 7 },  -- More Sunfury Signets (Fyalenn)
	[10659] = { [935] = 7 },  -- Single Sunfury Signet (Fyalenn)
	[10822] = { [935] = 7 },  -- More Sunfury Signets (Vyara)
	[10823] = { [935] = 7 },  -- Single Sunfury Signet (Vyara)
}

-- Standing where the player can no longer earn useful rep from this quest's
-- reward to a given faction. Default is Exalted (8); per-quest overrides
-- in REP_CAPS lower the bar for capped/spillover reps.
function Intern.GetRepCap(qid, factionId)
	return (Intern.REP_CAPS[qid] and Intern.REP_CAPS[qid][factionId]) or 8
end

-- True if the player has hit (or exceeded) the cap for this quest's reward
-- to this specific faction. Unknown standing → not capped (player hasn't
-- discovered the faction yet, may still gain rep).
function Intern.IsRepCapped(qid, factionId)
	local _, _, standing = GetFactionInfoByID(factionId)
	if not standing then return false end
	return standing >= Intern.GetRepCap(qid, factionId)
end

-- Returns true if every reputation this quest rewards is at-or-above its
-- cap on the current character. Quests with no rep rewards return false.
function Intern.IsAllRepsCapped(qid)
	local info = Intern_Quests and Intern_Quests[qid]
	if not info or not info.reps or next(info.reps) == nil then return false end
	for fid in pairs(info.reps) do
		if not Intern.IsRepCapped(qid, fid) then return false end
	end
	return true
end

-- ============================================================================
-- Frame layout persistence (position + size across reloads)
-- ============================================================================

function Intern.SaveFrameLayout(targetTable, frame)
	if not (targetTable and frame and frame:GetPoint()) then return end
	local point, _, relPoint, x, y = frame:GetPoint()
	targetTable.point    = point
	targetTable.relPoint = relPoint
	targetTable.x        = x and math.floor(x + 0.5) or 0
	targetTable.y        = y and math.floor(y + 0.5) or 0
	targetTable.width    = math.floor(frame:GetWidth()  + 0.5)
	-- Height is the user's preferred uncollapsed height — don't overwrite it
	-- with the title-only height while the tracker is collapsed.
	if not targetTable.collapsed then
		targetTable.height = math.floor(frame:GetHeight() + 0.5)
	end
end

function Intern.ApplyFrameLayout(targetTable, frame)
	if not (targetTable and frame) then return end
	if targetTable.width  and targetTable.width  > 50 then frame:SetWidth(targetTable.width)   end
	if targetTable.height and targetTable.height > 50 then frame:SetHeight(targetTable.height) end
	if targetTable.point and targetTable.x and targetTable.y then
		frame:ClearAllPoints()
		frame:SetPoint(targetTable.point, UIParent, targetTable.relPoint or targetTable.point, targetTable.x, targetTable.y)
	end
end

-- Hooks drag-stop / size-changed / hide on an AceGUI Frame's underlying frame
-- so any user move/resize/close immediately updates targetTable.
function Intern.WireFrameLayoutHooks(targetTable, aceguiFrame)
	local f = aceguiFrame and aceguiFrame.frame
	if not f then return end
	f:HookScript("OnDragStop",    function(self) Intern.SaveFrameLayout(targetTable, self) end)
	f:HookScript("OnSizeChanged", function(self) Intern.SaveFrameLayout(targetTable, self) end)
	f:HookScript("OnHide",        function(self) Intern.SaveFrameLayout(targetTable, self) end)
end

-- Returns true if this quest is part of a one-per-day rotation group AND a
-- different sibling has been picked as today's daily (in log or completed).
-- Returns false when the pick is *this* quest, or when no pick is known yet.
function Intern.IsHiddenByGroupPick(qid)
	local info = Intern_Quests and Intern_Quests[qid]
	if not info or not info.siblings then return false end

	-- Build the full group: this quest + its siblings.
	local group = { qid }
	for _, sib in ipairs(info.siblings) do table.insert(group, sib) end

	-- "Pick" priority: in the player's log first, otherwise completed-today
	-- (per our own tracking — see GetQuestState comment about Classic stickiness).
	for _, gqid in ipairs(group) do
		if C_QuestLog.IsOnQuest(gqid) then return gqid ~= qid end
	end
	local doneToday = Intern_Char[charKey] and Intern_Char[charKey].completedToday or {}
	for _, gqid in ipairs(group) do
		if doneToday[gqid] then return gqid ~= qid end
	end
	return false
end

-- Faction / Aldor-Scryer / profession / Exalted-rep / phase filter. Used by
-- both the main browse window and the tracker. The rotation-pick filter is
-- applied only in the tracker (see PassesTrackerFilters below).
function Intern.QuestPassesFilters(qid)
	local info = Intern_Quests and Intern_Quests[qid]
	if not info then return false end

	-- Phase filter: anything tagged for a phase later than the realm's current
	-- phase shouldn't show, regardless of whether the user has it tracked.
	-- This overrides per-quest tracking — content not yet live on the realm.
	if info.phase and info.expac and Intern_CurrentPhase then
		local current = Intern_CurrentPhase[info.expac]
		if current and info.phase > current then return false end
	end

	if info.faction and info.faction ~= playerFaction then return false end

	if info.reps then
		if info.reps[FACTION_ALDOR]  and isScryer then return false end
		if info.reps[FACTION_SCRYER] and isAldor  then return false end
	end

	if Intern_Settings and Intern_Settings.showOnlyForKnownProfessions then
		local profId = info.npc and TRADESKILL_BY_NPC[info.npc]
		if profId and not (Intern_Char[charKey].professions and Intern_Char[charKey].professions[profId]) then
			return false
		end
	end

	return true
end

-- Adds tracker-only filtering on top of QuestPassesFilters:
--   * rotation hide-non-picks rule
--   * seasonal-event toggle (only show when the user has the event enabled)
--   * hide-repeatables setting
--   * trackRepAtExalted: rep grinds where every rewarded faction is Exalted
--     are wasted on the player (no rep, just a dust/item drop), so hide them
--     from the active tracker. The browse window still shows them so the
--     player can configure tracking for alts or future characters.
-- The browse window deliberately uses just QuestPassesFilters.
function Intern.PassesTrackerFilters(qid)
	if not Intern.QuestPassesFilters(qid) then return false end
	if Intern.IsHiddenByGroupPick(qid) then return false end

	local info = Intern_Quests and Intern_Quests[qid]
	if info and info.seasonal then
		if not (Intern_Settings and Intern_Settings.events and Intern_Settings.events[info.seasonal]) then
			return false
		end
	end
	if info and info.frequency == "repeatable" and Intern_Settings and Intern_Settings.hideRepeatables then
		return false
	end
	-- The "hide rep dailies at cap" filter only applies to quests whose
	-- primary reward is reputation. Hide only when EVERY rewarded faction
	-- is at-or-above its per-quest cap (default Exalted; lower for capped
	-- spillover reps via REP_CAPS). If any rewarded rep is still grindable,
	-- the quest is worth showing under that faction's subheader.
	if Intern_Settings and not Intern_Settings.trackRepAtCap
	   and Intern.GetQuestCategory(qid) == "reputation"
	   and Intern.IsAllRepsCapped(qid) then
		return false
	end

	return true
end

-- The top-level section a quest belongs to in the rendered list. Seasonal
-- events take precedence over the daily/repeatable split because the player's
-- mental model groups them by holiday rather than by frequency. Returns
-- something like "Children's Week", "Dailies", or "Repeatables".
function Intern.GetSectionName(qid)
	local info = Intern_Quests and Intern_Quests[qid]
	if not info then return "Dailies" end
	if info.seasonal then return info.seasonal end
	if info.frequency == "repeatable" then return "Repeatables" end
	return "Dailies"
end

-- Sort key for sections: Dailies first, Repeatables second, then seasonal
-- events alphabetically.
function Intern.GetSectionSortKey(name)
	if name == "Dailies"     then return "1" end
	if name == "Repeatables" then return "2" end
	return "3:" .. name
end

-- Walk Intern_Quests, return a list of quest IDs that should be in the default
-- tracked set on a fresh install for the current expansion + phase. Skips
-- quests tagged for the opposite faction. (The player's faction may not be
-- known yet at OnInitialize time, in which case we don't faction-filter and
-- rely on the runtime filter / cleanup pass.)
local function defaultTrackedSet()
	local out = {}
	local currentPhase = Intern_CurrentPhase[2] or 1
	local f = UnitFactionGroup("player")
	for qid, info in pairs(Intern_Quests) do
		if info.expac == 2 and info.phase == currentPhase then
			if not info.faction or not f or info.faction == f then
				out[qid] = true
			end
		end
	end
	return out
end

-- One-time cleanup on enable: drop any tracked IDs that target the opposite
-- faction or that no longer exist in our quest data (e.g., we tightened the
-- filter and the entry was pruned). Keeps the saved-variables table tidy.
--
-- Bails out if Intern_Quests looks unhealthy (nil or empty). A failed data
-- load would make every tracked qid look "stale" and wipe the player's whole
-- selection — happened once when a re-extract produced a malformed file.
local function pruneTrackedSet()
	if not (Intern_Char and Intern_Char[charKey] and Intern_Char[charKey].tracked) then return end
	if not Intern_Quests or next(Intern_Quests) == nil then
		print("|cffff00ff[Intern]|r Quest data missing — skipping prune to protect tracked set.")
		return
	end
	local removed = 0
	for qid in pairs(Intern_Char[charKey].tracked) do
		local info = Intern_Quests[qid]
		if not info then
			Intern_Char[charKey].tracked[qid] = nil
			removed = removed + 1
		elseif info.faction and info.faction ~= playerFaction then
			Intern_Char[charKey].tracked[qid] = nil
			removed = removed + 1
		end
	end
	if removed > 0 then
		print(string.format("|cffff00ff[Intern]|r Pruned %d wrong-faction or stale tracked quests.", removed))
	end
end

-- Refresh the player's professions from the skill list. Used by the profession filter.
local function refreshProfessions()
	Intern_Char[charKey].professions = {}
	for i = 1, GetNumSkillLines() do
		local name = GetSkillLineInfo(i)
		local id = name and profIdByName[name]
		if id then
			Intern_Char[charKey].professions[id] = true
		end
	end
end

-- Detect Aldor (932) vs Scryer (934). Whichever standing is higher wins; if equal
-- (e.g., the player hasn't chosen yet) neither is set so both sides show.
local function detectAldorScryer()
	local _, _, aldor  = GetFactionInfoByID(FACTION_ALDOR)
	local _, _, scryer = GetFactionInfoByID(FACTION_SCRYER)
	isAldor  = (aldor  or 0) > (scryer or 0)
	isScryer = (scryer or 0) > (aldor  or 0)
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

function Intern:OnInitialize()
	Intern_Settings = Intern_Settings or {}
	if Intern_Settings.autoAccept              == nil then Intern_Settings.autoAccept              = true  end
	if Intern_Settings.autoTurnIn              == nil then Intern_Settings.autoTurnIn              = true  end
	if Intern_Settings.showCompletedInTracker  == nil then Intern_Settings.showCompletedInTracker  = true  end
	if Intern_Settings.showOnlyForKnownProfessions == nil then Intern_Settings.showOnlyForKnownProfessions = true end
	-- One-time rename: trackRepAtExalted → trackRepAtCap (broader semantic;
	-- "cap" covers Exalted plus per-quest spillover/lower caps).
	if Intern_Settings.trackRepAtExalted ~= nil and Intern_Settings.trackRepAtCap == nil then
		Intern_Settings.trackRepAtCap     = Intern_Settings.trackRepAtExalted
		Intern_Settings.trackRepAtExalted = nil
	end
	if Intern_Settings.trackRepAtCap               == nil then Intern_Settings.trackRepAtCap               = true end
	if Intern_Settings.hideRepeatables             == nil then Intern_Settings.hideRepeatables             = false end
	if Intern_Settings.transparentTracker          == nil then Intern_Settings.transparentTracker          = true end
	-- Seasonal-event toggles. Default off; user opts in when an event is live.
	-- Takes precedence over per-quest tracking — a tracked seasonal quest
	-- still hides if its event toggle is off.
	-- Combines a hardcoded list (so even events with no data on this client
	-- still show as toggleable in Settings) with anything we discover in the
	-- bundled data.
	Intern_Settings.events = Intern_Settings.events or {}
	for _, ev in ipairs({
		"Brewfest", "Children's Week", "Hallow's End", "Love is in the Air",
		"Lunar Festival", "Midsummer", "Pilgrim's Bounty",
	}) do
		if Intern_Settings.events[ev] == nil then Intern_Settings.events[ev] = false end
	end
	if Intern_Quests then
		for _, info in pairs(Intern_Quests) do
			if info.seasonal and Intern_Settings.events[info.seasonal] == nil then
				Intern_Settings.events[info.seasonal] = false
			end
		end
	end
	if Intern_Settings.minimap                 == nil then Intern_Settings.minimap                 = {}    end

	Intern_Char = Intern_Char or {}
	Intern_Char[charKey] = Intern_Char[charKey] or {}
	if Intern_Char[charKey].tracked == nil then
		Intern_Char[charKey].tracked = defaultTrackedSet()
	end
	Intern_Char[charKey].tracker          = Intern_Char[charKey].tracker          or { width = 280, height = 400, locked = false }
	-- Per-section / per-category collapse state for the tracker. Persisted
	-- so collapsed sections stay collapsed across reloads.
	Intern_Char[charKey].tracker.sectionCollapsed  = Intern_Char[charKey].tracker.sectionCollapsed  or {}
	Intern_Char[charKey].tracker.categoryCollapsed = Intern_Char[charKey].tracker.categoryCollapsed or {}
	Intern_Char[charKey].professions      = Intern_Char[charKey].professions      or {}
	Intern_Char[charKey].seenLog          = Intern_Char[charKey].seenLog          or {}
	Intern_Char[charKey].trackedCDs       = Intern_Char[charKey].trackedCDs       or {}
	Intern_Char[charKey].completedToday   = Intern_Char[charKey].completedToday   or {}
	Intern_Char[charKey].nextReset        = Intern_Char[charKey].nextReset        or 0
	-- completedMonthly: { [qid] = unix-timestamp-of-turn-in } for monthly
	-- quests. Cleared at the 28-day mark or when the WoW client API reports
	-- the flag false (server reset). 28 days is a safe lower bound — even
	-- if the server resets monthly, we'll only over-show "completed" by a
	-- couple of days and the API check usually catches it sooner.
	Intern_Char[charKey].completedMonthly = Intern_Char[charKey].completedMonthly or {}

	-- Build the inverse profession-name lookup for the player's locale.
	for id, name in pairs(PROF_NAMES_ENUS) do profIdByName[name] = id end

	if Intern.SetupOptions then Intern.SetupOptions() end
end

function Intern:OnEnable()
	playerFaction = UnitFactionGroup("player") or ""

	-- Drop tracked entries that target the opposite faction or that no longer
	-- exist in the current data file.
	pruneTrackedSet()

	-- Tracker refresh events (state changes).
	self:RegisterEvent("QUEST_ACCEPTED",         function() Intern.RequestUpdate() end)
	self:RegisterEvent("QUEST_TURNED_IN", function(_, qid)
		-- Record turn-in timestamp by frequency bucket. AceEvent anonymous
		-- callbacks receive (eventName, ...args), so qid is the SECOND arg
		-- positionally. Earlier this was function(_, _, qid) which captured
		-- xpReward — at level 70 xpReward is 0, which silently populated
		-- completedToday[0]=true and missed every real turn-in.
		-- We track turn-ins ourselves because IsQuestFlaggedCompleted is
		-- sticky across daily resets in Classic.
		if qid and qid > 0 and Intern_Char and Intern_Char[charKey] then
			local info = Intern_Quests and Intern_Quests[qid]
			if info and info.frequency == "monthly" then
				Intern_Char[charKey].completedMonthly = Intern_Char[charKey].completedMonthly or {}
				Intern_Char[charKey].completedMonthly[qid] = time()
			else
				Intern_Char[charKey].completedToday = Intern_Char[charKey].completedToday or {}
				Intern_Char[charKey].completedToday[qid] = true
			end
		end
		Intern.RequestUpdate()
	end)
	self:RegisterEvent("QUEST_REMOVED",          function() Intern.RequestUpdate() end)
	self:RegisterEvent("UNIT_QUEST_LOG_CHANGED", function() Intern.RequestUpdate() end)
	self:RegisterEvent("QUEST_LOG_UPDATE",       function() Intern.RequestUpdate() end)
	self:RegisterEvent("SPELL_UPDATE_COOLDOWN",  function() Intern.RequestUpdate() end)
	self:RegisterEvent("PLAYER_ENTERING_WORLD",  function()
		C_Timer.After(2, function()
			detectAldorScryer()
			refreshProfessions()
			Intern.MaybeRollDailyReset()
			Intern.RequestUpdate()
			-- Re-open the main browse window on /reload if the user had it open before.
			-- Same persistence pattern the tracker uses (Intern_Char[charKey].tracker.shown).
			if Intern_Char[charKey].main and Intern_Char[charKey].main.shown then
				Intern.ShowMainWindow()
			end
		end)
	end)

	-- Auto-accept / auto-turn-in events.
	self:RegisterEvent("QUEST_DETAIL",   "OnQuestDetail")
	self:RegisterEvent("QUEST_PROGRESS", "OnQuestProgress")
	self:RegisterEvent("QUEST_COMPLETE", "OnQuestComplete")
	self:RegisterEvent("GOSSIP_SHOW",    "OnGossipShow")

	-- Broker / minimap icon.
	local broker = LDB:NewDataObject("Intern", {
		type = "data source",
		text = "Intern",
		icon = "Interface\\AddOns\\Intern\\Images\\intern.tga",
		OnClick = function(_, button)
			if button == "LeftButton" then
				if Intern.ToggleTracker then Intern.ToggleTracker() end
			elseif button == "MiddleButton" then
				Intern.ToggleMainWindow()
			elseif button == "RightButton" then
				if Intern.OpenOptions then Intern.OpenOptions() end
			end
		end,
		OnTooltipShow = function(tooltip)
			tooltip:AddLine("|cFFffffffIntern|r")
			tooltip:AddLine("|cffffd100Left Click|r toggle tracker",   0.2, 1, 0.2)
			tooltip:AddLine("|cffffd100Middle Click|r open main window", 0.2, 1, 0.2)
			tooltip:AddLine("|cffffd100Right Click|r open settings",   0.2, 1, 0.2)
		end,
	})
	if LibDBIcon then LibDBIcon:Register("Intern", broker, Intern_Settings.minimap) end

	-- Slash commands.
	self:RegisterChatCommand("intern", function(input)
		input = (input or ""):lower():match("^%s*(.-)%s*$")
		if input == "tracker" then
			if Intern.ToggleTracker then Intern.ToggleTracker() end
		elseif input == "options" or input == "config" then
			if Intern.OpenOptions then Intern.OpenOptions() end
		elseif input == "reseed" then
			-- Re-apply Phase-1 defaults, merging with anything already tracked.
			-- Use case: tracked set got wiped (e.g. by a data-file failure) and
			-- the player wants the default selection back without 60+ clicks.
			local defaults = defaultTrackedSet()
			local added = 0
			for qid in pairs(defaults) do
				if not Intern_Char[charKey].tracked[qid] then
					Intern_Char[charKey].tracked[qid] = true
					added = added + 1
				end
			end
			print(string.format("|cffff00ff[Intern]|r Reseeded defaults: added %d tracked quests.", added))
			if Intern.RefreshTracker     then Intern.RefreshTracker()    end
			if Intern.ShowBrowseContent  then Intern.ShowBrowseContent() end
		elseif input:sub(1, 4) == "done" then
			-- Retroactively mark quest(s) as completed, matching by substring
			-- on the title. Daily/repeatable → completedToday (cleared at next
			-- realm reset); monthly → completedMonthly (cleared after ~28d or
			-- when the WoW client flag goes false). Useful when you turned a
			-- quest in before Intern was tracking events.
			local query = input:sub(6):lower()
			if query == "" then
				print("|cffff00ff[Intern]|r Usage: /intern done <partial title>")
			else
				local matched = {}
				for qid, info in pairs(Intern_Quests or {}) do
					if info.title and info.title:lower():find(query, 1, true) then
						if info.frequency == "monthly" then
							Intern_Char[charKey].completedMonthly[qid] = time()
							table.insert(matched, info.title .. " (monthly)")
						elseif info.frequency == "daily" then
							Intern_Char[charKey].completedToday[qid] = true
							table.insert(matched, info.title)
						end
					end
				end
				if #matched == 0 then
					print("|cffff00ff[Intern]|r No daily/monthly titles matched '" .. query .. "'.")
				else
					print(string.format("|cffff00ff[Intern]|r Marked %d quest(s) done: %s",
						#matched, table.concat(matched, ", ")))
				end
				Intern.RequestUpdate()
			end
		else
			Intern.ShowMainWindow()
		end
	end)

	print("|cffff00ff[Intern]|r v" .. (C_AddOns.GetAddOnMetadata(addonName, "Version") or "?") .. " loaded. /intern to open.")
end

-- ============================================================================
-- Auto-accept / auto-turn-in
-- ============================================================================

function Intern:OnQuestDetail()
	if not Intern_Settings.autoAccept then return end
	local id = GetQuestID()
	if id and Intern_Char[charKey].tracked[id] then
		AcceptQuest()
	end
end

function Intern:OnQuestProgress()
	if not Intern_Settings.autoTurnIn then return end
	local id = GetQuestID()
	if id and Intern_Char[charKey].tracked[id] and IsQuestCompletable() then
		CompleteQuest()
	end
end

function Intern:OnQuestComplete()
	if not Intern_Settings.autoTurnIn then return end
	local id = GetQuestID()
	if id and Intern_Char[charKey].tracked[id] and GetNumQuestChoices() == 0 then
		GetQuestReward(0)
	end
end

function Intern:OnGossipShow()
	if not Intern_Settings.autoAccept and not Intern_Settings.autoTurnIn then return end

	if Intern_Settings.autoAccept then
		local available = (C_GossipInfo and C_GossipInfo.GetAvailableQuests and C_GossipInfo.GetAvailableQuests()) or {}
		for _, q in ipairs(available) do
			if Intern_Char[charKey].tracked[q.questID] then
				C_GossipInfo.SelectAvailableQuest(q.questID)
				return  -- one click per gossip event
			end
		end
	end

	if Intern_Settings.autoTurnIn then
		local active = (C_GossipInfo and C_GossipInfo.GetActiveQuests and C_GossipInfo.GetActiveQuests()) or {}
		for _, q in ipairs(active) do
			if Intern_Char[charKey].tracked[q.questID] and q.isComplete then
				C_GossipInfo.SelectActiveQuest(q.questID)
				return
			end
		end
	end
end

-- ============================================================================
-- Throttled refresh entry point (called by InternTracker and the main window)
-- ============================================================================

local _updatePending = false
function Intern.RequestUpdate()
	if _updatePending then return end
	_updatePending = true
	C_Timer.After(0.2, function()
		_updatePending = false
		Intern.MaybeRollDailyReset()
		-- Tracker reflects live quest state; the main browse window is just a
		-- track-config UI and doesn't depend on quest state, so we don't refresh
		-- it on QUEST_* events. It refreshes on its own toggles + filter changes.
		if Intern.RefreshTracker then Intern.RefreshTracker() end
	end)
end

-- ============================================================================
-- Main browse window
-- ============================================================================

local browseScroll = nil

function Intern.ShowMainWindow()
	if mainFrame and mainFrame.frame:IsShown() then return end

	if not mainFrame then
		mainFrame = AceGUI:Create("Frame")
		mainFrame:SetTitle("Intern")
		mainFrame:SetStatusText("Toggle quests to track them. The tracker window shows their state.")
		mainFrame:SetWidth(640)
		mainFrame:SetHeight(540)
		mainFrame:SetLayout("Flow")
		mainFrame:SetCallback("OnClose", function()
			Intern_Char[charKey].main.shown = false
		end)

		_G["InternMainFrame"] = mainFrame.frame
		tinsert(UISpecialFrames, "InternMainFrame")

		browseScroll = AceGUI:Create("ScrollFrame")
		browseScroll:SetLayout("Flow")
		browseScroll:SetFullWidth(true)
		browseScroll:SetFullHeight(true)
		mainFrame:AddChild(browseScroll)

		-- Layout persistence: per-character. Apply saved point/size on first
		-- build, then capture changes via drag-stop / size-changed / hide.
		Intern_Char[charKey].main = Intern_Char[charKey].main or {}
		Intern.ApplyFrameLayout(Intern_Char[charKey].main, mainFrame.frame)
		Intern.WireFrameLayoutHooks(Intern_Char[charKey].main, mainFrame)
	end

	Intern_Char[charKey].main.shown = true
	mainFrame.frame:Show()
	Intern.ShowBrowseContent()
end

function Intern.HideMainWindow()
	if mainFrame and mainFrame.frame:IsShown() then
		Intern_Char[charKey].main.shown = false
		mainFrame.frame:Hide()
	end
end

function Intern.ToggleMainWindow()
	if mainFrame and mainFrame.frame:IsShown() then
		Intern.HideMainWindow()
	else
		Intern.ShowMainWindow()
	end
end

-- Render the Cooldowns section into the browse scroll: one collapsible header
-- with a tri-state master checkbox (toggle all known CDs at once) plus one
-- toggleable checkbox per known profession-CD spell. Opt-in flag persists in
-- Intern_Char[charKey].trackedCDs[spellID].
local function renderBrowseCDs(scroll, isFirst)
	local known = Intern.ListKnownCDs()
	if #known == 0 then return false end

	local sectionKey = "section::Cooldowns"
	local collapsed  = browseCollapsed[sectionKey]
	local indicator  = collapsed and "|cffffd100[+]|r" or "|cffffd100[-]|r"

	-- Master state across all known CDs.
	local total, tracked = #known, 0
	for _, spellID in ipairs(known) do
		if Intern_Char[charKey].trackedCDs[spellID] then tracked = tracked + 1 end
	end
	local masterState
	if tracked == 0 then masterState = false
	elseif tracked == total then masterState = true
	else masterState = nil end

	local headerWrap = AceGUI:Create("SimpleGroup")
	headerWrap:SetFullWidth(true)
	headerWrap:SetLayout("Flow")

	local masterCB = AceGUI:Create("CheckBox")
	masterCB:SetType("checkbox")
	masterCB:SetTriState(true)
	masterCB:SetWidth(28)
	masterCB:SetLabel("")
	masterCB:SetValue(masterState)
	masterCB:SetCallback("OnValueChanged", function()
		local turnOn = (masterState ~= true)
		for _, spellID in ipairs(known) do
			Intern_Char[charKey].trackedCDs[spellID] = turnOn and true or nil
		end
		Intern.ShowBrowseContent()
		if Intern.RefreshTracker then Intern.RefreshTracker() end
	end)
	headerWrap:AddChild(masterCB)

	local header = AceGUI:Create("InteractiveLabel")
	header:SetRelativeWidth(0.92)
	header:SetText((isFirst and "" or "\n") .. indicator .. " |cffffd100Cooldowns|r")
	header:SetFont(GameFontNormal:GetFont(), 14)
	header:SetCallback("OnClick", function()
		browseCollapsed[sectionKey] = not collapsed
		Intern.ShowBrowseContent()
	end)
	headerWrap:AddChild(header)

	scroll:AddChild(headerWrap)

	if collapsed then return true end

	for _, spellID in ipairs(known) do
		local meta = Intern.ProfessionCDs[spellID]
		local rowWrap = AceGUI:Create("SimpleGroup")
		rowWrap:SetFullWidth(true)
		rowWrap:SetLayout("Flow")

		local spacer = AceGUI:Create("Label")
		spacer:SetText(" ")
		spacer:SetWidth(36)
		rowWrap:AddChild(spacer)

		local cb = AceGUI:Create("CheckBox")
		cb:SetType("checkbox")
		cb:SetRelativeWidth(0.9)
		cb:SetValue(Intern_Char[charKey].trackedCDs[spellID] and true or false)
		cb:SetLabel(meta.name .. "  |cff808080-  " .. meta.profession .. "|r")
		cb:SetCallback("OnValueChanged", function(_, _, val)
			Intern_Char[charKey].trackedCDs[spellID] = val and true or nil
			if Intern.RefreshTracker then Intern.RefreshTracker() end
		end)
		rowWrap:AddChild(cb)

		scroll:AddChild(rowWrap)
	end
	return true
end

function Intern.ShowBrowseContent()
	if not browseScroll then return end

	-- Preserve scroll position across rebuilds. ReleaseChildren() destroys all
	-- AceGUI widgets and re-laying out from scratch resets the scroll bar to 0,
	-- which is jarring when the user just clicked an expand/collapse arrow.
	local savedScroll = browseScroll.localstatus and browseScroll.localstatus.scrollvalue or 0

	browseScroll:ReleaseChildren()

	-- Bucket by section (Dailies / Repeatables / event name) then by category
	-- (cooking / fishing / wanted / honor / reputation / gold). Browse uses
	-- QuestPassesFilters (faction, Aldor/Scryer, profession, exalted) but NOT
	-- the tracker-only seasonal/repeatable hide-toggles, so the user can see
	-- and pre-track event quests year-round.
	local bySection = {}
	local total = 0
	for qid in pairs(Intern_Quests) do
		if Intern.QuestPassesFilters(qid) then
			local section  = Intern.GetSectionName(qid)
			local category = Intern.GetQuestCategory(qid)
			bySection[section] = bySection[section] or {}
			bySection[section][category] = bySection[section][category] or {}
			table.insert(bySection[section][category], qid)
			total = total + 1
		end
	end

	if total == 0 then
		-- Even with zero quests, the player may still have profession CDs to
		-- toggle on this character — render those before giving up.
		local cdsRendered = renderBrowseCDs(browseScroll, true)
		if not cdsRendered then
			local empty = AceGUI:Create("Label")
			empty:SetText("\n No quests match the current filters.")
			empty:SetFullWidth(true)
			empty:SetFont(GameFontNormal:GetFont(), 12)
			browseScroll:AddChild(empty)
		end
		return
	end

	-- Within each (section, category), dedupe by title. Multiple quest IDs may
	-- share a title (e.g. "Striking Back" has 6 IDs, "Marks of Sargeras" has 2
	-- NPCs). Keep one display row per title; the row's checkbox toggles tracking
	-- for *all* same-title sibling IDs so the player effectively tracks the
	-- whole group with one click.
	local titleSiblings = {}
	for sectionName, categoryMap in pairs(bySection) do
		titleSiblings[sectionName] = titleSiblings[sectionName] or {}
		for category, qids in pairs(categoryMap) do
			local sibs = {}
			for _, qid in ipairs(qids) do
				local title = Intern_Quests[qid].title
				sibs[title] = sibs[title] or {}
				table.insert(sibs[title], qid)
			end
			titleSiblings[sectionName][category] = sibs
			-- Replace the qids list with one representative per title.
			local deduped = {}
			for _, group in pairs(sibs) do
				table.insert(deduped, group[1])
			end
			categoryMap[category] = deduped
		end
	end

	-- Section order: Dailies, Repeatables, then seasonal events alphabetically.
	local sections = {}
	for name in pairs(bySection) do table.insert(sections, name) end
	table.sort(sections, function(a, b)
		return Intern.GetSectionSortKey(a) < Intern.GetSectionSortKey(b)
	end)

	-- Aggregate-state helper: count tracked + total qids underneath a master-row
	-- collection. Used to drive the section/category checkbox tri-state.
	-- `siblingMap` is { [title] = { qid, qid, ... } }.
	local function countTrackedFromSiblings(siblingMap)
		local total, tracked = 0, 0
		for _, sibs in pairs(siblingMap) do
			for _, qid in ipairs(sibs) do
				total = total + 1
				if Intern_Char[charKey].tracked[qid] then tracked = tracked + 1 end
			end
		end
		return tracked, total
	end

	-- Apply a track-all / untrack-all to every qid in a sibling map.
	local function setTrackedFromSiblings(siblingMap, val)
		for _, sibs in pairs(siblingMap) do
			for _, qid in ipairs(sibs) do
				Intern_Char[charKey].tracked[qid] = val and true or nil
			end
		end
	end

	-- Build a header row with a tri-state master checkbox + collapsible label.
	-- Returns nothing; appends to browseScroll directly.
	-- `siblingMaps` is a list of per-category sibling maps (so the section
	-- header can aggregate across categories with one helper).
	local function emitHeaderRow(opts)
		local total, tracked = 0, 0
		for _, sm in ipairs(opts.siblingMaps) do
			local t, tt = countTrackedFromSiblings(sm)
			tracked, total = tracked + t, total + tt
		end
		local state
		if tracked == 0 then state = false
		elseif tracked == total then state = true
		else state = nil end

		local row = AceGUI:Create("SimpleGroup")
		row:SetFullWidth(true)
		row:SetLayout("Flow")

		if opts.indent and opts.indent > 0 then
			local sp = AceGUI:Create("Label")
			sp:SetText(" ")
			sp:SetWidth(opts.indent)
			row:AddChild(sp)
		end

		local cb = AceGUI:Create("CheckBox")
		cb:SetType("checkbox")
		cb:SetTriState(true)
		cb:SetWidth(28)
		cb:SetLabel("")
		cb:SetValue(state)
		cb:SetCallback("OnValueChanged", function()
			-- Override AceGUI's tri-state cycling: a click decides "select all"
			-- or "clear all" based on the pre-click state. Mixed/none → all on,
			-- all-on → all off.
			local turnOn = (state ~= true)
			for _, sm in ipairs(opts.siblingMaps) do
				setTrackedFromSiblings(sm, turnOn)
			end
			Intern.ShowBrowseContent()
			if Intern.RefreshTracker then Intern.RefreshTracker() end
		end)
		row:AddChild(cb)

		local label = AceGUI:Create("InteractiveLabel")
		label:SetRelativeWidth(0.92)
		label:SetText(opts.text)
		label:SetFont(GameFontNormal:GetFont(), opts.fontSize or 14)
		label:SetCallback("OnClick", opts.onClick)
		row:AddChild(label)

		browseScroll:AddChild(row)
	end

	local first = true
	for _, sectionName in ipairs(sections) do
		local categoryMap = bySection[sectionName]
		local sectionKey = "section::" .. sectionName
		local sectionCollapsed = browseCollapsed[sectionKey]
		-- Seasonal sections render flat (no category subheaders) — most event
		-- quests are single-shot ones with no meaningful category, and grouping
		-- a small set under category buckets is more noise than signal.
		local isFlat = (sectionName ~= "Dailies" and sectionName ~= "Repeatables")

		-- Section header — gather sibling maps across all categories.
		local sectionSiblingMaps = {}
		for cat, _ in pairs(categoryMap) do
			table.insert(sectionSiblingMaps, titleSiblings[sectionName][cat])
		end
		local sIndicator = sectionCollapsed and "|cffffd100[+]|r" or "|cffffd100[-]|r"
		emitHeaderRow({
			indent       = 0,
			fontSize     = 14,
			text         = (first and "" or "\n") .. sIndicator .. " |cffffd100" .. sectionName .. "|r",
			siblingMaps  = sectionSiblingMaps,
			onClick      = function()
				browseCollapsed[sectionKey] = not sectionCollapsed
				Intern.ShowBrowseContent()
			end,
		})
		first = false

		if not sectionCollapsed then
			-- Sort category keys by Intern.CATEGORY_ORDER (alphabetical equivalent).
			local categories = {}
			for cat in pairs(categoryMap) do table.insert(categories, cat) end
			table.sort(categories, function(a, b)
				return (Intern.CATEGORY_ORDER[a] or 99) < (Intern.CATEGORY_ORDER[b] or 99)
			end)

			for _, category in ipairs(categories) do
				local qids = categoryMap[category]
				-- Sort within category: for Dungeons, heroics first; then
				-- alphabetical by title.
				table.sort(qids, function(a, b)
					if category == "wanted" and Intern.IsHeroicWanted then
						local ha = Intern.IsHeroicWanted(a) and 0 or 1
						local hb = Intern.IsHeroicWanted(b) and 0 or 1
						if ha ~= hb then return ha < hb end
					end
					return (Intern_Quests[a].title or "") < (Intern_Quests[b].title or "")
				end)

				-- Category subheader — only for non-flat (Dailies/Repeatables) sections.
				local categoryCollapsed = false
				if not isFlat then
					local categoryLabel = Intern.CATEGORY_LABEL[category] or category
					local categoryKey   = "category::" .. sectionName .. "::" .. category
					categoryCollapsed   = browseCollapsed[categoryKey]
					local cIndicator    = categoryCollapsed and "|cffffd100[+]|r" or "|cffffd100[-]|r"
					emitHeaderRow({
						indent      = 18,
						fontSize    = 12,
						text        = cIndicator .. " |cffffffff" .. categoryLabel .. "|r",
						siblingMaps = { titleSiblings[sectionName][category] },
						onClick     = function()
							browseCollapsed[categoryKey] = not categoryCollapsed
							Intern.ShowBrowseContent()
						end,
					})
				end

				if not categoryCollapsed then
					-- Reputation gets sub-bucketed by primary faction so rows
					-- render under per-faction subheaders. Other categories
					-- use a single bucket with no faction subheader.
					local subBuckets = {}
					if category == "reputation" and not isFlat then
						local byFaction = {}
						for _, qid in ipairs(qids) do
							local fid = (Intern.GetPrimaryRepFaction and Intern.GetPrimaryRepFaction(qid)) or 0
							byFaction[fid] = byFaction[fid] or {}
							table.insert(byFaction[fid], qid)
						end
						local factionIds = {}
						for fid in pairs(byFaction) do table.insert(factionIds, fid) end
						local nameOf = Intern.GetFactionName or function(id) return tostring(id) end
						table.sort(factionIds, function(a, b)
							return (nameOf(a) or "") < (nameOf(b) or "")
						end)
						for _, fid in ipairs(factionIds) do
							table.insert(subBuckets, { factionName = nameOf(fid), qids = byFaction[fid] })
						end
					else
						table.insert(subBuckets, { factionName = nil, qids = qids })
					end

					for _, bucket in ipairs(subBuckets) do
					if bucket.factionName then
						-- Faction subheader: tri-state checkbox toggles every
						-- quest in this faction's bucket.
						local factionSibsByTitle = {}
						for _, masterQid in ipairs(bucket.qids) do
							local title = Intern_Quests[masterQid].title
							factionSibsByTitle[title] = titleSiblings[sectionName][category][title]
						end
						emitHeaderRow({
							indent      = 36,
							fontSize    = 11,
							text        = "|cffaaaaaa" .. bucket.factionName .. "|r",
							siblingMaps = { factionSibsByTitle },
							onClick     = function() end,
						})
					end

					for _, qid in ipairs(bucket.qids) do
						local info = Intern_Quests[qid]
						local title = info.title
						local sibsForTitle = titleSiblings[sectionName][category][title]
						local multi = #sibsForTitle > 1

						-- ===== Master row =====
						local rowWrap = AceGUI:Create("SimpleGroup")
						rowWrap:SetFullWidth(true)
						rowWrap:SetLayout("Flow")

						local spacer = AceGUI:Create("Label")
						spacer:SetText(" ")
						spacer:SetWidth(isFlat and 18 or (bucket.factionName and 54 or 36))
						rowWrap:AddChild(spacer)

						local row = AceGUI:Create("CheckBox")
						row:SetType("checkbox")
						row:SetRelativeWidth(0.9)

						-- "Tracked" state is the OR of all same-title sibling IDs.
						local tracked = false
						for _, sibQid in ipairs(sibsForTitle) do
							if Intern_Char[charKey].tracked[sibQid] then
								tracked = true
								break
							end
						end
						row:SetValue(tracked)

						-- The browse window is a track-configuration UI; it doesn't
						-- show live quest state (that belongs to the tracker).
						local label = title
						-- Only show NPC on master row when there's a single variant
						-- (multi-variant rows might have different NPCs per sibling
						-- so we let the variants show their own).
						if not multi and info.npc and info.npc ~= "" then
							label = label .. "  |cff808080-  " .. info.npc .. "|r"
						end
						row:SetLabel(label)

						row:SetCallback("OnValueChanged", function(_, _, val)
							-- Toggle tracked for *every* same-title sibling so the
							-- player effectively tracks the whole group with one click.
							for _, sibQid in ipairs(sibsForTitle) do
								Intern_Char[charKey].tracked[sibQid] = val and true or nil
							end
							if Intern.RefreshTracker then Intern.RefreshTracker() end
						end)
						rowWrap:AddChild(row)

						browseScroll:AddChild(rowWrap)

						-- ===== Variants expander + per-variant rows =====
						-- Only show the expander when the siblings are actually distinguishable
						-- (different NPC and/or different zone). If all 6 "Striking Back" IDs
						-- share an empty NPC and empty zone, listing them as "id 11948" etc.
						-- adds no value — the master row covers them.
						local distinguishable = false
						if multi then
							local firstNpc  = (Intern_Quests[sibsForTitle[1]].npc  or "")
							local firstZone = (Intern_Quests[sibsForTitle[1]].zone or "")
							for _, sibQid in ipairs(sibsForTitle) do
								local s = Intern_Quests[sibQid]
								if (s.npc or "") ~= firstNpc or (s.zone or "") ~= firstZone then
									distinguishable = true
									break
								end
							end
						end

						if multi and distinguishable then
							local expandKey = "variants::" .. sectionName .. "::" .. category .. "::" .. title
							local expanded = browseCollapsed[expandKey] == false  -- default collapsed

							local link = AceGUI:Create("InteractiveLabel")
							local arrow = expanded and "v" or ">"
							link:SetText(string.format("            |cff60c0ff%s %d variants|r", arrow, #sibsForTitle))
							link:SetFullWidth(true)
							link:SetFont(GameFontNormal:GetFont(), 11)
							link:SetCallback("OnClick", function()
								browseCollapsed[expandKey] = expanded  -- flip
								Intern.ShowBrowseContent()
							end)
							browseScroll:AddChild(link)

							if expanded then
								for _, sibQid in ipairs(sibsForTitle) do
									local sibInfo = Intern_Quests[sibQid]
									local sibWrap = AceGUI:Create("SimpleGroup")
									sibWrap:SetFullWidth(true)
									sibWrap:SetLayout("Flow")

									local sibSpacer = AceGUI:Create("Label")
									sibSpacer:SetText(" ")
									sibSpacer:SetWidth(bucket.factionName and 72 or 54)
									sibWrap:AddChild(sibSpacer)

									local sibRow = AceGUI:Create("CheckBox")
									sibRow:SetType("checkbox")
									sibRow:SetRelativeWidth(0.85)
									sibRow:SetValue(Intern_Char[charKey].tracked[sibQid] and true or false)

									local distinguishers = {}
									if sibInfo.npc and sibInfo.npc ~= "" then
										table.insert(distinguishers, sibInfo.npc)
									end
									if sibInfo.zone and sibInfo.zone ~= "" then
										table.insert(distinguishers, sibInfo.zone)
									end
									local qualifier = #distinguishers > 0
										and ("  |cff808080(" .. table.concat(distinguishers, ", ") .. ")|r")
										or ""
									sibRow:SetLabel(title .. qualifier)

									sibRow:SetCallback("OnValueChanged", function(_, _, val)
										Intern_Char[charKey].tracked[sibQid] = val and true or nil
										Intern.ShowBrowseContent()
										if Intern.RefreshTracker then Intern.RefreshTracker() end
									end)
									sibWrap:AddChild(sibRow)

									browseScroll:AddChild(sibWrap)
								end
							end
						end
					end
					end -- closes for _, bucket in ipairs(subBuckets)
				end
			end
		end
	end

	-- Profession-CD section renders after all quest sections.
	renderBrowseCDs(browseScroll, false)

	-- Restore scroll position after AceGUI's deferred layout pass.
	if savedScroll and savedScroll > 0 and browseScroll.scrollbar then
		C_Timer.After(0, function()
			if browseScroll and browseScroll.scrollbar then
				browseScroll.scrollbar:SetValue(savedScroll)
			end
		end)
	end
end
