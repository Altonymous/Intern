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

-- Height of the tracker when collapsed — just the title bar's worth.
local TITLE_ONLY_HEIGHT = 28

-- Apply (or clear) the transparent-background style on the tracker. Driven
-- by Intern_Settings.transparentTracker; called from buildTrackerFrame and
-- whenever the toggle flips in the options panel. Transparent mode kills
-- the dialog backdrop fill, the dialog border, and every decorative texture
-- on the main frame (titlebg + the two side curves) — leaving just the
-- title text + scroll content.
function Intern.ApplyTrackerStyle()
	if not trackerFrame then return end
	local transparent = Intern_Settings and Intern_Settings.transparentTracker
	local fillAlpha   = transparent and 0 or 1
	local borderAlpha = transparent and 0 or 1
	local f = trackerFrame.frame
	if f.SetBackdropColor then f:SetBackdropColor(0, 0, 0, fillAlpha) end
	if f.SetBackdropBorderColor then f:SetBackdropBorderColor(1, 1, 1, borderAlpha) end
	-- Iterate regions: only the dialog-header textures are direct regions of
	-- the main frame (titlebg, titlebg_l, titlebg_r). Content lives in child
	-- frames and is unaffected. FontStrings (titletext) skipped via type check.
	for i = 1, f:GetNumRegions() do
		local r = select(i, f:GetRegions())
		if r and r.GetObjectType and r:GetObjectType() == "Texture" and r.SetAlpha then
			r:SetAlpha(transparent and 0 or 1)
		end
	end
end

-- Title text for the tracker. Questie uses a "+" suffix when collapsed as
-- a visual cue that clicking expands it.
local TRACKER_TITLE = "Intern - Today's Memo"

-- Re-anchor the frame so its TOPLEFT corner stays fixed at its current
-- screen position. SetHeight on a frame anchored by CENTER (AceGUI's
-- default after a drag) keeps the center fixed and pulls the top down
-- when shrinking — visible side-effect when collapsing the tracker.
-- Locking to TOPLEFT means SetHeight only affects the bottom edge.
local function reanchorToTopLeft(frame)
	if not frame then return end
	local left, top = frame:GetLeft(), frame:GetTop()
	if not (left and top) then return end
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
end

-- Apply the persisted collapsed state.
--   Collapsed: ReleaseChildren on the scroll (drops every row back to
--     AceGUI's pool — their frames hide reliably this way, since SetHeight
--     alone doesn't shrink the content frame's anchored height), Hide the
--     scroll wrapper, shrink the tracker, append "+" to the title.
--   Expanded: restore full height, show the scroll, drop the "+",
--     RefreshTracker re-creates the rows.
local function applyTrackerCollapsed()
	if not trackerFrame then return end
	local t = Intern_Char[charKey].tracker
	-- Lock the anchor before SetHeight so the title doesn't drift.
	reanchorToTopLeft(trackerFrame.frame)
	if t.collapsed then
		if trackerScroll then
			trackerScroll:ReleaseChildren()
			if trackerScroll.frame   then trackerScroll.frame:Hide()   end
		end
		trackerFrame:SetHeight(TITLE_ONLY_HEIGHT)
		if trackerFrame.titletext then
			trackerFrame.titletext:SetText(TRACKER_TITLE .. "  +")
		end
	else
		local h = t.height or 400
		if h <= TITLE_ONLY_HEIGHT + 20 then h = 400 end
		trackerFrame:SetHeight(h)
		if trackerScroll and trackerScroll.frame then trackerScroll.frame:Show() end
		if trackerFrame.titletext then
			trackerFrame.titletext:SetText(TRACKER_TITLE)
		end
		Intern.RefreshTracker()
	end
end

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

	-- Re-anchor the title to the frame's TOPLEFT (default AceGUI anchors it
	-- to the centered titlebg texture). Anchoring to the frame directly gets
	-- us a true left-aligned title like Questie's tracker.
	if trackerFrame.titletext then
		trackerFrame.titletext:ClearAllPoints()
		trackerFrame.titletext:SetPoint("TOPLEFT", trackerFrame.frame, "TOPLEFT", 14, -10)
		trackerFrame.titletext:SetJustifyH("LEFT")
	end

	-- AceGUI doesn't expose the close button, status background, or title
	-- frame on the widget table — they're created as locals in the widget
	-- constructor. Reach them via GetParent / GetChildren.
	local titleFrame = trackerFrame.titletext and trackerFrame.titletext:GetParent()
	local statusBg   = trackerFrame.statustext and trackerFrame.statustext:GetParent()
	local closeBtn
	for i = 1, trackerFrame.frame:GetNumChildren() do
		local kid = select(i, trackerFrame.frame:GetChildren())
		if kid and kid.GetText and kid:GetObjectType() == "Button" and kid:GetText() == "Close" then
			closeBtn = kid
			break
		end
	end

	-- Strip bottom-bar chrome (Close + status text). Override Show on each
	-- so AceGUI's layout passes can't bring them back.
	if closeBtn then
		closeBtn:Hide()
		closeBtn.Show = function() end
	end
	if statusBg and statusBg ~= trackerFrame.frame then
		statusBg:Hide()
		statusBg.Show = function() end
	end
	if trackerFrame.statustext then trackerFrame.statustext:Hide() end

	-- Bottom-right resize grip: invisible at rest, faded in whenever the
	-- mouse is anywhere over the tracker window. Polling IsMouseOver via a
	-- throttled OnUpdate is the most reliable way — OnEnter/OnLeave on the
	-- parent fire inconsistently when the mouse moves between children.
	if trackerFrame.sizer_se then
		local sizer = trackerFrame.sizer_se
		local function setSizerAlpha(a)
			for i = 1, sizer:GetNumRegions() do
				local r = select(i, sizer:GetRegions())
				if r and r.GetObjectType and r:GetObjectType() == "Texture" and r.SetAlpha then
					r:SetAlpha(a)
				end
			end
		end
		setSizerAlpha(0)

		local lastOver = false
		trackerFrame.frame:SetScript("OnUpdate", function(self, elapsed)
			self._internAccum = (self._internAccum or 0) + elapsed
			if self._internAccum < 0.1 then return end
			self._internAccum = 0
			local over = self:IsMouseOver()
			if over ~= lastOver then
				lastOver = over
				setSizerAlpha(over and 1 or 0)
			end
		end)
	end

	-- Make the title frame's hit-area span the full top edge of the main
	-- frame — so clicks anywhere on the title bar register, not just where
	-- the original titlebg texture was anchored at center.
	if titleFrame then
		titleFrame:ClearAllPoints()
		titleFrame:SetPoint("TOPLEFT",  trackerFrame.frame, "TOPLEFT",  0, 0)
		titleFrame:SetPoint("TOPRIGHT", trackerFrame.frame, "TOPRIGHT", 0, 0)
		titleFrame:SetHeight(28)
	end

	-- Replace the title bar's drag handlers: plain left-click+drag moves the
	-- frame; click without dragging toggles collapse. We detect "click vs
	-- drag" by snapshotting the frame's position on mouse-down and comparing
	-- on mouse-up — if the position changed, it was a drag.
	if titleFrame then
		titleFrame:SetScript("OnMouseDown", function(self)
			local frame = self:GetParent()
			frame:StartMoving()
			self._intern_downLeft = frame:GetLeft()
			self._intern_downTop  = frame:GetTop()
			AceGUI:ClearFocus()
		end)
		titleFrame:SetScript("OnMouseUp", function(self)
			local frame = self:GetParent()
			frame:StopMovingOrSizing()
			local moved = (self._intern_downLeft ~= frame:GetLeft())
			           or (self._intern_downTop  ~= frame:GetTop())
			if moved then
				-- Mirror AceGUI's MoverSizer_OnMouseUp: keep the widget's
				-- internal status table in sync so resize handles + other
				-- consumers see the new geometry.
				local widget = frame.obj
				if widget then
					local status = widget.status or widget.localstatus
					if status then
						status.width  = frame:GetWidth()
						status.height = frame:GetHeight()
						status.top    = frame:GetTop()
						status.left   = frame:GetLeft()
					end
				end
				Intern.SaveFrameLayout(Intern_Char[charKey].tracker, frame)
			else
				-- No position change → it was a click, toggle collapse.
				Intern_Char[charKey].tracker.collapsed = not Intern_Char[charKey].tracker.collapsed
				applyTrackerCollapsed()
			end
		end)
	end

	-- Deliberately NOT registered in UISpecialFrames: opening the world map
	-- (and other "close all windows" actions) would otherwise hide the tracker.
	-- Questie's tracker behaves the same way — stays visible through map opens.
	_G["InternTrackerFrame"] = trackerFrame.frame

	Intern.ApplyTrackerStyle()

	-- Layout persistence: apply previously saved point/size, then capture every
	-- drag-stop / size-changed / hide via the shared helpers in Intern.lua.
	Intern.ApplyFrameLayout(Intern_Char[charKey].tracker, trackerFrame.frame)
	-- Force TOPLEFT anchor so the upcoming applyTrackerCollapsed() SetHeight
	-- adjusts the bottom edge only — keeps the visible title position stable.
	reanchorToTopLeft(trackerFrame.frame)
	Intern.WireFrameLayoutHooks(Intern_Char[charKey].tracker, trackerFrame)

	trackerScroll = AceGUI:Create("ScrollFrame")
	trackerScroll:SetLayout("Flow")
	trackerScroll:SetFullWidth(true)
	trackerScroll:SetFullHeight(true)
	trackerFrame:AddChild(trackerScroll)

	-- Hide the scrollbar (Questie-style). Mousewheel still scrolls the
	-- content. AceGUI's FixScroll auto-shows the bar when content overflows;
	-- override Show on the scrollbar so it stays invisible.
	if trackerScroll.scrollbar then
		trackerScroll.scrollbar:Hide()
		trackerScroll.scrollbar.Show = function() end
	end

	-- Override AceGUI's 400x200 minimum size so the user can shrink the
	-- tracker to a narrow column if they like. The newer SetResizeBounds
	-- API is preferred when available; fall back to SetMinResize otherwise.
	if trackerFrame.frame.SetResizeBounds then
		trackerFrame.frame:SetResizeBounds(180, 50)
	elseif trackerFrame.frame.SetMinResize then
		trackerFrame.frame:SetMinResize(180, 50)
	end

	-- Apply the persisted collapsed state last (after scroll exists).
	applyTrackerCollapsed()

	-- Re-apply transparency last so nothing in the buildup (AddChild's
	-- layout pass, AceGUI's internal SetBackdropColor calls) stomps it.
	Intern.ApplyTrackerStyle()
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

	-- Skip content rendering while the tracker is collapsed. Without this,
	-- any subsequent QUEST_LOG_UPDATE / QUEST_TURNED_IN / etc. event would
	-- repopulate rows on top of the collapsed title bar.
	if Intern_Char[charKey].tracker.collapsed then return end

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

		local sectionCollapsed = Intern_Char[charKey].tracker.sectionCollapsed
			and Intern_Char[charKey].tracker.sectionCollapsed[sectionName]

		local function emitHeader()
			if headerEmitted then return end
			local sLabel = AceGUI:Create("InteractiveLabel")
			local indicator = sectionCollapsed and "|cffffd100[+]|r " or ""
			sLabel:SetText((total > 0 and "\n" or "") .. indicator .. "|cffffd100" .. label .. "|r")
			sLabel:SetFullWidth(true)
			sLabel:SetFont(GameFontNormal:GetFont(), 14, "")
			sLabel:SetCallback("OnClick", function()
				Intern_Char[charKey].tracker.sectionCollapsed[sectionName] =
					not Intern_Char[charKey].tracker.sectionCollapsed[sectionName]
				Intern.RefreshTracker()
			end)
			trackerScroll:AddChild(sLabel)
			headerEmitted = true
		end

		-- If collapsed, emit just the header and return — the user can click
		-- it again to expand.
		if sectionCollapsed then
			emitHeader()
			return 1
		end

		-- Build an ordered list of category buckets.
		local categoryList = {}
		for cat in pairs(categoryMap) do table.insert(categoryList, cat) end
		table.sort(categoryList, function(a, b)
			return (CATEGORY_ORDER[a] or 99) < (CATEGORY_ORDER[b] or 99)
		end)

		for _, category in ipairs(categoryList) do
			local quests = categoryMap[category]
			local categoryKey = sectionName .. "::" .. category
			local categoryCollapsed = Intern_Char[charKey].tracker.categoryCollapsed
				and Intern_Char[charKey].tracker.categoryCollapsed[categoryKey]

			-- Collapsed category: emit header (clickable to re-expand) and skip rows.
			if categoryCollapsed and not isFlat then
				emitHeader()
				local hLabel = AceGUI:Create("InteractiveLabel")
				hLabel:SetText("  |cffffd100[+]|r |cffffffff" .. (Intern.CATEGORY_LABEL[category] or category) .. "|r")
				hLabel:SetFullWidth(true)
				hLabel:SetFont(GameFontNormal:GetFont(), 12, "")
				hLabel:SetCallback("OnClick", function()
					Intern_Char[charKey].tracker.categoryCollapsed[categoryKey] = nil
					Intern.RefreshTracker()
				end)
				trackerScroll:AddChild(hLabel)
				emitted = emitted + 1
				total   = total + 1
			else

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

			-- Sort groups by state priority, then (within Dungeons category)
			-- heroics first, then alphabetical title.
			table.sort(groups, function(a, b)
				local _, sa = representativeOf(a)
				local _, sb = representativeOf(b)
				local pa = STATE_ORDER[sa] or 99
				local pb = STATE_ORDER[sb] or 99
				if pa ~= pb then return pa < pb end
				if category == "wanted" and Intern.IsHeroicWanted then
					local ha = Intern.IsHeroicWanted(a[1]) and 0 or 1
					local hb = Intern.IsHeroicWanted(b[1]) and 0 or 1
					if ha ~= hb then return ha < hb end
				end
				return (Intern_Quests[a[1]].title or "") < (Intern_Quests[b[1]].title or "")
			end)

			-- Reputation gets an extra layer: bucket groups by their primary
			-- faction (highest rep amount among rewards) so rows render
			-- under per-faction subheaders. Other categories use a single
			-- bucket with no faction subheader.
			local factionBuckets = {}
			if category == "reputation" and not isFlat then
				local byFaction = {}
				for _, group in ipairs(groups) do
					local fid = (Intern.GetPrimaryRepFaction and Intern.GetPrimaryRepFaction(group[1])) or 0
					byFaction[fid] = byFaction[fid] or {}
					table.insert(byFaction[fid], group)
				end
				local factionIds = {}
				for fid in pairs(byFaction) do table.insert(factionIds, fid) end
				local nameOf = Intern.GetFactionName or function(id) return tostring(id) end
				table.sort(factionIds, function(a, b)
					return (nameOf(a) or "") < (nameOf(b) or "")
				end)
				for _, fid in ipairs(factionIds) do
					table.insert(factionBuckets, { factionName = nameOf(fid), groups = byFaction[fid] })
				end
			else
				table.insert(factionBuckets, { factionName = nil, groups = groups })
			end

			local pendingHeader = (not isFlat) and (Intern.CATEGORY_LABEL[category] or category) or nil

			for _, bucket in ipairs(factionBuckets) do
				local pendingFactionHeader = bucket.factionName

				for _, group in ipairs(bucket.groups) do
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
						local hLabel = AceGUI:Create("InteractiveLabel")
						local indicator = categoryCollapsed and "|cffffd100[+]|r " or ""
						hLabel:SetText("  " .. indicator .. "|cffffffff" .. pendingHeader .. "|r")
						hLabel:SetFullWidth(true)
						hLabel:SetFont(GameFontNormal:GetFont(), 12, "")
						hLabel:SetCallback("OnClick", function()
							Intern_Char[charKey].tracker.categoryCollapsed[categoryKey] =
								not Intern_Char[charKey].tracker.categoryCollapsed[categoryKey]
							Intern.RefreshTracker()
						end)
						trackerScroll:AddChild(hLabel)
						pendingHeader = nil
					end
					if pendingFactionHeader then
						local fLabel = AceGUI:Create("Label")
						fLabel:SetText("    |cffdddddd" .. pendingFactionHeader .. "|r")
						fLabel:SetFullWidth(true)
						fLabel:SetFont(GameFontNormal:GetFont(), 12, "")
						trackerScroll:AddChild(fLabel)
						pendingFactionHeader = nil
					end

					-- Flat sections (seasonal events) get less indent because there's
					-- no category sub-header to nest under. Reputation rows nest
					-- one extra level under the faction subheader.
					local indent = isFlat and "  " or (bucket.factionName and "      " or "    ")
					local heroicTag = (Intern.IsHeroicWanted and Intern.IsHeroicWanted(repQid))
						and "|cffff8000[H]|r " or ""
					local row  = AceGUI:Create("InteractiveLabel")
					row:SetText(indent .. (STATE_MARKER[state] or "") .. heroicTag .. (info.title or ""))
					row:SetFullWidth(true)
					row:SetFont(GameFontNormal:GetFont(), 12, "")
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
							-- Open the quest log to this quest (Questie-style).
							-- Anniversary's quest log frame might be exposed as
							-- ClassicQuestLog, QuestLogExFrame, or QuestLogFrame
							-- depending on which UI flavor / addon overlays are
							-- active — try the same fallback chain Questie uses.
							-- Only meaningful for quests actually in the log;
							-- "available" quests would open the log to nothing.
							if C_QuestLog.IsOnQuest(repQid) then
								local logIndex = (GetQuestLogIndexByID and GetQuestLogIndexByID(repQid))
									or (C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(repQid))
								if logIndex then
									if SelectQuestLogEntry then SelectQuestLogEntry(logIndex) end
									local questFrame = QuestLogExFrame or ClassicQuestLog or QuestLogFrame
									if questFrame and not questFrame:IsShown() and not InCombatLockdown() then
										ShowUIPanel(questFrame)
									end
									-- When the log is already open, SelectQuestLogEntry alone
									-- won't push the new selection through to the visible UI:
									--   QuestLog_UpdateQuestDetails redraws the right-hand
									--     detail pane (objectives + reward).
									--   QuestLog_Update redraws the left-hand list selection.
									-- Need both — Questie does the same.
									if QuestLog_UpdateQuestDetails then QuestLog_UpdateQuestDetails() end
									if QuestLog_Update             then QuestLog_Update()             end
									-- Scroll the left-hand list so the highlighted quest is
									-- actually visible (otherwise it just flips to the new
									-- selection off-screen). Questie uses this same formula:
									-- pin the entry ~3 rows from the top of the visible region.
									local scrollBar = (QuestLogListScrollFrame and QuestLogListScrollFrame.ScrollBar)
										or QuestLogListScrollFrameScrollBar
									if scrollBar and scrollBar.GetValueStep and scrollBar.SetValue then
										local step = scrollBar:GetValueStep() or 0
										if step > 0 then
											scrollBar:SetValue(logIndex * step - step * 3)
										end
									end
								end
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
				end -- inner: for _, group in ipairs(bucket.groups)
			end -- outer: for _, bucket in ipairs(factionBuckets)
			end -- else (categoryCollapsed branch)
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
			sLabel:SetFont(GameFontNormal:GetFont(), 14, "")
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
				row:SetFont(GameFontNormal:GetFont(), 12, "")
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
		empty:SetFont(GameFontNormal:GetFont(), 12, "")
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
