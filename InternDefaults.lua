-- The default tracked set on a fresh install is computed at runtime by walking
-- Intern_Quests and selecting entries whose phase matches Intern_CurrentPhase[expac].
-- Bump these numbers when the realm advances to the next content phase.
Intern_CurrentPhase = {
	[2] = 1,  -- TBC: Phase 1 (Anniversary launch content)
	[3] = 1,  -- WotLK: phase 1 placeholder
	[4] = 1,  -- Cataclysm: phase 1 placeholder
}
