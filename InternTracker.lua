-- Intern's floating tracker window. Always-visible (when any quests are tracked),
-- groups by zone, sorts each zone by state priority (Ready -> In Progress -> Available -> Completed).

local addonName, Intern = ...
local AceGUI = LibStub("AceGUI-3.0")

local charKey = UnitName("player") .. "-" .. GetRealmName()

local trackerFrame = nil
local trackerScroll = nil

-- State priority for sorting within a zone.
local STATE_ORDER = {
	ready       = 1,
	in_progress = 2,
	available   = 3,
	completed   = 4,
}

-- Sort order within a section: alphabetical by category key.
local CATEGORY_ORDER = {
	cooking    = 1,
	fishing    = 2,
	gold       = 3,
	honor      = 4,
	reputation = 5,
	wanted     = 6,
}

-- Inline-texture state markers, mirroring the WoW NPC-overhead conventions
-- (matches Questie's tracker iconography):
--   blue !  = daily quest available     (DailyQuestIcon)
--   blue ?  = daily in your log, not yet ready (DailyActiveQuestIcon)
--   yellow ?= quest ready to turn in    (ActiveQuestIcon)
--   green check = already done today    (UI-CheckBox-Check)
local STATE_MARKER = {
	available   = "|TInterface\\GossipFrame\\DailyQuestIcon:14|t ",
	in_progress = "|TInterface\\GossipFrame\\DailyActiveQuestIcon:14|t ",
	ready       = "|TInterface\\GossipFrame\\ActiveQuestIcon:14|t ",
	completed   = "|TInterface\\Buttons\\UI-CheckBox-Check:14|t ",
}

local function buildTrackerFrame()
	if trackerFrame then return end

	trackerFrame = AceGUI:Create("Frame")
	trackerFrame:SetTitle("Intern - Today's Memo")
	trackerFrame:SetStatusText("")
	trackerFrame:SetWidth(Intern_Char[charKey].tracker.width  or 280)
	trackerFrame:SetHeight(Intern_Char[charKey].tracker.height or 400)
	trackerFrame:SetLayout("Flow")
	trackerFrame:SetCallback("OnClose", function(widget)
		Intern_Char[charKey].tracker.shown = false
	end)

	_G["InternTrackerFrame"] = trackerFrame.frame
	tinsert(UISpecialFrames, "InternTrackerFrame")

	-- Layout persistence: apply previously saved point/size, then capture every
	-- drag-stop / size-changed / hide via the shared helpers in Intern.lua.
	Intern.ApplyFrameLayout(Intern_Char[charKey].tracker, trackerFrame.frame)
	Intern.WireFrameLayoutHooks(Intern_Char[charKey].tracker, trackerFrame)

	trackerScroll = AceGUI:Create("ScrollFrame")
	trackerScroll:SetLayout("Flow")
	trackerScroll:SetFullWidth(true)
	trackerScroll:SetFullHeight(true)
	trackerFrame:AddChild(trackerScroll)
end

-- Render the tracker contents from scratch (called by RequestUpdate's throttle).
function Intern.RefreshTracker()
	if not trackerFrame then
		-- Lazy-build only once we have something to show — either a tracked
		-- quest or a tracked profession CD.
		local hasTracked = false
		for qid in pairs(Intern_Char[charKey].tracked) do
			if Intern_Quests[qid] then hasTracked = true; break end
		end
		if not hasTracked and Intern_Char[charKey].trackedCDs then
			for _ in pairs(Intern_Char[charKey].trackedCDs) do hasTracked = true; break end
		end
		if not hasTracked then return end
		buildTrackerFrame()
		if Intern_Char[charKey].tracker.shown == false then
			trackerFrame.frame:Hide()
		end
	end

	if not trackerFrame.frame:IsShown() then return end

	-- Preserve scroll position across rebuilds. ReleaseChildren() destroys all
	-- children and re-laying out resets the scroll to 0, which is jarring when
	-- a refresh fires from a click handler (shift-click to untrack, etc.).
	local savedScroll = trackerScroll.localstatus and trackerScroll.localstatus.scrollvalue or 0

	trackerScroll:ReleaseChildren()

	-- Bucket tracked quests by section, then category. Section is decided by
	-- Intern.GetSectionName (seasonal event name beats frequency); category
	-- comes from Intern.GetQuestCategory (cooking/fishing/wanted/honor/...).
	-- Seasonal sections render flat — see the renderSection helper below.
	local bySection = {}
	for qid in pairs(Intern_Char[charKey].tracked) do
		local info = Intern_Quests[qid]
		if info and Intern.PassesTrackerFilters(qid) then
			local section  = Intern.GetSectionName(qid)
			local category = Intern.GetQuestCategory(qid)
			bySection[section] = bySection[section] or {}
			bySection[section][category] = bySection[section][category] or {}
			table.insert(bySection[section][category], qid)
		end
	end

	-- Note: we deliberately do NOT dedupe by title here. The browse window's
	-- master/variant rows let the player track or untrack individual sibling
	-- IDs; the tracker should reflect that selection accurately, so each
	-- tracked qid gets its own row with its own NPC/zone/coords.

	-- Sorted section list. Intern.GetSectionSortKey puts Dailies first,
	-- Repeatables second, then seasonal events alphabetically.
	local sections = {}
	for name in pairs(bySection) do table.insert(sections, name) end
	table.sort(sections, function(a, b)
		return Intern.GetSectionSortKey(a) < Intern.GetSectionSortKey(b)
	end)

	local total = 0

	-- Renders one (section, categoryMap) bucket. Returns the number of rows emitted.
	-- For seasonal sections (anything that isn't "Dailies" or "Repeatables") we
	-- render the quests flat under a single anonymous bucket — events typically
	-- have too few quests to warrant a category sub-grouping, and most are
	-- frequency=once with no meaningful category.
	local function renderSection(sectionName, label, categoryMap)
		local isFlat = (sectionName ~= "Dailies" and sectionName ~= "Repeatables")

		-- Section header (rendered after we know there's at least one row to show).
		local headerEmitted = false
		local emitted = 0

		local function emitHeader()
			if headerEmitted then return end
			local sLabel = AceGUI:Create("Label")
			sLabel:SetText((total > 0 and "\n" or "") .. "|cffffd100" .. label .. "|r")
			sLabel:SetFullWidth(true)
			sLabel:SetFont(GameFontNormal:GetFont(), 14)
			trackerScroll:AddChild(sLabel)
			headerEmitted = true
		end

		-- Build an ordered list of category buckets.
		local categoryList = {}
		for cat in pairs(categoryMap) do table.insert(categoryList, cat) end
		table.sort(categoryList, function(a, b)
			return (CATEGORY_ORDER[a] or 99) < (CATEGORY_ORDER[b] or 99)
		end)

		for _, category in ipairs(categoryList) do
			local quests = categoryMap[category]

			-- Group qids that are visually indistinguishable (same title, NPC,
			-- zone, coords). Questie's DB lists rep-grind variants like
			-- "Membership Benefits" 9884-9887 as four separate qids, but all
			-- four are taken from the same NPC at the same coords with the
			-- same title — rendering four identical rows is just clutter.
			local groups = {}
			local sigToIdx = {}
			for _, qid in ipairs(quests) do
				local info = Intern_Quests[qid]
				local cx = info.coords and info.coords.x or 0
				local cy = info.coords and info.coords.y or 0
				local sig = string.format("%s|%s|%s|%.2f|%.2f",
					info.title or "", info.npc or "", info.zone or "", cx, cy)
				if sigToIdx[sig] then
					table.insert(groups[sigToIdx[sig]], qid)
				else
					sigToIdx[sig] = #groups + 1
					groups[#groups + 1] = { qid }
				end
			end

			-- For a group, the "display state" is the most-meaningful state any
			-- member is in. Priority differs from the sort order: within a group
			-- we want `completed` to beat `available` because the siblings are
			-- visually identical to the player — completing any one of them
			-- means the user has done "the quest" (canonical case: monthly
			-- "Membership Benefits" rep-tier variants). The sort within a
			-- category still uses STATE_ORDER, which keeps Done rows at the
			-- bottom.
			local REP_PRIORITY = { in_progress = 1, ready = 2, completed = 3, available = 4 }
			local function representativeOf(group)
				local bestQid, bestState = group[1], Intern.GetQuestState(group[1])
				for i = 2, #group do
					local s = Intern.GetQuestState(group[i])
					if (REP_PRIORITY[s] or 99) < (REP_PRIORITY[bestState] or 99) then
						bestQid, bestState = group[i], s
					end
				end
				return bestQid, bestState
			end

			-- Sort groups by state priority, then alphabetical title.
			table.sort(groups, function(a, b)
				local _, sa = representativeOf(a)
				local _, sb = representativeOf(b)
				local pa = STATE_ORDER[sa] or 99
				local pb = STATE_ORDER[sb] or 99
				if pa ~= pb then return pa < pb end
				return (Intern_Quests[a[1]].title or "") < (Intern_Quests[b[1]].title or "")
			end)

			local pendingHeader = (not isFlat) and (Intern.CATEGORY_LABEL[category] or category) or nil

			for _, group in ipairs(groups) do
				local repQid, state = representativeOf(group)
				local info = Intern_Quests[repQid]
				-- Auto-hide once-completed one-time event quests regardless of the
				-- showCompletedInTracker toggle. Their state stays "completed" forever
				-- (within an event) so leaving them visible just clutters the list.
				-- Repeatable + daily quests still respect the toggle.
				local skipBecauseOnce = state == "completed" and info and info.frequency == "once"
				if (state == "completed" and not Intern_Settings.showCompletedInTracker) or skipBecauseOnce then
					-- skip
				else
					emitHeader()
					if pendingHeader then
						local hLabel = AceGUI:Create("Label")
						hLabel:SetText("  |cffffffff" .. pendingHeader .. "|r")
						hLabel:SetFullWidth(true)
						hLabel:SetFont(GameFontNormal:GetFont(), 12)
						trackerScroll:AddChild(hLabel)
						pendingHeader = nil
					end

					-- Flat sections (seasonal events) get less indent because there's
					-- no category sub-header to nest under.
					local indent = isFlat and "  " or "    "
					local heroicTag = (Intern.IsHeroicWanted and Intern.IsHeroicWanted(repQid))
						and "|cffff8000[H]|r " or ""
					local row  = AceGUI:Create("InteractiveLabel")
					row:SetText(indent .. (STATE_MARKER[state] or "") .. heroicTag .. (info.title or ""))
					row:SetFullWidth(true)
					row:SetFont(GameFontNormal:GetFont(), 12)
					row:SetCallback("OnClick", function(widget, _, button)
						if button == "RightButton" or IsShiftKeyDown() then
							-- Untrack the entire group — they're indistinguishable
							-- to the player, so untracking only one would just
							-- leave a near-duplicate row in place.
							for _, gqid in ipairs(group) do
								Intern_Char[charKey].tracked[gqid] = nil
							end
							Intern.RequestUpdate()
						elseif IsControlKeyDown() then
							if Intern.SetWaypoint then
								Intern.SetWaypoint(repQid)
							else
								print("|cffff00ff[Intern]|r Intern.SetWaypoint missing")
							end
						else
							if C_QuestLog.IsOnQuest(repQid) then
								local logIndex = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(repQid)
								if logIndex and SelectQuestLogEntry then SelectQuestLogEntry(logIndex) end
							end
						end
					end)
					row:SetCallback("OnEnter", function(widget)
						local body = Intern.GetQuestTooltip and Intern.GetQuestTooltip(repQid)
						if not body then return end
						GameTooltip:SetOwner(widget.frame, "ANCHOR_RIGHT")
						for line in body:gmatch("([^\n]*)\n?") do
							if line ~= "" then GameTooltip:AddLine(line, 1, 1, 1, true) end
						end
						GameTooltip:Show()
					end)
					row:SetCallback("OnLeave", function() GameTooltip:Hide() end)
					trackerScroll:AddChild(row)

					emitted = emitted + 1
					total   = total + 1
				end
			end
		end

		return emitted
	end

	for _, sectionName in ipairs(sections) do
		-- Section names are already Title Case (Dailies / Repeatables / Children's Week).
		renderSection(sectionName, sectionName, bySection[sectionName])
	end

	-- Cooldowns section: profession CDs the player has opted in to (Browse
	-- window). Each row's state comes from GetSpellCooldown — "ready" when off
	-- CD, "completed" with a remaining-time suffix while on CD.
	local trackedCDs = Intern_Char[charKey].trackedCDs or {}
	local cdList = {}
	for spellID in pairs(trackedCDs) do
		if Intern.ProfessionCDs and Intern.ProfessionCDs[spellID] and IsSpellKnown and IsSpellKnown(spellID) then
			table.insert(cdList, spellID)
		end
	end
	table.sort(cdList, function(a, b)
		return (Intern.ProfessionCDs[a].name or "") < (Intern.ProfessionCDs[b].name or "")
	end)

	if #cdList > 0 then
		-- Two-pass: filter rows respecting showCompletedInTracker, then emit.
		local rows = {}
		for _, spellID in ipairs(cdList) do
			local state, remaining = Intern.GetCDState(spellID)
			if not (state == "completed" and not Intern_Settings.showCompletedInTracker) then
				table.insert(rows, { spellID = spellID, state = state, remaining = remaining })
			end
		end
		-- Within Cooldowns, ready entries come before on-CD ones.
		table.sort(rows, function(a, b)
			local sa = (a.state == "ready") and 1 or 2
			local sb = (b.state == "ready") and 1 or 2
			if sa ~= sb then return sa < sb end
			return (Intern.ProfessionCDs[a.spellID].name or "") < (Intern.ProfessionCDs[b.spellID].name or "")
		end)

		if #rows > 0 then
			local sLabel = AceGUI:Create("Label")
			sLabel:SetText((total > 0 and "\n" or "") .. "|cffffd100Cooldowns|r")
			sLabel:SetFullWidth(true)
			sLabel:SetFont(GameFontNormal:GetFont(), 14)
			trackerScroll:AddChild(sLabel)

			for _, r in ipairs(rows) do
				local meta   = Intern.ProfessionCDs[r.spellID]
				local badge  = (Intern.PROFESSION_BADGE and Intern.PROFESSION_BADGE[meta.profession]) or ""
				local marker = (r.state == "ready" and STATE_MARKER.ready) or STATE_MARKER.completed
				local suffix = (r.state == "completed" and r.remaining > 0)
					and string.format(" |cff808080(%s)|r", Intern.FormatCDRemaining(r.remaining))
					or ""
				local row = AceGUI:Create("InteractiveLabel")
				row:SetText("  " .. badge .. " " .. marker .. meta.name .. suffix)
				row:SetFullWidth(true)
				row:SetFont(GameFontNormal:GetFont(), 12)
				row:SetCallback("OnClick", function(_, _, button)
					if button == "RightButton" or IsShiftKeyDown() then
						Intern_Char[charKey].trackedCDs[r.spellID] = nil
						Intern.RequestUpdate()
					end
				end)
				row:SetCallback("OnEnter", function(widget)
					GameTooltip:SetOwner(widget.frame, "ANCHOR_RIGHT")
					GameTooltip:SetSpellByID(r.spellID)
					GameTooltip:Show()
				end)
				row:SetCallback("OnLeave", function() GameTooltip:Hide() end)
				trackerScroll:AddChild(row)
				total = total + 1
			end
		end
	end

	if total == 0 then
		local empty = AceGUI:Create("Label")
		empty:SetText("\n No tracked quests match the current filters.")
		empty:SetFullWidth(true)
		empty:SetFont(GameFontNormal:GetFont(), 12)
		trackerScroll:AddChild(empty)
	end

	-- Restore scroll position after AceGUI's deferred layout pass. Without this,
	-- shift-clicking a row in the middle of a long tracker rebuilds and snaps
	-- back to the top, which is jarring.
	if savedScroll and savedScroll > 0 and trackerScroll.scrollbar then
		C_Timer.After(0, function()
			if trackerScroll and trackerScroll.scrollbar then
				trackerScroll.scrollbar:SetValue(savedScroll)
			end
		end)
	end
end

function Intern.ShowTracker()
	if not trackerFrame then buildTrackerFrame() end
	Intern_Char[charKey].tracker.shown = true
	trackerFrame.frame:Show()
	Intern.RefreshTracker()
end

function Intern.HideTracker()
	if not trackerFrame then return end
	Intern_Char[charKey].tracker.shown = false
	trackerFrame.frame:Hide()
end

function Intern.ToggleTracker()
	if trackerFrame and trackerFrame.frame:IsShown() then
		Intern.HideTracker()
	else
		Intern.ShowTracker()
	end
end
