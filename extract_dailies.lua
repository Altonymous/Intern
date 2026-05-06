-- Extract TBC dailies/repeatables from Questie's data files into Intern_Quests.
-- Usage: lua5.4 extract_dailies.lua > InternData.lua

local QUESTIE = "/home/saiba/Games/battlenet/drive_c/Program Files (x86)/World of Warcraft/_anniversary_/Interface/AddOns/Questie"

local function read_file(path)
	local f = assert(io.open(path, "r"))
	local s = f:read("*all")
	f:close()
	return s
end

-- Pull the long-string `[[return { ... }]]` payload out of a Questie DB file
-- and evaluate it as a Lua chunk.
local function load_questie_blob(path, var_name)
	local content = read_file(path)
	local marker = var_name .. " = %[%["
	local s = content:find(marker)
	assert(s, "could not find " .. marker .. " in " .. path)
	local e = content:find("%]%]", s)
	assert(e, "could not find closing ]] in " .. path)
	local payload = content:sub(s + #(var_name .. " = [["), e - 1)
	local chunk = assert(load(payload, path, "t"))
	return chunk()
end

local quests = load_questie_blob(QUESTIE .. "/Database/TBC/tbcQuestDB.lua", "QuestieDB.questData")
local npcs   = load_questie_blob(QUESTIE .. "/Database/TBC/tbcNpcDB.lua",   "QuestieDB.npcData")

-- Pull the enUS zone names from lookupZones.lua.
local zones = {}
do
	local content = read_file(QUESTIE .. "/Localization/lookups/lookupZones.lua")
	for id, name in content:gmatch("%[(%d+)%]%s*=%s*\"([^\"]+)\"") do
		zones[tonumber(id)] = zones[tonumber(id)] or name
	end
end

-- Race bitmask -> faction
local HORDE_RACES    = 690
local ALLIANCE_RACES = 1101

local function faction_for(required_races)
	required_races = required_races or 0
	if required_races == 0 then return nil end
	local has_horde    = (required_races & HORDE_RACES) ~= 0
	local has_alliance = (required_races & ALLIANCE_RACES) ~= 0
	if has_horde and not has_alliance then return "Horde" end
	if has_alliance and not has_horde then return "Alliance" end
	return nil
end

local function lua_string(s)
	return '"' .. (s or ""):gsub("\\", "\\\\"):gsub("\"", "\\\"") .. '"'
end

-- Quests Questie's DB classifies as repeatable/daily but that don't actually
-- function that way on Anniversary (or WoWHead disagrees). Verified against
-- live behavior — the giver simply doesn't offer the listed quest.
local SKIP_QUESTS = {
	[9483]  = "Life's Finer Pleasures (Viera Sunwhisper) — Questie flags Repeatable but WoWHead lists as one-time and Viera doesn't offer it on Anniversary",
	[5101]  = "Lee's Ultimate Test Quest... of Doom! — developer/test quest Questie sorts under Children's Week",
	[10960] = "When I Grow Up... — defunct since patch 2.4 (Lady Liadrin moved to Outland); replaced by 11975 'Now, When I Grow Up...'",
	[10346] = "Return to the Abyssal Shelf (Alliance) — flagged repeatable by Questie but doesn't actually function in-game",
	[10347] = "Return to the Abyssal Shelf (Horde) — flagged repeatable by Questie but doesn't actually function in-game",
}

-- Quests Questie tags as Repeatable but that actually have a MONTHLY reset
-- in-game. The Consortium "Membership Benefits" turn-ins (rep-tier-gated)
-- are the canonical case — same NPC/coords/title; only one variant offers
-- per player based on standing, redeemable once per month.
local MONTHLY_QUESTS = {
	[9884] = true, [9885] = true, [9886] = true, [9887] = true,
}

-- Manual faction overrides for quests Questie tags requiredRaces=0 with no
-- NPC, but whose objectives clearly target one faction's racial city/NPC.
-- Children's Week side-trips are the canonical case.
local MANUAL_FACTION = {
	[10960] = "Horde",     -- When I Grow Up... (Salandria → Silvermoon, Lady Liadrin)
	[10968] = "Alliance",  -- Call on the Farseer (Dornaa → Exodar, Farseer Nobundo)
}

local TBC_ZONES = {
	-- Outland
	["Hellfire Peninsula"] = true,
	["Zangarmarsh"]        = true,
	["Terokkar Forest"]    = true,
	["Nagrand"]            = true,
	["Blade's Edge Mountains"] = true,
	["Netherstorm"]        = true,
	["Shadowmoon Valley"]  = true,
	["Shattrath City"]     = true,
	["Isle of Quel'Danas"] = true,
	-- Blood Elf / Draenei starting areas
	["Silvermoon City"]  = true,
	["Eversong Woods"]   = true,
	["Ghostlands"]       = true,
	["The Exodar"]       = true,
	["Azuremyst Isle"]   = true,
	["Bloodmyst Isle"]   = true,
	-- TBC dungeons / raids
	["Magisters' Terrace"] = true,
	["Sunwell Plateau"]    = true,
	-- BG zones whose Call-to-Arms dailies are TBC content
	["Arathi Basin"]    = true,
	["Warsong Gulch"]   = true,
	["Alterac Valley"]  = true,
	["Eye of the Storm"] = true,
}

-- BG zones bring in a flood of vanilla rep grinds (Ten Commendation Signets,
-- Master Ryson's All Seeing Eye, Korrak quests, etc.). Restrict them to
-- daily-flagged quests only — that catches the TBC Call to Arms set without
-- the vanilla noise.
local BG_ZONES = {
	["Arathi Basin"]    = true,
	["Warsong Gulch"]   = true,
	["Alterac Valley"]  = true,
	["Eye of the Storm"] = true,
}

-- Negative `zoneOrSort` values that map to seasonal world events. Quests in
-- these sorts are only obtainable while the event is active and shouldn't
-- clutter the year-round tracker.
--
-- Source comparison: Questie's lookupZones.lua claims certain IDs (e.g. -378
-- for Children's Week) but the actual TBC questDB rows use different ones
-- (Children's Week quests are sorted under -284). Both -284 and the lookup-
-- claimed -378 are listed for safety so we catch any quest tagged either way.
local SEASONAL_SORT = {
	-- Questie's lookupZones.lua claims certain IDs (e.g. -21 for Hallow's End,
	-- -378 for Children's Week) but the actual TBC questDB uses different ones
	-- (-22 for Hallow's End, -284 for Children's Week). We list both forms here
	-- so we catch quests tagged either way.
	[-21]  = "Hallow's End",
	[-22]  = "Hallow's End",
	[-284] = "Children's Week",
	[-366] = "Lunar Festival",
	[-369] = "Midsummer",
	[-370] = "Brewfest",
	[-375] = "Pilgrim's Bounty",
	[-376] = "Love is in the Air",
	[-378] = "Children's Week",
}

local function expac_for(zone)
	if zone == "" then return 2 end
	if TBC_ZONES[zone] then return 2 end
	return 1
end

-- Faction reputation IDs that flag a quest into a particular Anniversary phase.
-- Phase 4 (Sunwell): Shattered Sun Offensive (1077).
-- Phase 2 (patch 2.1 content): Sha'tari Skyguard (1031), Ogri'la (1038), Netherwing (1015).
-- Anything else defaults to Phase 1.
local PHASE_BY_REP = {
	[1077] = 4,
	[1031] = 2,
	[1038] = 2,
	[1015] = 2,
}

-- Zones that flag a quest into a particular phase regardless of rep.
local PHASE_BY_ZONE = {
	["Isle of Quel'Danas"] = 4,
	["Magisters' Terrace"] = 4,
	["Sunwell Plateau"]    = 4,
}

local function phase_for(zone, rep_reward)
	if PHASE_BY_ZONE[zone] then return PHASE_BY_ZONE[zone] end
	if rep_reward then
		for _, pair in ipairs(rep_reward) do
			local fid = pair[1]
			if fid and PHASE_BY_REP[fid] then
				return PHASE_BY_REP[fid]
			end
		end
	end
	return 1
end

local rows = {}

for qid, q in pairs(quests) do
	local name             = q[1]
	local started_by       = q[2]
	local quest_level      = q[5] or 0
	local required_races   = q[6] or 0
	local exclusive_to     = q[16]    -- {qid,...} of sibling rotation members (e.g. cooking dailies)
	local zone_or_sort     = q[17] or 0
	local quest_flags      = q[23] or 0
	local special_flags    = q[24] or 0
	local pre_quest_single = q[25]    -- single prerequisite quest ID (must be done first)
	local rep_reward       = q[26]

	local repeatable = (special_flags & 1) == 1
	local daily      = (quest_flags & 4096) == 4096

	local is_old = name and name:sub(1, 4) == "OLD "
	local is_skipped = SKIP_QUESTS[qid] ~= nil
	local seasonal_name = SEASONAL_SORT[zone_or_sort]

	-- Computed below because we need the zone before deciding.
	local raw_zone = zones[zone_or_sort] or ""

	-- Decide inclusion based on zone:
	--   * Seasonal: always include (filtered at runtime by per-event toggles).
	--   * BG zone: DAILY flag required (filters out vanilla AV rep-grind chains).
	--   * No zone: DAILY flag required (filters out city Commendation-Officer turn-ins).
	--   * TBC outland zone: DAILY or (Repeatable + level >= 58).
	--   * Otherwise: skip (Classic content).
	local include
	if seasonal_name then
		-- Seasonal events: include EVERY quest sorted under the event, regardless
		-- of repeatable/daily flags. The TBC Children's Week chain (Orphan Matron
		-- Mercy → orphan whistle → "Back to the Orphanage") is mostly one-time
		-- quests with neither flag set, but the player wants to see all of them
		-- so they can complete the achievement chain. The tracker hides one-time
		-- quests automatically once completed.
		include = true
	elseif BG_ZONES[raw_zone] then
		include = daily
	elseif raw_zone == "" then
		include = daily
	elseif TBC_ZONES[raw_zone] then
		include = daily or (repeatable and quest_level >= 58)
	elseif daily and quest_level >= 58 then
		-- Catch-all for daily-flagged TBC quests in dungeon/instance zones we
		-- haven't enumerated. The Lower City Wanted dungeon dailies are sorted
		-- under instance zones (Hellfire Citadel, Caverns of Time, etc.) by
		-- the questDB even though the giver is in Shattrath. The DAILY flag
		-- + level 58 floor is enough to keep vanilla content out.
		include = true
	else
		include = false
	end

	if include and not is_old and not is_skipped then
		local npc_id   = started_by and started_by[1] and started_by[1][1]
		local npc_data = npc_id and npcs[npc_id]
		local npc_name = (npc_data and npc_data[1]) or ""
		local zone     = raw_zone
		local faction  = faction_for(required_races)

		-- When the questDB doesn't restrict by race, fall back to the NPC's
		-- friendly-to-faction flag ("A" / "H" / "AH"). Quests like the "More
		-- Sunfury Signets" turn-in to Battlemage Vyara have requiredRaces=0
		-- but the NPC is Alliance-only.
		if not faction and npc_data and npc_data[13] then
			local f = npc_data[13]
			if     f == "H"  then faction = "Horde"
			elseif f == "A"  then faction = "Alliance"
			-- "AH" / "HA" => both factions, leave faction nil
			end
		end

		-- NPC-name-based faction fallback for race-locked-but-not-tagged
		-- helpers. Children's Week orphan NPCs are the canonical case:
		-- Blood Elf orphans only follow Horde; Draenei orphans only Alliance.
		-- Without this, both faction variants of every CW quest show up in
		-- the tracker for either side.
		if not faction and npc_name and npc_name ~= "" then
			if     npc_name == "Blood Elf Orphan"  then faction = "Horde"
			elseif npc_name == "Draenei Orphan"    then faction = "Alliance"
			elseif npc_name == "Human Orphan"      then faction = "Alliance"
			elseif npc_name == "Orcish Orphan"     then faction = "Horde"
			end
		end

		-- Last-resort manual override for quests with no NPC and no race
		-- restriction in Questie's DB but a clearly faction-locked objective.
		if not faction and MANUAL_FACTION[qid] then
			faction = MANUAL_FACTION[qid]
		end

		-- Pull the first spawn point of the questgiver, if any. Questie stores
		-- spawns at npc_data[7] as {[areaID]={{x,y},...}} with x/y in 0-100 scale.
		-- If the quest itself has no zone (e.g. cooking/fishing dailies use a -304
		-- "sort" key), fall back to the NPC's spawn zone.
		local coord_x, coord_y
		if npc_data and npc_data[7] then
			for areaID, points in pairs(npc_data[7]) do
				if points and points[1] then
					coord_x, coord_y = points[1][1], points[1][2]
					if zone == "" then
						zone = zones[areaID] or ""
					end
					break
				end
			end
		end

		local expac = expac_for(zone)
		-- Daily-flagged level-58+ quests are TBC content even if their zoneOrSort
		-- points to a dungeon container we haven't listed (Hellfire Citadel,
		-- Caverns of Time, etc.). Forcing expac=2 here keeps the heroic Wanted
		-- pool (11354, 11362, …) from being misclassified as Classic.
		if daily and quest_level >= 58 then expac = 2 end

		-- Skip Classic-zone repeatables (pollute the list and aren't TBC dailies).
		-- Allow empty zone only for seasonal quests, since many event quests have
		-- no startedBy NPC and therefore no zone we can derive.
		if expac == 2 and (zone ~= "" or seasonal_name) then
			local parts = { string.format("title=%s", lua_string(name)) }
			if npc_name ~= "" then table.insert(parts, string.format("npc=%s",  lua_string(npc_name))) end
			if zone     ~= "" then table.insert(parts, string.format("zone=%s", lua_string(zone))) end
			if faction          then table.insert(parts, string.format("faction=%s", lua_string(faction))) end
			if coord_x and coord_y then
				table.insert(parts, string.format("coords={x=%.2f,y=%.2f}", coord_x, coord_y))
			end

			if rep_reward and #rep_reward > 0 then
				local rep_parts = {}
				for _, pair in ipairs(rep_reward) do
					local fid, val = pair[1], pair[2]
					if fid and val then
						table.insert(rep_parts, string.format("[%d]=%d", fid, val))
					end
				end
				if #rep_parts > 0 then
					table.insert(parts, string.format("reps={%s}", table.concat(rep_parts, ",")))
				end
			end

			table.insert(parts, string.format("expac=%d", expac))
			table.insert(parts, string.format("phase=%d", phase_for(zone, rep_reward)))

			-- Frequency classification:
			--   "daily"      -> questFlags has DAILY bit (4096); resets at server reset
			--   "repeatable" -> Repeatable specialFlag without DAILY; can be turned in unlimited times per day
			--   "once"       -> neither; can only be done once. Mostly seasonal one-shot event quests like
			--                   "Children's Week" (10942) or the orphan-whistle chain.
			local frequency
			if MONTHLY_QUESTS[qid] then
				-- Hand-curated override: certain "Repeatable" quests are
				-- actually monthly resets in-game. See MONTHLY_QUESTS table.
				frequency = "monthly"
			elseif daily then
				frequency = "daily"
			elseif repeatable then
				frequency = "repeatable"
			else
				frequency = "once"
			end
			table.insert(parts, string.format("frequency=%s", lua_string(frequency)))

			if seasonal_name then
				table.insert(parts, string.format("seasonal=%s", lua_string(seasonal_name)))
			end

			-- Sibling list for rotation groups (cooking, fishing, Wanted dungeon
			-- pool, BG Call to Arms). When one is picked up, the others shouldn't
			-- show as "Available" for the rest of the day.
			if exclusive_to and #exclusive_to > 0 then
				local sib_parts = {}
				for _, sib in ipairs(exclusive_to) do
					table.insert(sib_parts, tostring(sib))
				end
				table.insert(parts, string.format("siblings={%s}", table.concat(sib_parts, ",")))
			end

			-- Single prerequisite quest ID (must be completed for the quest to
			-- offer up). Some "repeatable" rep grinds chain off a one-time intro
			-- quest — e.g. Life's Finer Pleasures (9483) needs 9472 first.
			if pre_quest_single and pre_quest_single > 0 then
				table.insert(parts, string.format("prereq=%d", pre_quest_single))
			end

			table.insert(rows, { qid = qid, line = string.format("\t[%d] = { %s },", qid, table.concat(parts, ", ")) })
		end
	end
end

table.sort(rows, function(a, b) return a.qid < b.qid end)

io.write("-- AUTO-GENERATED from Questie's TBC quest database.\n")
io.write("-- Filter: TBC zones only; Repeatable (specialFlags bit 0, level>=58) OR Daily (questFlags bit 12).\n")
io.write("-- Re-run extract_dailies.lua to regenerate.\n\n")
io.write("Intern_Quests = {\n")
for _, r in ipairs(rows) do io.write(r.line .. "\n") end
io.write("}\n")

io.stderr:write(string.format("Extracted %d TBC daily/repeatable quests.\n", #rows))
