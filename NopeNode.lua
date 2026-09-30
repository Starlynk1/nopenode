-- Colors gathering node names on the minimap blip tooltip.
-- The blip line is an arrow texture plus the node name, so the name has to be
-- found inside that line and the difficulty color written into the text.
-- World-object hover uses GetWorldCursor and is left alone.

local ADDON_NAME = "NopeNode"
local Nodes = NopeNode_Nodes
NopeNode_Nodes = nil

local ORANGE_SPAN = 25
local YELLOW_SPAN = 50
local GREEN_SPAN = 100

local skills = {
	herb = 0,
	mine = 0,
}

local registered = false

local function Rgb(color, fallbackR, fallbackG, fallbackB)
	if color and color.GetRGB then
		return color:GetRGB()
	end
	return fallbackR, fallbackG, fallbackB
end

local function RefreshSkills()
	skills.herb = 0
	skills.mine = 0

	local wanted = {}
	if C_TradeSkillUI and C_TradeSkillUI.GetProfessionSkillLineID and Enum and Enum.Profession then
		local herbID = C_TradeSkillUI.GetProfessionSkillLineID(Enum.Profession.Herbalism)
		local mineID = C_TradeSkillUI.GetProfessionSkillLineID(Enum.Profession.Mining)
		if herbID and herbID > 0 then
			wanted[herbID] = "herb"
		end
		if mineID and mineID > 0 then
			wanted[mineID] = "mine"
		end
	end

	if not C_SkillInfo or not C_SkillInfo.GetNumSkillLines then
		return
	end

	for index = 1, C_SkillInfo.GetNumSkillLines() do
		local info = C_SkillInfo.GetSkillLineInfo(index)
		if info and not info.isHeader and info.name then
			local kind = wanted[info.skillID]
			if not kind then
				local name = info.name:lower()
				if name == "herbalism" then
					kind = "herb"
				elseif name == "mining" then
					kind = "mine"
				end
			end
			if kind then
				skills[kind] = (info.rank or 0) + (info.modifier or 0)
			end
		end
	end
end

local function ColorFor(node)
	local skill = skills[node.kind] or 0
	if skill < node.required then
		return Rgb(IMPOSSIBLE_DIFFICULTY_COLOR, 1, 0.1, 0.1)
	end

	local over = skill - node.required
	if over < ORANGE_SPAN then
		return Rgb(DIFFICULT_DIFFICULTY_COLOR, 1, 0.5, 0.25)
	elseif over < YELLOW_SPAN then
		return Rgb(FAIR_DIFFICULTY_COLOR, 1, 1, 0)
	elseif over < GREEN_SPAN then
		return Rgb(EASY_DIFFICULTY_COLOR, 0.25, 0.75, 0.25)
	end
	return Rgb(TRIVIAL_DIFFICULTY_COLOR, 0.5, 0.5, 0.5)
end

local function MouseIsOverMinimap()
	return Minimap and Minimap.IsMouseOver and Minimap:IsMouseOver()
end

local painting = false

local function NormalRgb()
	return Rgb(NORMAL_FONT_COLOR, 1, 0.82, 0)
end

-- Skip tooltip escape sequences so a search cannot match inside an icon path
-- or an existing color code.
local function PlainParts(text)
	local chars = {}
	local positions = {}
	local i = 1
	local limit = #text
	while i <= limit do
		if text:byte(i) == 124 then
			local kind = text:sub(i + 1, i + 1)
			if kind == "c" then
				i = i + 10
			elseif kind == "r" or kind == "R" then
				i = i + 2
			elseif kind == "T" then
				local _, closeAt = text:find("|t", i, true)
				i = closeAt and (closeAt + 1) or (i + 2)
			elseif kind == "A" then
				local _, closeAt = text:find("|a", i, true)
				i = closeAt and (closeAt + 1) or (i + 2)
			elseif kind == "H" then
				local _, closeAt = text:find("|h", i, true)
				i = closeAt and (closeAt + 1) or (i + 2)
			else
				chars[#chars + 1] = text:sub(i, i):lower()
				positions[#positions + 1] = i
				i = i + 1
			end
		else
			chars[#chars + 1] = text:sub(i, i):lower()
			positions[#positions + 1] = i
			i = i + 1
		end
	end
	return table.concat(chars), positions
end

local function NodeRanges(text)
	local plain, positions = PlainParts(text)
	if plain == "" then
		return nil
	end
	local names = {}
	for nodeName in pairs(Nodes) do
		names[#names + 1] = nodeName
	end
	table.sort(names, function(a, b)
		return #a > #b
	end)

	local used = {}
	local ranges = {}
	for _, nodeName in ipairs(names) do
		local key = nodeName:lower()
		local from = 1
		while true do
			local startPlain, endPlain = plain:find(key, from, true)
			if not startPlain then
				break
			end
			local overlaps = false
			for index = startPlain, endPlain do
				if used[index] then
					overlaps = true
					break
				end
			end
			if not overlaps then
				for index = startPlain, endPlain do
					used[index] = true
				end
				ranges[#ranges + 1] = {
					startPos = positions[startPlain],
					endPos = positions[endPlain],
					node = Nodes[nodeName],
					name = nodeName,
				}
			end
			from = endPlain + 1
		end
	end
	table.sort(ranges, function(a, b)
		return a.startPos < b.startPos
	end)
	return ranges
end

local function FirstNodeRange(text)
	local ranges = NodeRanges(text)
	if not ranges or #ranges == 0 then
		return nil
	end
	return ranges[1]
end

local function SplitAtNode(text, range)
	if not range.startPos or not range.endPos then
		return nil
	end
	local prefix = text:sub(1, range.startPos - 1)
	prefix = prefix:gsub("|c%x%x%x%x%x%x%x%x", "")
	prefix = prefix:gsub("|r", "")
	prefix = prefix:gsub("|R", "")
	local name = text:sub(range.startPos, range.endPos)
	local rest = text:sub(range.endPos + 1)
	rest = rest:gsub("|c%x%x%x%x%x%x%x%x", "")
	rest = rest:gsub("|r", "")
	rest = rest:gsub("|R", "")
	rest = rest:gsub("|T.-|t", "")
	rest = rest:match("^[%s\r\n]*(.-)[%s\r\n]*$") or ""
	return prefix .. name, rest
end

local function LaterLineHas(tooltip, startIndex, rest)
	local name = tooltip:GetName()
	local countOk, num = pcall(tooltip.NumLines, tooltip)
	if not countOk or not num then
		return false
	end
	local needle = rest:lower()
	for index = startIndex, num do
		local line = _G[name .. "TextLeft" .. index]
		if line then
			local textOk, text = pcall(line.GetText, line)
			if textOk and type(text) == "string" and text:lower():find(needle, 1, true) then
				return true
			end
		end
	end
	return false
end

-- SetTextColor paints every word on a line. Keep the node on its own line so
-- that color cannot reach the quest text.
local function PaintFontString(tooltip, line, lineIndex)
	if not line then
		return
	end
	local textOk, text = pcall(line.GetText, line)
	if not textOk or type(text) ~= "string" or text == "" then
		return
	end
	local rangeOk, range = pcall(FirstNodeRange, text)
	if not rangeOk or not range then
		return
	end

	local nodeText, rest = SplitAtNode(text, range)
	if not nodeText then
		return
	end
	local r, g, b = ColorFor(range.node)
	if line:GetText() ~= nodeText then
		line:SetText(nodeText)
	end
	line:SetTextColor(r, g, b)

	if rest == "" or LaterLineHas(tooltip, lineIndex + 1, rest) then
		return
	end

	local nr, ng, nb = NormalRgb()
	painting = true
	tooltip:AddLine(rest, nr, ng, nb, true)
	painting = false
end

local function PaintShownTooltip(tooltip)
	if not tooltip or not tooltip.IsShown or not tooltip.GetName then
		return
	end
	local shownOk, shown = pcall(tooltip.IsShown, tooltip)
	if not shownOk or not shown then
		return
	end
	local num = 1
	if tooltip.NumLines then
		local countOk, count = pcall(tooltip.NumLines, tooltip)
		if countOk and count and count > 1 then
			num = count
		end
	end
	if painting then
		return
	end
	local name = tooltip:GetName()
	for i = 1, num do
		PaintFontString(tooltip, _G[name .. "TextLeft" .. i], i)
	end
end

local function RegisterTooltipColors()
	if registered then
		return
	end
	if not GameTooltip or not hooksecurefunc then
		return
	end
	registered = true

	if GameTooltip.SetMinimapMouseover then
		hooksecurefunc(GameTooltip, "SetMinimapMouseover", PaintShownTooltip)
	end
	if GameTooltip.Show then
		hooksecurefunc(GameTooltip, "Show", function(tooltip)
			if MouseIsOverMinimap() then
				PaintShownTooltip(tooltip)
			end
		end)
	end
	if GameTooltip.AddLine then
		hooksecurefunc(GameTooltip, "AddLine", function(tooltip)
			if MouseIsOverMinimap() then
				PaintShownTooltip(tooltip)
			end
		end)
	end

	if Minimap and Minimap.HookScript then
		Minimap:HookScript("OnUpdate", function()
			if MouseIsOverMinimap() and GameTooltip then
				PaintShownTooltip(GameTooltip)
			end
		end)
	end
end

local driver = CreateFrame("Frame")
driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("SKILL_LINES_CHANGED")
driver:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 ~= ADDON_NAME then
		return
	end
	if event == "ADDON_LOADED" or event == "PLAYER_ENTERING_WORLD" then
		RegisterTooltipColors()
	end
	RefreshSkills()
end)
