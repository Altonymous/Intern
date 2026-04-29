-- Intern's settings panel (Ace3 options table).

local addonName, Intern = ...

local function refresh()
	Intern.RequestUpdate()
end

-- Characters that see developer-only options (currently just the TBC Phase
-- dropdown). Everyone else gets a settings panel without it; the shipped phase
-- value comes from InternDefaults.lua. To roll the realm forward to a new
-- phase for end users, bump InternDefaults.lua and re-publish.
local DEV_CHARACTERS = {
	["Saiba-Nightslayer"] = true,
}

local function isDevChar()
	local key = (UnitName("player") or "") .. "-" .. (GetRealmName() or "")
	return DEV_CHARACTERS[key] or false
end

-- All seasonal events the Settings panel knows about. Listed here even when
-- the bundled data has zero quests for an event, because the toggle persists
-- the player's intent ("yes, track Hallow's End when it goes live") and
-- subsequent data refreshes will pick it up.
local SEASONAL_EVENTS = {
	"Brewfest", "Children's Week", "Hallow's End", "Love is in the Air",
	"Lunar Festival", "Midsummer", "Pilgrim's Bounty",
}

-- Combine hardcoded events with anything new the bundled data added (so a
-- future extract that picks up new event sorts shows up in Settings without
-- any manual list update).
local function getSeasonalEvents()
	local seen, list = {}, {}
	for _, ev in ipairs(SEASONAL_EVENTS) do
		seen[ev] = true
		table.insert(list, ev)
	end
	if Intern_Quests then
		for _, info in pairs(Intern_Quests) do
			if info.seasonal and not seen[info.seasonal] then
				seen[info.seasonal] = true
				table.insert(list, info.seasonal)
			end
		end
	end
	table.sort(list)
	return list
end

local options = {
	type = "group",
	name = "Intern",
	args = {
		header_general = {
			type  = "header",
			name  = "General",
			order = 10,
		},
		showTracker = {
			type  = "execute",
			name  = "Show Tracker",
			desc  = "Open the floating tracker window.",
			order = 11,
			func  = function() if Intern.ShowTracker then Intern.ShowTracker() end end,
		},
		hideTracker = {
			type  = "execute",
			name  = "Hide Tracker",
			desc  = "Close the floating tracker window.",
			order = 12,
			func  = function() if Intern.HideTracker then Intern.HideTracker() end end,
		},

		header_auto = {
			type  = "header",
			name  = "Auto-flow",
			order = 20,
		},
		autoAccept = {
			type  = "toggle",
			name  = "Auto-accept tracked quests",
			desc  = "When you talk to an NPC offering a quest you're tracking, accept it automatically.",
			order = 21,
			width = "full",
			get   = function() return Intern_Settings.autoAccept end,
			set   = function(_, val) Intern_Settings.autoAccept = val end,
		},
		autoTurnIn = {
			type  = "toggle",
			name  = "Auto-turn-in tracked quests",
			desc  = "When you talk to an NPC who can turn in a quest you're tracking, complete it automatically (when there's no reward choice).",
			order = 22,
			width = "full",
			get   = function() return Intern_Settings.autoTurnIn end,
			set   = function(_, val) Intern_Settings.autoTurnIn = val end,
		},

		header_filters = {
			type  = "header",
			name  = "Display filters",
			order = 30,
		},
		showCompletedInTracker = {
			type  = "toggle",
			name  = "Show completed quests in tracker",
			desc  = "When off, tracked quests that are already done today are hidden from the tracker.",
			order = 31,
			width = "full",
			get   = function() return Intern_Settings.showCompletedInTracker end,
			set   = function(_, val) Intern_Settings.showCompletedInTracker = val; refresh() end,
		},
		showOnlyForKnownProfessions = {
			type  = "toggle",
			name  = "Hide profession dailies for professions you don't have",
			desc  = "When on, cooking dailies hide unless you have Cooking; fishing dailies hide unless you have Fishing.",
			order = 32,
			width = "full",
			get   = function() return Intern_Settings.showOnlyForKnownProfessions end,
			set   = function(_, val) Intern_Settings.showOnlyForKnownProfessions = val; refresh() end,
		},
		trackRepAtExalted = {
			type  = "toggle",
			name  = "Track reputation quests at Exalted",
			desc  = "When on, rep dailies stay visible even after you hit Exalted (useful for gold farming). When off, a rep daily auto-hides once you're Exalted with every faction it rewards.",
			order = 33,
			width = "full",
			get   = function() return Intern_Settings.trackRepAtExalted end,
			set   = function(_, val) Intern_Settings.trackRepAtExalted = val; refresh() end,
		},
		hideRepeatables = {
			type  = "toggle",
			name  = "Hide repeatables",
			desc  = "When on, the Repeatables section (rep grinds like 'Another Heap of Ethereals' that can be turned in unlimited times per day) is hidden from the tracker. Dailies (true once-per-day quests) are unaffected.",
			order = 34,
			width = "full",
			get   = function() return Intern_Settings.hideRepeatables end,
			set   = function(_, val) Intern_Settings.hideRepeatables = val; refresh() end,
		},

		header_events = {
			type  = "header",
			name  = "Seasonal events",
			order = 40,
		},
		eventsDesc = {
			type  = "description",
			name  = "Toggle on the events that are currently live on your realm. These override individual tracking — a seasonal quest stays hidden until its event is checked.",
			order = 41,
			fontSize = "small",
		},

		header_phase = {
			type   = "header",
			name   = "Content phase",
			order  = 60,
			hidden = function() return not isDevChar() end,
		},
		currentPhaseTBC = {
			type   = "select",
			name   = "TBC Current Phase",
			desc   = "Which content phase your realm is currently on. Affects which dailies are seeded into the tracked set on a fresh character.",
			order  = 61,
			width  = "full",
			values = { [1] = "Phase 1 (Launch)", [2] = "Phase 2 (Skettis / Ogri'la / Netherwing)", [4] = "Phase 4 (Sunwell)" },
			get    = function() return (Intern_CurrentPhase[2] or 1) end,
			set    = function(_, val) Intern_CurrentPhase[2] = val end,
			hidden = function() return not isDevChar() end,
		},
	},
}

-- Generate one toggle per seasonal event present in the data. Done at panel
-- registration time so newly-extracted events automatically appear.
local function buildEventToggles()
	-- Strip any previously-built event_* entries (in case we ever rebuild).
	for k in pairs(options.args) do
		if type(k) == "string" and k:sub(1, 6) == "event_" then
			options.args[k] = nil
		end
	end
	local order = 42
	for _, ev in ipairs(getSeasonalEvents()) do
		local key = "event_" .. ev:gsub("[^%w]", "")
		options.args[key] = {
			type  = "toggle",
			name  = "Track " .. ev,
			order = order,
			width = "full",
			get   = function() return Intern_Settings.events and Intern_Settings.events[ev] end,
			set   = function(_, val) Intern_Settings.events[ev] = val; refresh() end,
		}
		order = order + 1
	end
end

function Intern.SetupOptions()
	buildEventToggles()
	LibStub("AceConfig-3.0"):RegisterOptionsTable("Intern", options)
	Intern.optionsFrame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("Intern", "Intern")
end

function Intern.OpenOptions()
	if Settings and Settings.OpenToCategory then
		Settings.OpenToCategory("Intern")
	elseif InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory("Intern")
		InterfaceOptionsFrame_OpenToCategory("Intern")
	end
end
