-- portal_mage/farm.lua — farm plot helpers (empty soil highlight)
--
-- Hierarchy (from dumps):
--   Workspace.FarmSoils_Plot{N}.soil_{id}
--     └── CropPlaceholder
--           └── {Crop}_{Stage}   e.g. Carrot_Mature, Tomato_Seed, MagicBerry_Sprout
--                 └── CropInfo
--
-- Empty = no generic plant entity under CropPlaceholder (any non-info child).
return function(S)
	local C = S.Config
	local U = S.Util
	local M = {}

	local HL_NAME = "PortalMage_EmptySoilHL"
	local MAINTAIN = 0.6

	local function setStatus(t: string)
		if U and U.setStatus then
			U.setStatus(t)
		end
	end

	local function refreshLabel()
		if S.ui and S.ui.setEmptyPlotLabel then
			S.ui.setEmptyPlotLabel(S.farmEmptyHighlightEnabled == true)
		end
	end

	---------------------------------------------------------------------------
	-- Plant detection (generic — not a crop name whitelist)
	---------------------------------------------------------------------------

	-- True if this instance looks like a planted crop / plant (not metadata/VFX-only).
	function M.isPlantEntity(inst: Instance): boolean
		if not inst or not inst.Parent then
			return false
		end
		local n = string.lower(inst.Name)
		-- Metadata / container only
		if n == "cropinfo" or n == "cropplaceholder" or n == "crop" then
			return false
		end
		-- Harvest pickups are not a growing plant (tile free-ish for logic? keep as occupied)
		-- User asked "plant on it" — treat Harvest_* as NOT a plant so empty after harvest highlights.
		if string.find(n, "harvest", 1, true) == 1 then
			return false
		end
		-- Pure VFX / attachments rarely sit as sole CropPlaceholder children
		if inst:IsA("BillboardGui")
			or inst:IsA("ParticleEmitter")
			or inst:IsA("Attachment")
			or inst:IsA("Highlight")
			or inst:IsA("SelectionBox")
		then
			return false
		end
		-- Any Model / BasePart / Folder under the placeholder is a plant stage
		if inst:IsA("Model") or inst:IsA("BasePart") or inst:IsA("Folder") then
			return true
		end
		return false
	end

	function M.soilHasPlant(soil: Instance): boolean
		if not soil then
			return false
		end
		local ph = soil:FindFirstChild("CropPlaceholder")
		if not ph then
			-- Fallback: plant as direct child of soil
			for _, ch in ipairs(soil:GetChildren()) do
				if M.isPlantEntity(ch) then
					return true
				end
			end
			return false
		end
		-- Direct children of CropPlaceholder are crop stages (Carrot_Mature, etc.)
		for _, ch in ipairs(ph:GetChildren()) do
			if M.isPlantEntity(ch) then
				return true
			end
		end
		return false
	end

	function M.getSoilPart(soil: Instance): BasePart?
		if soil:IsA("BasePart") then
			return soil
		end
		if soil:IsA("Model") then
			local m = soil :: Model
			if m.PrimaryPart then
				return m.PrimaryPart
			end
		end
		local best: BasePart? = nil
		local bestVol = 0
		for _, d in ipairs(soil:GetDescendants()) do
			if d:IsA("BasePart") then
				local vol = d.Size.X * d.Size.Y * d.Size.Z
				if vol > bestVol then
					bestVol = vol
					best = d
				end
			end
		end
		return best
	end

	---------------------------------------------------------------------------
	-- Scan FarmSoils_Plot* soils
	---------------------------------------------------------------------------

	function M.collectSoils(): { Instance }
		local list = {}
		for _, child in ipairs(workspace:GetChildren()) do
			local name = child.Name
			if string.find(name, "FarmSoils_Plot", 1, true) == 1 then
				for _, soil in ipairs(child:GetChildren()) do
					local sn = string.lower(soil.Name)
					if string.find(sn, "soil", 1, true) == 1
						or soil:FindFirstChild("CropPlaceholder")
					then
						table.insert(list, soil)
					end
				end
			end
		end
		return list
	end

	function M.scanEmptySoils(): ({ Instance }, number, number)
		local soils = M.collectSoils()
		local empty = {}
		local planted = 0
		for _, soil in ipairs(soils) do
			if M.soilHasPlant(soil) then
				planted += 1
			else
				table.insert(empty, soil)
			end
		end
		return empty, #soils, planted
	end

	---------------------------------------------------------------------------
	-- Highlights
	---------------------------------------------------------------------------

	local function destroyHighlightOn(inst: Instance)
		local h = inst:FindFirstChild(HL_NAME)
		if h then
			h:Destroy()
		end
		-- Also on primary part
		local part = M.getSoilPart(inst)
		if part and part ~= inst then
			local h2 = part:FindFirstChild(HL_NAME)
			if h2 then
				h2:Destroy()
			end
		end
	end

	function M.clearAllHighlights()
		for _, soil in ipairs(M.collectSoils()) do
			destroyHighlightOn(soil)
		end
		-- Orphans from prior sessions
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == HL_NAME then
				d:Destroy()
			end
		end
	end

	function M.ensureHighlight(soil: Instance)
		local part = M.getSoilPart(soil)
		if not part then
			return
		end
		local host: Instance = part
		local h = host:FindFirstChild(HL_NAME)
		if not (h and h:IsA("Highlight")) then
			if h then
				h:Destroy()
			end
			h = Instance.new("Highlight")
			h.Name = HL_NAME
			h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			h.Parent = host
		end
		local hl = h :: Highlight
		hl.Adornee = part
		hl.Enabled = true
		hl.FillColor = C.FARM_EMPTY_HL_FILL or Color3.fromRGB(255, 90, 40)
		hl.OutlineColor = C.FARM_EMPTY_HL_OUTLINE or Color3.fromRGB(255, 220, 80)
		hl.FillTransparency = C.FARM_EMPTY_HL_FILL_T or 0.55
		hl.OutlineTransparency = C.FARM_EMPTY_HL_OUTLINE_T or 0.15
	end

	function M.refreshHighlights(): (number, number, number)
		local empty, total, planted = M.scanEmptySoils()
		local emptySet: { [Instance]: boolean } = {}
		for _, soil in ipairs(empty) do
			emptySet[soil] = true
			M.ensureHighlight(soil)
		end
		for _, soil in ipairs(M.collectSoils()) do
			if not emptySet[soil] then
				destroyHighlightOn(soil)
			end
		end
		return #empty, total, planted
	end

	---------------------------------------------------------------------------
	-- Toggle / maintain
	---------------------------------------------------------------------------

	local function maintainLoop()
		while S.farmEmptyHighlightEnabled do
			pcall(function()
				M.refreshHighlights()
			end)
			task.wait(C.FARM_EMPTY_HL_INTERVAL or MAINTAIN)
		end
		S.farmEmptyHighlightThread = nil
	end

	function M.setEmptyHighlightEnabled(on: boolean)
		S.farmEmptyHighlightEnabled = on and true or false
		refreshLabel()
		if S.farmEmptyHighlightEnabled then
			local nEmpty, nTotal, nPlanted = M.refreshHighlights()
			setStatus(string.format(
				"Empty Plot HL ON — empty=%d planted=%d total=%d",
				nEmpty,
				nPlanted,
				nTotal
			))
			if not S.farmEmptyHighlightThread then
				S.farmEmptyHighlightThread = task.spawn(maintainLoop)
			end
		else
			M.clearAllHighlights()
			setStatus("Empty Plot HL OFF")
		end
	end

	function M.toggleEmptyHighlight()
		M.setEmptyHighlightEnabled(not S.farmEmptyHighlightEnabled)
	end

	return M
end
