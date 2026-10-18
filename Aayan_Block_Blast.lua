--[[
	AAYAN V3  |  BLOCK BLAST      (Roblox LocalScript, builds its GUI in PlayerGui)

	WHERE TO RUN
	  * Roblox Studio: StarterPlayer > StarterPlayerScripts > LocalScript (paste this file).
	    It must be a LocalScript, NOT a normal Script.
	  * Executor: run it as a client script; it parents itself to PlayerGui.

	HOW TO PLAY
	  1. Tap one of the 3 block shapes at the bottom (it gets highlighted).
	  2. PC: move the mouse over the board to see the preview, click to place.
	     Phone: tap a cell to see the preview, tap the SAME cell again to place
	     (tap another cell to move the preview).
	  3. A shape can only be placed if every cell is inside the board and empty.
	     Green/cyan preview = valid, red = invalid. Gold glow = this move completes a line.
	  4. A full row or column clears (several at once = bigger bonus).
	  5. When all 3 shapes are used, 3 NEW random shapes appear immediately, forever.
	  6. When none of the current shapes fits anywhere -> GAME OVER. RESTART starts again.
	  The round button on the left opens / hides the window - drag it anywhere.
	  Drag the window by its title bar. "–" minimizes, "✕" hides.

	SCORING   +1 per placed cell, clear bonus 10 x lines x lines, +5 per extra combo move in a row.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local GUI_NAME = "AayanBlockBlast"

--==================================================
-- CLEAN UP A PREVIOUS RUN
--==================================================
if typeof(_G.AayanBlockBlast_Cleanup) == "function" then
	pcall(_G.AayanBlockBlast_Cleanup)
end
do
	local old = playerGui:FindFirstChild(GUI_NAME)
	if old then old:Destroy() end
end

local alive = true
local connections = {}
local function bind(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

--==================================================
-- GAME LOGIC (pure Lua - no GUI, no Roblox APIs)
--==================================================
--[[LOGIC_BEGIN]]
local Logic = {}
Logic.SIZE = 10
Logic.HAND = 3

-- shape families: each entry = { weight, colorIndex, { pattern, pattern, ... } }
-- a pattern is a list of strings, "X" = filled cell
local FAMILIES = {
	{ 0.7, 1, { { "X" } } },                                                         -- single block
	{ 1.0, 2, { { "XX" }, { "X", "X" } } },                                          -- 1x2 line
	{ 1.0, 3, { { "XXX" }, { "X", "X", "X" } } },                                    -- 1x3 line
	{ 0.9, 4, { { "XXXX" }, { "X", "X", "X", "X" } } },                              -- 1x4 line
	{ 0.6, 5, { { "XXXXX" }, { "X", "X", "X", "X", "X" } } },                        -- 1x5 line
	{ 1.0, 6, { { "XX", "XX" } } },                                                  -- 2x2 square
	{ 0.5, 7, { { "XXX", "XXX", "XXX" } } },                                         -- 3x3 square
	{ 0.8, 2, { { "XXX", "XXX" }, { "XX", "XX", "XX" } } },                          -- 2x3 block
	{ 1.0, 1, { { "X.", "XX" }, { ".X", "XX" }, { "XX", "X." }, { "XX", ".X" } } },  -- small L
	{ 1.0, 3, { { "X.", "X.", "XX" }, { ".X", ".X", "XX" }, { "XX", "X.", "X." }, { "XX", ".X", ".X" },
		{ "XXX", "X.." }, { "XXX", "..X" }, { "X..", "XXX" }, { "..X", "XXX" } } },  -- L / J
	{ 0.6, 5, { { "X..", "X..", "XXX" }, { "..X", "..X", "XXX" }, { "XXX", "X..", "X.." }, { "XXX", "..X", "..X" } } }, -- big L
	{ 1.0, 4, { { "XXX", ".X." }, { ".X.", "XXX" }, { "X.", "XX", "X." }, { ".X", "XX", ".X" } } }, -- T
	{ 1.0, 6, { { "XX.", ".XX" }, { ".XX", "XX." }, { ".X", "XX", "X." }, { "X.", "XX", ".X" } } }, -- Z / S zigzag
}

Logic.SHAPES = {}
do
	for _, fam in ipairs(FAMILIES) do
		for _, pattern in ipairs(fam[3]) do
			local cells = {}
			local w = 0
			for r, row in ipairs(pattern) do
				for c = 1, #row do
					if string.sub(row, c, c) == "X" then
						cells[#cells + 1] = { r - 1, c - 1 }
						if c > w then w = c end
					end
				end
			end
			Logic.SHAPES[#Logic.SHAPES + 1] = {
				cells = cells, h = #pattern, w = w, color = fam[2], weight = fam[1] / #fam[3], count = #cells,
			}
		end
	end
end

function Logic.newBoard()
	local b = {}
	for r = 1, Logic.SIZE do
		b[r] = {}
		for c = 1, Logic.SIZE do b[r][c] = 0 end
	end
	return b
end

-- r, c = board cell (1-based) where the shape's top-left corner goes
function Logic.canPlace(board, shape, r, c)
	for _, cell in ipairs(shape.cells) do
		local rr, cc = r + cell[1], c + cell[2]
		if rr < 1 or rr > Logic.SIZE or cc < 1 or cc > Logic.SIZE then return false end
		if board[rr][cc] ~= 0 then return false end
	end
	return true
end

function Logic.place(board, shape, r, c)
	for _, cell in ipairs(shape.cells) do
		board[r + cell[1]][c + cell[2]] = shape.color
	end
end

-- complete rows / columns (as lists of indices)
function Logic.findFull(board)
	local rows, cols = {}, {}
	for r = 1, Logic.SIZE do
		local full = true
		for c = 1, Logic.SIZE do
			if board[r][c] == 0 then full = false; break end
		end
		if full then rows[#rows + 1] = r end
	end
	for c = 1, Logic.SIZE do
		local full = true
		for r = 1, Logic.SIZE do
			if board[r][c] == 0 then full = false; break end
		end
		if full then cols[#cols + 1] = c end
	end
	return rows, cols
end

-- empties the given rows/columns; returns the list of cleared cells { r, c, color }
function Logic.clearLines(board, rows, cols)
	local marked, out = {}, {}
	local function mark(r, c)
		local key = r * 100 + c
		if not marked[key] then
			marked[key] = true
			out[#out + 1] = { r, c, board[r][c] }
		end
	end
	for _, r in ipairs(rows) do
		for c = 1, Logic.SIZE do mark(r, c) end
	end
	for _, c in ipairs(cols) do
		for r = 1, Logic.SIZE do mark(r, c) end
	end
	for _, cell in ipairs(out) do board[cell[1]][cell[2]] = 0 end
	return out
end

function Logic.fitsAnywhere(board, shape)
	for r = 1, Logic.SIZE - shape.h + 1 do
		for c = 1, Logic.SIZE - shape.w + 1 do
			if Logic.canPlace(board, shape, r, c) then return true, r, c end
		end
	end
	return false
end

-- is any of the (non-nil) shapes in the hand placeable somewhere?
function Logic.anyFits(board, hand)
	for i = 1, Logic.HAND do
		local s = hand[i]
		if s and Logic.fitsAnywhere(board, s) then return true end
	end
	return false
end

local function pickWeighted(rng)
	local total = 0
	for _, s in ipairs(Logic.SHAPES) do total = total + s.weight end
	local x = rng() * total
	for _, s in ipairs(Logic.SHAPES) do
		x = x - s.weight
		if x <= 0 then return s end
	end
	return Logic.SHAPES[#Logic.SHAPES]
end

-- 3 new random shapes. Tries a few times so the hand is not instantly unplayable on an open board
-- (if the board is genuinely too full, the last random hand is used and the game can end).
function Logic.generate(board, rng)
	rng = rng or math.random
	local hand
	for _ = 1, 25 do
		hand = {}
		for i = 1, Logic.HAND do hand[i] = pickWeighted(rng) end
		if Logic.anyFits(board, hand) then return hand end
	end
	return hand
end

-- points for one move
function Logic.moveScore(cellCount, linesCleared, combo)
	local bonus = 0
	if linesCleared > 0 then
		bonus = 10 * linesCleared * linesCleared + 5 * math.max(0, combo - 1)
	end
	return cellCount + bonus, bonus
end
--[[LOGIC_END]]

--==================================================
-- BEST SCORE STORAGE
--==================================================
local SAVE_FILE = "AayanBlockBlast_best.json"
local best = tonumber(_G.AayanBlockBlast_Best) or 0
do
	local ok, data = pcall(function()
		if typeof(isfile) == "function" and typeof(readfile) == "function" and isfile(SAVE_FILE) then
			return HttpService:JSONDecode(readfile(SAVE_FILE))
		end
	end)
	if ok and typeof(data) == "table" then best = math.max(best, tonumber(data.best) or 0) end
end
local function saveBest()
	_G.AayanBlockBlast_Best = best
	pcall(function()
		if typeof(writefile) == "function" then
			writefile(SAVE_FILE, HttpService:JSONEncode({ best = best }))
		end
	end)
end

--==================================================
-- THEME + GUI HELPERS
--==================================================
local C = {
	bg = Color3.fromRGB(2, 2, 6),
	panel = Color3.fromRGB(12, 10, 26),
	panel2 = Color3.fromRGB(22, 18, 46),
	hover = Color3.fromRGB(40, 32, 84),
	cyan = Color3.fromRGB(0, 235, 255),
	purple = Color3.fromRGB(170, 85, 255),
	text = Color3.fromRGB(238, 240, 255),
	muted = Color3.fromRGB(140, 140, 185),
	red = Color3.fromRGB(255, 70, 95),
	gold = Color3.fromRGB(255, 212, 90),
	green = Color3.fromRGB(70, 240, 160),
}

-- realistic gem-like block colours
local BLOCK_COLORS = {
	Color3.fromRGB(0, 205, 255),
	Color3.fromRGB(160, 90, 255),
	Color3.fromRGB(70, 125, 255),
	Color3.fromRGB(255, 85, 185),
	Color3.fromRGB(255, 145, 45),
	Color3.fromRGB(50, 225, 135),
	Color3.fromRGB(255, 210, 60),
}

local function tween(obj, t, props, style, dir)
	local tw = TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function corner(p, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = p
	return c
end

local function gradient(p, rot, c0, c1)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(c0 or C.cyan, c1 or C.purple)
	g.Rotation = rot or 0
	g.Parent = p
	return g
end

local function stroke(p, thick, transp, c0, c1)
	local s = Instance.new("UIStroke")
	s.Thickness = thick or 1
	s.Transparency = transp or 0
	s.Color = Color3.new(1, 1, 1)
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = p
	local g = gradient(s, 0, c0, c1)
	return s, g
end

local function frame(parent, pos, size, color)
	local f = Instance.new("Frame")
	f.Position = pos or UDim2.new()
	f.Size = size or UDim2.new(1, 0, 1, 0)
	f.BackgroundColor3 = color or C.panel
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function label(parent, text, size, color, font, xalign)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextSize = size
	l.TextColor3 = color or C.text
	l.Font = font or Enum.Font.GothamMedium
	l.TextXAlignment = xalign or Enum.TextXAlignment.Center
	l.Parent = parent
	return l
end

local function button(parent, text, pos, size, textSize, callback)
	local b = Instance.new("TextButton")
	b.Position = pos
	b.Size = size
	b.BackgroundColor3 = C.panel2
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.Text = text
	b.TextColor3 = C.text
	b.TextSize = textSize or 13
	b.Font = Enum.Font.GothamBold
	b.Parent = parent
	corner(b, 9)
	local s = stroke(b, 1.2, 0.5)
	local sc = Instance.new("UIScale", b)
	bind(b.MouseEnter, function()
		tween(b, 0.15, { BackgroundColor3 = C.hover })
		tween(s, 0.15, { Transparency = 0 })
	end)
	bind(b.MouseLeave, function()
		tween(b, 0.15, { BackgroundColor3 = C.panel2 })
		tween(s, 0.15, { Transparency = 0.5 })
		tween(sc, 0.12, { Scale = 1 })
	end)
	bind(b.MouseButton1Down, function() tween(sc, 0.07, { Scale = 0.94 }) end)
	bind(b.MouseButton1Up, function() tween(sc, 0.14, { Scale = 1 }, Enum.EasingStyle.Back) end)
	if callback then bind(b.MouseButton1Click, callback) end
	return b
end

local function shadeColor(c, k)
	if k <= 1 then
		return Color3.new(c.R * k, c.G * k, c.B * k)
	end
	return c:Lerp(Color3.new(1, 1, 1), k - 1)
end

--==================================================
-- BLOCK TILE (realistic: gradient body, bevel ring, gloss, glint, edge shadow)
--==================================================
local function makeTile(parent, radius)
	local t = {}
	local base = Instance.new("Frame")
	base.BackgroundColor3 = Color3.new(1, 1, 1)
	base.BorderSizePixel = 0
	base.Parent = parent
	corner(base, radius)
	t.base = base
	t.grad = Instance.new("UIGradient")
	t.grad.Rotation = 90
	t.grad.Parent = base
	t.edge = Instance.new("UIStroke")
	t.edge.Thickness = 1.2
	t.edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	t.edge.Parent = base

	-- inner bevel ring
	local inner = Instance.new("Frame")
	inner.Position = UDim2.new(0, 2, 0, 2)
	inner.Size = UDim2.new(1, -4, 1, -4)
	inner.BackgroundTransparency = 1
	inner.BorderSizePixel = 0
	inner.Parent = base
	corner(inner, math.max(radius - 1, 1))
	local ring = Instance.new("UIStroke")
	ring.Color = Color3.new(1, 1, 1)
	ring.Transparency = 0.72
	ring.Thickness = 1
	ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ring.Parent = inner

	-- gloss on the upper half (fades out downwards)
	local shine = Instance.new("Frame")
	shine.Position = UDim2.new(0, 3, 0, 3)
	shine.Size = UDim2.new(1, -6, 0.45, 0)
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BorderSizePixel = 0
	shine.Parent = base
	corner(shine, math.max(radius - 1, 1))
	local sg = Instance.new("UIGradient")
	sg.Rotation = 90
	sg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.42),
		NumberSequenceKeypoint.new(1, 1),
	})
	sg.Parent = shine

	-- small specular glint
	local glint = Instance.new("Frame")
	glint.Position = UDim2.new(0.14, 0, 0.12, 0)
	glint.Size = UDim2.new(0.26, 0, 0.14, 0)
	glint.BackgroundColor3 = Color3.new(1, 1, 1)
	glint.BackgroundTransparency = 0.3
	glint.BorderSizePixel = 0
	glint.Parent = base
	corner(glint, 99)

	-- white flash used by the clear animation
	t.flash = Instance.new("Frame")
	t.flash.Size = UDim2.new(1, 0, 1, 0)
	t.flash.BackgroundColor3 = Color3.new(1, 1, 1)
	t.flash.BackgroundTransparency = 1
	t.flash.BorderSizePixel = 0
	t.flash.ZIndex = 3
	t.flash.Parent = base
	corner(t.flash, radius)

	t.scale = Instance.new("UIScale", base)
	return t
end

local function paintTile(t, colorIdx)
	local c = BLOCK_COLORS[colorIdx] or BLOCK_COLORS[1]
	t.grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, shadeColor(c, 1.3)),
		ColorSequenceKeypoint.new(0.5, c),
		ColorSequenceKeypoint.new(1, shadeColor(c, 0.55)),
	})
	t.edge.Color = shadeColor(c, 0.4)
end

--==================================================
-- GUI LAYOUT
--==================================================
local CELL, GAP, PAD = 26, 2, 6
local N = Logic.SIZE
local BOARD_PX = N * CELL + (N - 1) * GAP + PAD * 2 -- 290

local WIDTH = BOARD_PX + 20
local HEADER_H = 44
local SCORE_Y = HEADER_H + 6
local BOARD_Y = SCORE_Y + 54
local TRAY_Y = BOARD_Y + BOARD_PX + 8
local TRAY_H = 82
local HINT_Y = TRAY_Y + TRAY_H + 4
local ACT_Y = HINT_Y + 18
local HEIGHT = ACT_Y + 34 + 10

local ui = {}

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 90
gui.Parent = playerGui

local main = Instance.new("CanvasGroup")
main.Name = "Main"
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.Position = UDim2.new(0.5, 0, 0.5, 0)
main.Size = UDim2.new(0, WIDTH, 0, HEIGHT)
main.BackgroundColor3 = C.bg
main.BorderSizePixel = 0
main.GroupTransparency = 1
main.Visible = false
main.Parent = gui
corner(main, 20)
local _, mainStrokeGrad = stroke(main, 2, 0)
do
	local glow = Instance.new("UIStroke")
	glow.Thickness = 9
	glow.Transparency = 0.84
	glow.Color = Color3.new(1, 1, 1)
	glow.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	glow.Parent = main
	gradient(glow, 45)
end
local mainScale = Instance.new("UIScale", main)

local bgFill = frame(main, UDim2.new(), UDim2.new(1, 0, 1, 0), Color3.new(1, 1, 1))
bgFill.ZIndex = 0
gradient(bgFill, 80, Color3.fromRGB(14, 6, 30), Color3.fromRGB(0, 0, 0))

-- title bar -----------------------------------------------------------------
local header = frame(main, UDim2.new(), UDim2.new(1, 0, 0, HEADER_H), C.panel)
header.BackgroundTransparency = 0.35
local titleL = label(header, "AAYAN V3  |  BLOCK BLAST", 14, C.text, Enum.Font.GothamBlack, Enum.TextXAlignment.Left)
titleL.Position = UDim2.new(0, 14, 0, 0)
titleL.Size = UDim2.new(1, -90, 1, 0)
gradient(titleL, 0)
local dragHandle = Instance.new("TextButton")
dragHandle.Name = "DragHandle"
dragHandle.BackgroundTransparency = 1
dragHandle.Text = ""
dragHandle.Size = UDim2.new(1, -76, 1, 0)
dragHandle.Parent = header
local minBtn = button(header, "–", UDim2.new(1, -70, 0.5, -12), UDim2.new(0, 28, 0, 24), 16)
local closeBtn = button(header, "✕", UDim2.new(1, -38, 0.5, -12), UDim2.new(0, 28, 0, 24), 13)

-- body (hidden when minimized)
local body = frame(main, UDim2.new(0, 0, 0, HEADER_H), UDim2.new(1, 0, 1, -HEADER_H), C.bg)
body.BackgroundTransparency = 1
local function at(y) return y - HEADER_H end

-- score cards: LINES | SCORE (big) | BEST -------------------------------------
local scoreRow = frame(body, UDim2.new(0, 10, 0, at(SCORE_Y)), UDim2.new(1, -20, 0, 48), C.bg)
scoreRow.BackgroundTransparency = 1
local function card(pos, size, title, big)
	local f = frame(scoreRow, pos, size, C.panel)
	f.BackgroundTransparency = 0.2
	corner(f, 12)
	stroke(f, 1.2, big and 0.15 or 0.5)
	local t = label(f, title, 9, C.muted, Enum.Font.GothamBold)
	t.Position = UDim2.new(0, 0, 0, 4)
	t.Size = UDim2.new(1, 0, 0, 11)
	local v = label(f, "0", big and 24 or 17, big and C.cyan or C.text, Enum.Font.GothamBlack)
	v.Position = UDim2.new(0, 0, 0, 15)
	v.Size = UDim2.new(1, 0, 0, big and 30 or 26)
	local sc = Instance.new("UIScale", v)
	return v, sc
end
ui.linesV = card(UDim2.new(0, 0, 0, 0), UDim2.new(0.28, -3, 1, 0), "LINES", false)
ui.scoreV, ui.scoreScale = card(UDim2.new(0.28, 1, 0, 0), UDim2.new(0.44, -2, 1, 0), "SCORE", true)
ui.bestV = card(UDim2.new(0.72, 3, 0, 0), UDim2.new(0.28, -3, 1, 0), "BEST", false)

-- board ---------------------------------------------------------------------
local boardPanel = frame(body, UDim2.new(0, 10, 0, at(BOARD_Y)), UDim2.new(0, BOARD_PX, 0, BOARD_PX), C.panel)
boardPanel.BackgroundTransparency = 0.1
corner(boardPanel, 14)
local _, boardStrokeGrad = stroke(boardPanel, 2, 0.1)
local boardScale = Instance.new("UIScale", boardPanel)

local cells = {} -- cells[r][c] = { empty, tile, hint, ghost, hit, anim }
for r = 1, N do
	cells[r] = {}
	for c = 1, N do
		local x = PAD + (c - 1) * (CELL + GAP)
		local y = PAD + (r - 1) * (CELL + GAP)
		local holder = frame(boardPanel, UDim2.new(0, x, 0, y), UDim2.new(0, CELL, 0, CELL), C.bg)
		holder.BackgroundTransparency = 1
		-- empty slot: recessed look
		local empty = frame(holder, UDim2.new(), UDim2.new(1, 0, 1, 0), Color3.fromRGB(30, 26, 58))
		corner(empty, 5)
		gradient(empty, 90, Color3.fromRGB(16, 13, 34), Color3.fromRGB(34, 29, 66))
		local es = Instance.new("UIStroke")
		es.Color = Color3.fromRGB(60, 52, 110)
		es.Transparency = 0.55
		es.Thickness = 1
		es.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		es.Parent = empty

		local tile = makeTile(holder, 5)
		tile.base.Size = UDim2.new(1, 0, 1, 0)
		tile.base.Visible = false

		local hint = frame(holder, UDim2.new(), UDim2.new(1, 0, 1, 0), C.gold)
		hint.BackgroundTransparency = 1
		hint.ZIndex = 4
		corner(hint, 5)
		local hs = Instance.new("UIStroke")
		hs.Color = C.gold
		hs.Thickness = 2
		hs.Transparency = 1
		hs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		hs.Parent = hint

		local ghost = frame(holder, UDim2.new(), UDim2.new(1, 0, 1, 0), C.cyan)
		ghost.BackgroundTransparency = 1
		ghost.ZIndex = 5
		corner(ghost, 5)
		local gs = Instance.new("UIStroke")
		gs.Color = C.cyan
		gs.Thickness = 1.5
		gs.Transparency = 1
		gs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		gs.Parent = ghost

		local hit = Instance.new("TextButton")
		hit.Size = UDim2.new(1, 0, 1, 0)
		hit.BackgroundTransparency = 1
		hit.Text = ""
		hit.AutoButtonColor = false
		hit.ZIndex = 8
		hit.Parent = holder

		cells[r][c] = {
			holder = holder, empty = empty, tile = tile, hint = hint, hintStroke = hs,
			ghost = ghost, ghostStroke = gs, hit = hit, anim = 0,
		}
	end
end

-- tray (3 shapes) -----------------------------------------------------------
local tray = frame(body, UDim2.new(0, 10, 0, at(TRAY_Y)), UDim2.new(0, BOARD_PX, 0, TRAY_H), C.bg)
tray.BackgroundTransparency = 1
local slots = {}
local MINI_MAX = 25
for i = 1, Logic.HAND do
	local s = {}
	s.frame = frame(tray, UDim2.new((i - 1) / 3, (i == 1) and 0 or 2, 0, 0), UDim2.new(1 / 3, (i == 2) and -4 or -2, 1, 0), C.panel)
	s.frame.BackgroundTransparency = 0.15
	corner(s.frame, 14)
	s.stroke = Instance.new("UIStroke")
	s.stroke.Color = Color3.fromRGB(90, 80, 160)
	s.stroke.Thickness = 1.5
	s.stroke.Transparency = 0.4
	s.stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.stroke.Parent = s.frame
	s.holder = frame(s.frame, UDim2.new(), UDim2.new(1, 0, 1, 0), C.bg)
	s.holder.BackgroundTransparency = 1
	s.tiles = {}
	for k = 1, MINI_MAX do
		local t = makeTile(s.holder, 4)
		t.base.Visible = false
		s.tiles[k] = t
	end
	s.scale = Instance.new("UIScale", s.frame)
	s.hit = Instance.new("TextButton")
	s.hit.Size = UDim2.new(1, 0, 1, 0)
	s.hit.BackgroundTransparency = 1
	s.hit.Text = ""
	s.hit.ZIndex = 10
	s.hit.Parent = s.frame
	slots[i] = s
end

-- hint line + actions ------------------------------------------------------
ui.hint = label(body, "Select a block, then tap the board", 11, C.muted, Enum.Font.GothamBold)
ui.hint.Position = UDim2.new(0, 10, 0, at(HINT_Y))
ui.hint.Size = UDim2.new(1, -20, 0, 16)
local restartBtn = button(body, "↻   RESTART", UDim2.new(0, 10, 0, at(ACT_Y)), UDim2.new(1, -20, 0, 34), 14)

-- floating text (line clear message) -----------------------------------------
local popL = label(body, "", 22, C.gold, Enum.Font.GothamBlack)
popL.AnchorPoint = Vector2.new(0.5, 0.5)
popL.Position = UDim2.new(0.5, 0, 0, at(BOARD_Y) + BOARD_PX / 2)
popL.Size = UDim2.new(0, 240, 0, 40)
popL.TextTransparency = 1
popL.TextStrokeTransparency = 1
popL.TextStrokeColor3 = Color3.new(0, 0, 0)
popL.ZIndex = 30
local popToken = 0

-- game over overlay ----------------------------------------------------------
local over = Instance.new("CanvasGroup")
over.Position = UDim2.new(0, 10, 0, at(BOARD_Y))
over.Size = UDim2.new(0, BOARD_PX, 0, BOARD_PX + 8 + TRAY_H)
over.BackgroundColor3 = Color3.fromRGB(4, 2, 12)
over.BackgroundTransparency = 0.08
over.BorderSizePixel = 0
over.ZIndex = 40
over.Visible = false
over.GroupTransparency = 1
over.Active = true
over.Parent = body
corner(over, 14)
local oTitle = label(over, "GAME OVER", 30, C.red, Enum.Font.GothamBlack)
oTitle.Position = UDim2.new(0, 0, 0, 46)
oTitle.Size = UDim2.new(1, 0, 0, 40)
local oSub = label(over, "No shape fits anymore", 12, C.muted, Enum.Font.GothamBold)
oSub.Position = UDim2.new(0, 0, 0, 88)
oSub.Size = UDim2.new(1, 0, 0, 16)
local oScore = label(over, "0", 50, C.cyan, Enum.Font.GothamBlack)
oScore.Position = UDim2.new(0, 0, 0, 110)
oScore.Size = UDim2.new(1, 0, 0, 58)
gradient(oScore, 0)
local oInfo = label(over, "", 12, C.text, Enum.Font.GothamBold)
oInfo.Position = UDim2.new(0, 0, 0, 172)
oInfo.Size = UDim2.new(1, 0, 0, 18)
local oNew = label(over, "★ NEW BEST! ★", 15, C.gold, Enum.Font.GothamBlack)
oNew.Position = UDim2.new(0, 0, 0, 194)
oNew.Size = UDim2.new(1, 0, 0, 20)
oNew.Visible = false
local oRestart = button(over, "▶   PLAY AGAIN", UDim2.new(0.5, -90, 0, 236), UDim2.new(0, 180, 0, 44), 15)

--==================================================
-- GAME STATE (board / hand are separate from the GUI)
--==================================================
local board = Logic.newBoard()
local hand = {}          -- hand[i] = shape or nil (used)
local selected = nil     -- selected slot index
local preview = nil      -- { r, c } top-left of the previewed placement
local score, lines, combo = 0, 0, 0
local isOver = false
local gameId = 0
local touchMode = false

--==================================================
-- RENDERING
--==================================================
local function setCellFilled(r, c, color, animate)
	local cell = cells[r][c]
	cell.anim = cell.anim + 1
	local t = cell.tile
	if color == 0 then
		t.base.Visible = false
		return
	end
	paintTile(t, color)
	t.flash.BackgroundTransparency = 1
	t.base.Visible = true
	t.base.Size = UDim2.new(1, 0, 1, 0)
	if animate then
		t.scale.Scale = 0.55
		tween(t.scale, 0.28, { Scale = 1 }, Enum.EasingStyle.Back)
	else
		t.scale.Scale = 1
	end
end

local function renderBoard()
	for r = 1, N do
		for c = 1, N do setCellFilled(r, c, board[r][c], false) end
	end
end

local function clearPreviewVisuals()
	for r = 1, N do
		for c = 1, N do
			local cell = cells[r][c]
			cell.ghost.BackgroundTransparency = 1
			cell.ghostStroke.Transparency = 1
			cell.hintStroke.Transparency = 1
			cell.hint.BackgroundTransparency = 1
		end
	end
end

local function clearPreview()
	preview = nil
	clearPreviewVisuals()
end

-- preview anchored so the shape's middle cell sits under the pointer
local function pivotOffset(shape)
	return (shape.h - 1) // 2, (shape.w - 1) // 2
end

local function setPreview(r, c)
	clearPreviewVisuals()
	if not selected or not hand[selected] then
		preview = nil
		return
	end
	local shape = hand[selected]
	local pr, pc = pivotOffset(shape)
	local tr, tc = r - pr, c - pc
	preview = { tr, tc, r, c }
	local valid = Logic.canPlace(board, shape, tr, tc)

	for _, cell in ipairs(shape.cells) do
		local rr, cc = tr + cell[1], tc + cell[2]
		if rr >= 1 and rr <= N and cc >= 1 and cc <= N then
			local g = cells[rr][cc]
			local good = valid
			g.ghost.BackgroundColor3 = good and BLOCK_COLORS[shape.color] or C.red
			g.ghostStroke.Color = good and C.cyan or C.red
			g.ghost.BackgroundTransparency = 0.45
			g.ghostStroke.Transparency = 0.1
		end
	end

	-- gold glow on lines this move would complete
	if valid then
		local sim = {}
		for i = 1, N do
			sim[i] = {}
			for j = 1, N do sim[i][j] = board[i][j] end
		end
		Logic.place(sim, shape, tr, tc)
		local rows, cols = Logic.findFull(sim)
		for _, rr in ipairs(rows) do
			for cc = 1, N do
				cells[rr][cc].hintStroke.Transparency = 0.1
				cells[rr][cc].hint.BackgroundTransparency = 0.85
			end
		end
		for _, cc in ipairs(cols) do
			for rr = 1, N do
				cells[rr][cc].hintStroke.Transparency = 0.1
				cells[rr][cc].hint.BackgroundTransparency = 0.85
			end
		end
	end
end

local function renderSlot(i, animate)
	local s = slots[i]
	local shape = hand[i]
	for _, t in ipairs(s.tiles) do t.base.Visible = false end
	if not shape then
		s.stroke.Color = Color3.fromRGB(50, 46, 90)
		s.stroke.Transparency = 0.7
		return
	end
	local m = math.floor(math.min(80 / shape.w, 56 / shape.h, 20))
	local g = 1
	local tw_ = shape.w * m + (shape.w - 1) * g
	local th_ = shape.h * m + (shape.h - 1) * g
	local ox, oy = -tw_ / 2, -th_ / 2
	local fits = Logic.fitsAnywhere(board, shape)
	for k, cell in ipairs(shape.cells) do
		local t = s.tiles[k]
		paintTile(t, shape.color)
		t.base.AnchorPoint = Vector2.new(0, 0)
		t.base.Position = UDim2.new(0.5, ox + cell[2] * (m + g), 0.5, oy + cell[1] * (m + g))
		t.base.Size = UDim2.fromOffset(m, m)
		t.base.BackgroundTransparency = fits and 0 or 0.55
		t.base.Visible = true
		if animate then
			t.scale.Scale = 0.3
			tween(t.scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		else
			t.scale.Scale = 1
		end
	end
	local on = (selected == i)
	s.stroke.Color = on and C.cyan or Color3.fromRGB(90, 80, 160)
	s.stroke.Thickness = on and 3 or 1.5
	s.stroke.Transparency = on and 0 or 0.4
end

local function renderSelection()
	for i = 1, Logic.HAND do
		local s = slots[i]
		local on = (selected == i) and hand[i] ~= nil
		if hand[i] then
			s.stroke.Color = on and C.cyan or Color3.fromRGB(90, 80, 160)
			s.stroke.Thickness = on and 3 or 1.5
			s.stroke.Transparency = on and 0 or 0.4
			tween(s.scale, 0.12, { Scale = on and 1.05 or 1 })
		end
	end
end

local function renderHand(animate)
	for i = 1, Logic.HAND do renderSlot(i, animate) end
	renderSelection()
end

local lastText = {}
local function renderStats()
	local function set(l, key, text)
		if lastText[key] ~= text then
			lastText[key] = text
			l.Text = text
		end
	end
	set(ui.scoreV, "s", tostring(score))
	set(ui.linesV, "l", tostring(lines))
	set(ui.bestV, "b", tostring(math.max(best, score)))
end

local function bumpScore()
	ui.scoreScale.Scale = 1.25
	tween(ui.scoreScale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
end

local function setHint(text, color)
	ui.hint.Text = text
	ui.hint.TextColor3 = color or C.muted
end

local function showPop(text, color)
	popToken = popToken + 1
	local id = popToken
	popL.Text = text
	popL.TextColor3 = color or C.gold
	popL.TextTransparency = 0
	popL.TextStrokeTransparency = 0.4
	popL.Position = UDim2.new(0.5, 0, 0, at(BOARD_Y) + BOARD_PX / 2)
	tween(popL, 0.9, { Position = UDim2.new(0.5, 0, 0, at(BOARD_Y) + BOARD_PX / 2 - 40), TextTransparency = 1, TextStrokeTransparency = 1 })
	task.delay(1, function()
		if alive and popToken == id then popL.TextTransparency = 1 end
	end)
end

local function shakeBoard()
	task.spawn(function()
		local base = UDim2.new(0, 10, 0, at(BOARD_Y))
		for k = 1, 6 do
			if not alive then return end
			boardPanel.Position = UDim2.new(0, 10 + ((k % 2 == 0) and 1 or -1) * (6 - k), 0, at(BOARD_Y))
			task.wait(0.03)
		end
		if alive then boardPanel.Position = base end
	end)
end

--==================================================
-- GAME FLOW
--==================================================
local function hideOver()
	if over.Visible then
		local t = tween(over, 0.15, { GroupTransparency = 1 })
		t.Completed:Connect(function()
			if over.GroupTransparency >= 0.99 then over.Visible = false end
		end)
	end
end

local function gameOver()
	if isOver then return end
	isOver = true
	selected = nil
	clearPreview()
	local isNew = score > best
	if isNew then
		best = score
		saveBest()
	end
	oScore.Text = tostring(score)
	oInfo.Text = string.format("LINES %d   ·   BEST %d", lines, best)
	oNew.Visible = isNew
	renderStats()
	setHint("Game over - no shape fits", C.red)
	shakeBoard()
	local id = gameId
	task.delay(0.6, function()
		if alive and gameId == id and isOver then
			over.Visible = true
			over.GroupTransparency = 1
			tween(over, 0.3, { GroupTransparency = 0 })
		end
	end)
end

local function newHand(animate)
	hand = Logic.generate(board, math.random) -- three fresh random shapes
	selected = nil
	renderHand(animate)
end

local function startGame()
	gameId = gameId + 1
	board = Logic.newBoard()
	score, lines, combo = 0, 0, 0
	isOver = false
	selected = nil
	clearPreview()
	hideOver()
	lastText = {}
	renderBoard()
	newHand(true)
	renderStats()
	setHint("Select a block, then tap the board", C.muted)
end

local function selectSlot(i)
	if isOver or not hand[i] then return end
	selected = (selected == i) and nil or i -- tapping the selected one again deselects it
	clearPreview()
	renderSelection()
	setHint(selected and (touchMode and "Tap a cell to preview, tap again to place" or "Move over the board, click to place") or "Select a block, then tap the board", selected and C.cyan or C.muted)
end

local function animateClear(cellsCleared)
	local id = gameId
	for _, cl in ipairs(cellsCleared) do
		local cell = cells[cl[1]][cl[2]]
		cell.anim = cell.anim + 1
		local token = cell.anim
		local t = cell.tile
		paintTile(t, cl[3])
		t.base.Visible = true
		t.flash.BackgroundTransparency = 0.15
		tween(t.flash, 0.18, { BackgroundTransparency = 0.6 })
		tween(t.scale, 0.3, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In).Completed:Connect(function()
			if alive and gameId == id and cell.anim == token and board[cl[1]][cl[2]] == 0 then
				t.base.Visible = false
				t.scale.Scale = 1
				t.flash.BackgroundTransparency = 1
			end
		end)
	end
end

local function tryPlace()
	if isOver or not selected or not preview then return false end
	local shape = hand[selected]
	if not shape then return false end
	local tr, tc = preview[1], preview[2]
	if not Logic.canPlace(board, shape, tr, tc) then
		shakeBoard()
		setHint("Can't place there - cells must be empty and inside the board", C.red)
		return false
	end

	-- 1) place
	Logic.place(board, shape, tr, tc)
	for _, cell in ipairs(shape.cells) do
		setCellFilled(tr + cell[1], tc + cell[2], shape.color, true)
	end

	-- 2) clear full rows / columns
	local rows, cols = Logic.findFull(board)
	local nLines = #rows + #cols
	local cleared = {}
	if nLines > 0 then
		combo = combo + 1
		cleared = Logic.clearLines(board, rows, cols)
	else
		combo = 0
	end

	-- 3) score
	local gained, bonus = Logic.moveScore(shape.count, nLines, combo)
	score = score + gained
	lines = lines + nLines
	bumpScore()
	if nLines > 0 then
		animateClear(cleared)
		local names = { "CLEAR!", "DOUBLE!", "TRIPLE!", "AMAZING!" }
		showPop(string.format("%s  +%d", names[math.min(nLines, 4)], bonus), C.gold)
	end

	-- 4) this shape is used; refill with 3 new random shapes when all are used
	hand[selected] = nil
	selected = nil
	clearPreview()
	local used = true
	for i = 1, Logic.HAND do
		if hand[i] then used = false end
	end
	if used then
		hand = Logic.generate(board, math.random) -- new set appears immediately
		renderHand(true)
	else
		renderHand(false)
	end
	renderStats()
	setHint("Select a block, then tap the board", C.muted)

	-- 5) game over when none of the available shapes fits anywhere
	if not Logic.anyFits(board, hand) then gameOver() end
	return true
end

--==================================================
-- INPUT WIRING
--==================================================
for i = 1, Logic.HAND do
	bind(slots[i].hit.MouseButton1Click, function() selectSlot(i) end)
end

bind(UserInputService.LastInputTypeChanged, function(t)
	if t == Enum.UserInputType.Touch then
		touchMode = true
	elseif t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Keyboard then
		touchMode = false
	end
end)

for r = 1, N do
	for c = 1, N do
		local hit = cells[r][c].hit
		-- mouse: hover shows the preview
		bind(hit.MouseEnter, function()
			if touchMode or isOver or not selected then return end
			setPreview(r, c)
		end)
		bind(hit.InputBegan, function(input)
			if isOver then return end
			local t = input.UserInputType
			if t == Enum.UserInputType.Touch then
				touchMode = true
				if not selected then
					setHint("Select a block first", C.gold)
					return
				end
				-- first tap = preview, tapping the same preview again = place
				if preview and preview[3] == r and preview[4] == c then
					tryPlace()
				else
					setPreview(r, c)
				end
			elseif t == Enum.UserInputType.MouseButton1 then
				touchMode = false
				if not selected then
					setHint("Select a block first", C.gold)
					return
				end
				setPreview(r, c)
				tryPlace()
			end
		end)
	end
end

bind(restartBtn.MouseButton1Click, startGame)
bind(oRestart.MouseButton1Click, startGame)

--==================================================
-- WINDOW: drag / minimize / close
--==================================================
local mainOpen = false
local minimized = false
local winTweens = {}

local function viewScale()
	local cam = workspace.CurrentCamera
	if not cam then return 1 end
	local v = cam.ViewportSize
	return math.clamp(math.min(v.X / (WIDTH + 16), v.Y / (HEIGHT + 16)), 0.4, 1)
end

local function clampMain()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local vp = cam.ViewportSize
	local s = mainScale.Scale
	local w = WIDTH * s
	local h = main.Size.Y.Offset * s
	local cx = vp.X / 2 + main.Position.X.Offset
	local cy = vp.Y / 2 + main.Position.Y.Offset
	cx = math.clamp(cx, 90 - w / 2, vp.X - 90 + w / 2)
	local top = math.clamp(cy - h / 2, 0, math.max(vp.Y - 48 * s, 0))
	cy = top + h / 2
	main.Position = UDim2.new(0.5, cx - vp.X / 2, 0.5, cy - vp.Y / 2)
end

do
	local dragging = false
	local startInput, startPos
	bind(dragHandle.InputBegan, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			startInput, startPos = i.Position, main.Position
		end
	end)
	bind(UserInputService.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - startInput
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			clampMain()
		end
	end)
	bind(UserInputService.InputEnded, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
		end
	end)
end

local function setMainOpen(open)
	mainOpen = open
	for _, t in ipairs(winTweens) do t:Cancel() end
	table.clear(winTweens)
	local base = viewScale()
	if open then
		main.Visible = true
		mainScale.Scale = base * 0.85
		main.GroupTransparency = 1
		table.insert(winTweens, tween(main, 0.25, { GroupTransparency = 0 }))
		table.insert(winTweens, tween(mainScale, 0.35, { Scale = base }, Enum.EasingStyle.Back))
	else
		table.insert(winTweens, tween(main, 0.18, { GroupTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In))
		local t = tween(mainScale, 0.18, { Scale = base * 0.9 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		table.insert(winTweens, t)
		t.Completed:Connect(function(st)
			if st == Enum.PlaybackState.Completed and not mainOpen then main.Visible = false end
		end)
	end
end

local function setMinimized(min)
	minimized = min
	minBtn.Text = min and "▢" or "–"
	if min then
		body.Visible = false
		tween(main, 0.25, { Size = UDim2.new(0, WIDTH, 0, HEADER_H) }, Enum.EasingStyle.Quint)
	else
		local t = tween(main, 0.3, { Size = UDim2.new(0, WIDTH, 0, HEIGHT) }, Enum.EasingStyle.Back)
		t.Completed:Connect(function()
			if not minimized then body.Visible = true end
		end)
	end
end
bind(minBtn.MouseButton1Click, function() setMinimized(not minimized) end)
bind(closeBtn.MouseButton1Click, function() setMainOpen(false) end)

--==================================================
-- LEFT-SIDE DRAGGABLE TOGGLE
--==================================================
local TOGGLE = 56
local toggle = Instance.new("TextButton")
toggle.Name = "Toggle"
toggle.Position = UDim2.new(0, 12, 0, 300)
toggle.Size = UDim2.new(0, TOGGLE, 0, TOGGLE)
toggle.BackgroundColor3 = Color3.fromRGB(10, 6, 24)
toggle.AutoButtonColor = false
toggle.Text = ""
toggle.ZIndex = 60
toggle.Parent = gui
corner(toggle, 99)
local _, toggleGrad = stroke(toggle, 3, 0)
local toggleScale = Instance.new("UIScale", toggle)
-- icon: four little blocks
do
	local colors = { 1, 2, 4, 1 }
	local k = 0
	for rr = 0, 1 do
		for cc = 0, 1 do
			k = k + 1
			local hold = frame(toggle, UDim2.new(0.5, -13 + cc * 14, 0.5, -13 + rr * 14), UDim2.fromOffset(12, 12), C.bg)
			hold.BackgroundTransparency = 1
			hold.ZIndex = 62
			local t = makeTile(hold, 3)
			t.base.Size = UDim2.new(1, 0, 1, 0)
			paintTile(t, colors[k])
			t.base.ZIndex = 62
			for _, d in ipairs(t.base:GetDescendants()) do
				if d:IsA("GuiObject") then d.ZIndex = 63 end
			end
		end
	end
end
local ring = Instance.new("Frame")
ring.AnchorPoint = Vector2.new(0.5, 0.5)
ring.Position = UDim2.new(0.5, 0, 0.5, 0)
ring.Size = UDim2.new(1, 0, 1, 0)
ring.BackgroundTransparency = 1
ring.ZIndex = 59
ring.Parent = toggle
corner(ring, 99)
local ringStroke = Instance.new("UIStroke")
ringStroke.Thickness = 2
ringStroke.Color = C.purple
ringStroke.Transparency = 0.2
ringStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
ringStroke.Parent = ring
local ringA = TweenService:Create(ring, TweenInfo.new(1.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1), { Size = UDim2.new(1, 28, 1, 28) })
local ringB = TweenService:Create(ringStroke, TweenInfo.new(1.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1), { Transparency = 1 })
ringA:Play()
ringB:Play()

local function clampToggle()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local vp = cam.ViewportSize
	local x = math.clamp(toggle.Position.X.Offset, 0, math.max(vp.X - TOGGLE, 0))
	local y = math.clamp(toggle.Position.Y.Offset, 0, math.max(vp.Y - TOGGLE, 0))
	toggle.Position = UDim2.new(0, x, 0, y)
end

do
	local cam = workspace.CurrentCamera
	if cam then
		toggle.Position = UDim2.new(0, 12, 0, math.floor(cam.ViewportSize.Y / 2 - TOGGLE / 2))
	end
	local dragging, moved = false, false
	local startInput, startPos
	bind(toggle.InputBegan, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, moved = true, false
			startInput, startPos = i.Position, toggle.Position
		end
	end)
	bind(UserInputService.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - startInput
			if d.Magnitude > 8 then moved = true end
			if moved then
				toggle.Position = UDim2.new(0, startPos.X.Offset + d.X, 0, startPos.Y.Offset + d.Y)
				clampToggle()
			end
		end
	end)
	bind(UserInputService.InputEnded, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			if not moved then
				if mainOpen then
					setMainOpen(false)
				else
					setMainOpen(true)
					if minimized then setMinimized(false) end
					clampMain()
				end
			end
		end
	end)
	bind(toggle.MouseEnter, function() tween(toggleScale, 0.15, { Scale = 1.1 }) end)
	bind(toggle.MouseLeave, function() tween(toggleScale, 0.15, { Scale = 1 }) end)
	if cam then
		bind(cam:GetPropertyChangedSignal("ViewportSize"), function()
			if mainOpen then mainScale.Scale = viewScale() end
			clampToggle()
			clampMain()
		end)
	end
end

--==================================================
-- LIGHT LOOP (only gradient animation) + CLEANUP
--==================================================
local heartbeatConn
local t0 = os.clock()
heartbeatConn = RunService.Heartbeat:Connect(function()
	if not alive then return end
	local now = os.clock() - t0
	toggleGrad.Rotation = (now * 90) % 360
	if main.Visible then
		mainStrokeGrad.Rotation = (now * 40) % 360
		boardStrokeGrad.Rotation = (now * -55) % 360
	end
end)

local function cleanup()
	if not alive then return end
	alive = false
	gameId = gameId + 1
	for _, c in ipairs(connections) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(connections)
	if heartbeatConn then pcall(function() heartbeatConn:Disconnect() end) end
	pcall(function() ringA:Cancel() end)
	pcall(function() ringB:Cancel() end)
	pcall(function() gui:Destroy() end)
	if _G.AayanBlockBlast_Cleanup == cleanup then _G.AayanBlockBlast_Cleanup = nil end
end
_G.AayanBlockBlast_Cleanup = cleanup
bind(gui.Destroying, function() cleanup() end)

--==================================================
-- START
--==================================================
startGame()
setMainOpen(true)
