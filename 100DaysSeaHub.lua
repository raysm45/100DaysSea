-- ===========================================================================
--  100 DAYS SEA  —  HUB LENGKAP
--  ESP (Player/Pulau/Chest/Resource/Boat/Creature) + Auto Lock Harpoon
--  + Teleport + Quick E/F + Auto Farm + Auto Fuel + Movement + Home UI
--  Author: MCP Real session
--  Toggle menu: RightCtrl
-- ===========================================================================
--  Struktur kode dikategorisasi:
--    [0]  State adapter (live-reload aware)
--    [1]  Config  (persist via getgenv)
--    [2]  Services & warna
--    [3]  Drawing pools
--    [4]  Helpers
--    [5]  Cache target
--    [6]  Auto Lock + Auto Fire
--    [7]  Movement (speed/jump/noclip/fly)
--    [8]  Teleport
--    [9]  Quick Interact (E/F)
--    [10] Auto Fuel
--    [11] Render loop (ESP + Home live update)
--    [12] UI (WindUI)
--    [13] Init
-- ===========================================================================

-- ============================================================
-- [0] STATE ADAPTER — pakai STATE harness bila ada (live-reload),
--     fallback lokal bila dijalankan via eval biasa.
-- ============================================================
local FC = {} -- fallback cleanup list (hanya dipakai bila STATE == nil)

local function onCleanup(fn)
	if STATE and STATE.onCleanup then
		STATE.onCleanup(fn)
	else
		FC[#FC + 1] = fn
	end
end

local function Connect(sig, fn)
	if STATE and STATE.connect then
		return STATE.connect(sig, fn)
	end
	local c = sig:Connect(fn)
	FC[#FC + 1] = function()
		pcall(function()
			c:Disconnect()
		end)
	end
	return c
end

-- ============================================================
-- [1] CONFIG — persist across reload via getgenv (tabel stabil)
-- ============================================================
local DEFAULTS = {
	-- ESP
	espMaster = true,
	player = true,
	island = true,
	chest = true,
	resource = true,
	boat = false,
	creature = true,
	tracers = false,
	showDist = true,
	showHealth = true,
	maxDist = 1500,
	-- Auto Lock / Farm
	autoLock = false,
	autoFire = false,
	fireRate = 0.45,
	lockCategory = "Kayu",
	lockRange = 120,
	fov = 260,
	-- Movement
	speedOn = false,
	speed = 40,
	jumpOn = false,
	jump = 75,
	noclip = false,
	fly = false,
	flySpeed = 70,
	-- Teleport
	tpCategory = "Resource",
	clickTeleport = false,
	-- Quick Interact
	quickPrompt = false,
	simE = false,
	simF = false,
	quickRadius = 14,
	quickInterval = 0.45,
	-- Auto Fuel
	autoFuel = false,
	fuelRadius = 24,
	-- Warna
	colPlayer = Color3.fromRGB(255, 80, 80),
	colIsland = Color3.fromRGB(80, 220, 255),
	colChest = Color3.fromRGB(255, 205, 60),
	colBoat = Color3.fromRGB(190, 120, 255),
	colCreature = Color3.fromRGB(255, 120, 200),
	colWood = Color3.fromRGB(90, 220, 90),
	colMetal = Color3.fromRGB(160, 190, 230),
	colFood = Color3.fromRGB(255, 160, 60),
	colLock = Color3.fromRGB(255, 60, 60),
	colTracer = Color3.fromRGB(255, 255, 255),
}

local genv = getgenv()
-- Generation counter: cegah cleanup run lama menyentuh window run baru (race).
genv["_100days_gen"] = (genv["_100days_gen"] or 0) + 1
local MYGEN = genv["_100days_gen"]
local _saved = genv["_100days_cfg"]
local CONFIG = {}
for k, v in pairs(DEFAULTS) do
	CONFIG[k] = v
end
if type(_saved) == "table" then
	for k, v in pairs(_saved) do
		if DEFAULTS[k] ~= nil then
			CONFIG[k] = v
		end
	end
end
genv["_100days_cfg"] = CONFIG -- referensi stabil; UI callback memutasi tabel ini

-- ============================================================
-- [2] Services & warna
-- ============================================================
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

local function col(key)
	return CONFIG[key]
end

-- ============================================================
-- [3] Drawing pools (reuse objek, tanpa ghost)
-- ============================================================
local pools = { text = {}, square = {}, circle = {}, line = {} }

local function makePool(kind, count)
	local p = pools[kind]
	for i = #p + 1, count do
		local d
		if kind == "text" then
			d = Drawing.new("Text")
			d.Center = true
			d.Outline = true
			d.OutlineColor = Color3.fromRGB(0, 0, 0)
			d.Font = 2
			d.Size = 14
		elseif kind == "square" then
			d = Drawing.new("Square")
			d.Thickness = 1.5
			d.Filled = false
			d.Outline = true
			d.OutlineColor = Color3.fromRGB(0, 0, 0)
		elseif kind == "line" then
			d = Drawing.new("Line")
			d.Thickness = 1
			d.From = Vector2.new(0, 0)
			d.To = Vector2.new(0, 0)
		else -- circle (resource dot). JANGAN set NumSides (Real quirk).
			d = Drawing.new("Circle")
			d.Thickness = 1.5
			d.Filled = true
			d.Radius = 4
			d.Transparency = 0.2
		end
		d.Visible = false
		p[i] = d
	end
	return p
end

local function hideFrom(kind, startIdx)
	local p = pools[kind]
	for i = startIdx, #p do
		p[i].Visible = false
	end
end

onCleanup(function()
	for _, kind in ipairs({ "text", "square", "circle", "line" }) do
		for _, d in ipairs(pools[kind]) do
			pcall(function()
				d.Visible = false
				d:Remove()
			end)
		end
		pools[kind] = {}
	end
end)

-- ============================================================
-- [4] Helpers
-- ============================================================
local function screenCenter()
	return Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
end

local function originPos()
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp then
		return hrp.Position
	end
	return Camera.CFrame.Position
end

local function getHRP(plr)
	local char = (plr or LocalPlayer).Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function getHum(char)
	return char and char:FindFirstChildOfClass("Humanoid")
end

-- Kategori item berdasar attribute Interactable
local function matchesCategory(inst, cat)
	local res = inst:GetAttribute("Resource")
	local food = inst:GetAttribute("Food")
	if cat == "Semua" then
		return (res ~= nil or food ~= nil)
	elseif cat == "Kayu" then
		return res == "Wood"
	elseif cat == "Besi" then
		return res == "Metal"
	elseif cat == "Makanan" then
		return food ~= nil
	end
	return false
end

local function resInfo(inst)
	if inst:GetAttribute("Resource") == "Wood" then
		return col("colWood"), "Kayu"
	elseif inst:GetAttribute("Resource") == "Metal" then
		return col("colMetal"), "Besi"
	elseif inst:GetAttribute("Food") ~= nil then
		return col("colFood"), "Makanan"
	end
	return col("colWood"), "?"
end

local function pivotPos(inst)
	local ok, piv = pcall(function()
		return inst:GetPivot().Position
	end)
	if ok then
		return piv
	end
	return nil
end

-- ============================================================
-- [5] Cache target (refresh berkala, loop dibatasi)
-- ============================================================
local cache = { t = 0, prompts = {} }

-- Prompt list secara incremental (tanpa scan penuh berulang)
local promptSet = {}
Connect(workspace.DescendantAdded, function(d)
	if d:IsA("ProximityPrompt") then
		promptSet[d] = true
	end
end)
Connect(workspace.DescendantRemoving, function(d)
	if d:IsA("ProximityPrompt") then
		promptSet[d] = nil
	end
end)
task.spawn(function()
	pcall(function()
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("ProximityPrompt") then
				promptSet[d] = true
			end
		end
	end)
end)

local function folderList(folderName, color, o, md, limit)
	local folder = workspace:FindFirstChild(folderName)
	local list = {}
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if #list >= (limit or 200) then
				break
			end
			local piv = pivotPos(m)
			if piv and (piv - o).Magnitude <= md then
				list[#list + 1] = { pos = piv, name = m.Name, color = color, inst = m }
			end
		end
	end
	return list
end

local function refreshCache()
	local o = originPos()
	local md = CONFIG.maxDist

	-- Players
	local players = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer then
			local char = plr.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			local hum = getHum(char)
			if hrp and (hrp.Position - o).Magnitude <= md then
				players[#players + 1] = {
					pos = hrp.Position,
					name = plr.DisplayName or plr.Name,
					hum = hum,
					hrp = hrp,
				}
			end
		end
	end
	cache.players = players

	cache.islands = folderList("IslandContainer", col("colIsland"), o, md, 100)
	cache.chests = folderList("Chests", col("colChest"), o, md, 200)
	cache.creatures = folderList("CreatureContainer", col("colCreature"), o, md, 100)

	-- Boats (tag)
	local boats = {}
	for _, b in ipairs(CollectionService:GetTagged("Boat")) do
		local piv = pivotPos(b)
		if piv and (piv - o).Magnitude <= md then
			boats[#boats + 1] = { pos = piv, name = b.Name, color = col("colBoat"), inst = b }
		end
	end
	cache.boats = boats

	-- Resources (Interactable dgn Resource/Food)
	local res = {}
	for _, inst in ipairs(CollectionService:GetTagged("Interactable")) do
		if matchesCategory(inst, "Semua") then
			local piv = pivotPos(inst)
			if piv and (piv - o).Magnitude <= md then
				local c, label = resInfo(inst)
				res[#res + 1] = { pos = piv, name = label, color = c, inst = inst }
			end
		end
	end
	cache.resources = res

	-- Bonfire (buat Auto Fuel) — hanya scan saat fitur aktif, hasil di-cache
	if CONFIG.autoFuel then
		local bf = cache.bonfire
		if not (bf and bf.Parent) then
			cache.bonfire = nil
			pcall(function()
				local keywords = { "bonfire", "campfire", "firepit", "tungku", "api" }
				local function scan(container, depth)
					if depth > 3 or cache.bonfire then
						return
					end
					for _, c in ipairs(container:GetChildren()) do
						if cache.bonfire then
							return
						end
						local low = c.Name:lower()
						for _, kw in ipairs(keywords) do
							if low:find(kw) then
								cache.bonfire = c
								return
							end
						end
						if c:IsA("Model") or c:IsA("Folder") then
							scan(c, depth + 1)
						end
					end
				end
				scan(workspace, 0)
			end)
		end
	end
end

-- ============================================================
-- [6] Auto Lock + Auto Fire
-- ============================================================
local LOCK = { target = nil, lastFire = 0 }

local function harpoonEquipped()
	local char = LocalPlayer.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if not tool then
		return false
	end
	return tool:GetAttribute("MaxRange") ~= nil
		or tool.Name:lower():find("harpoon") ~= nil
		or tool.Name:lower():find("riptide") ~= nil
end

local function findLockTarget()
	if not CONFIG.autoLock or not harpoonEquipped() then
		return nil
	end
	local o = originPos()
	local center = screenCenter()
	local fovR = CONFIG.fov
	local best, bestD2
	for _, inst in ipairs(CollectionService:GetTagged("Interactable")) do
		if matchesCategory(inst, CONFIG.lockCategory) then
			local piv = pivotPos(inst)
			if piv then
				local dist = (piv - o).Magnitude
				if dist <= CONFIG.lockRange then
					local sp, onScreen = Camera:WorldToViewportPoint(piv)
					if onScreen then
						local dx, dy = sp.X - center.X, sp.Y - center.Y
						local d2 = dx * dx + dy * dy
						if d2 <= fovR * fovR and (bestD2 == nil or d2 < bestD2) then
							bestD2 = d2
							best = inst
						end
					end
				end
			end
		end
	end
	return best
end

-- Redirect ray bidik harpoon menuju target terkunci.
-- Dipanggil tiap ViewportPointToRay / ScreenPointToRay; hanya redirect
-- bila pemanggilnya HarpoonScript.
local function aimRedirect(self, method, x, y)
	local tgt = LOCK.target
	if not tgt or not tgt.Parent then
		return
	end
	local ok, calling = pcall(getcallingscript)
	if ok and calling and calling.Name == "HarpoonScript" then
		local okp, tp = pcall(function()
			return tgt:GetPivot().Position
		end)
		if okp then
			local cp = Camera.CFrame.Position
			return Ray.new(cp, (tp - cp).Unit)
		end
	end
	-- tidak return apa-apa -> method asli jalan
end

if STATE and STATE.namecallHook then
	STATE.namecallHook("ViewportPointToRay", aimRedirect)
	STATE.namecallHook("ScreenPointToRay", aimRedirect)
end

-- Auto Fire: simulasi klik mouse ke tengah layar saat ada target terkunci.
-- Karena aim sudah di-redirect oleh hook, tembakan melengkung ke target.
local function tryAutoFire()
	if not (CONFIG.autoFire and CONFIG.autoLock) then
		return
	end
	if not LOCK.target or not LOCK.target.Parent then
		return
	end
	local now = os.clock()
	if now - LOCK.lastFire < (CONFIG.fireRate or 0.45) then
		return
	end
	LOCK.lastFire = now
	task.spawn(function()
		pcall(function()
			local vp = Camera.ViewportSize
			local cx, cy = math.floor(vp.X / 2), math.floor(vp.Y / 2)
			VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true, game, 1)
			task.wait(0.03)
			VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
		end)
	end)
end

-- ============================================================
-- [7] Movement (speed / jump / noclip / fly)
-- ============================================================
local function applyMovement()
	pcall(function()
		local char = LocalPlayer.Character
		local hum = getHum(char)
		if hum then
			hum.WalkSpeed = CONFIG.speedOn and CONFIG.speed or 16
			hum.UseJumpPower = true
			hum.JumpPower = CONFIG.jumpOn and CONFIG.jump or 50
		end
	end)
end

Connect(LocalPlayer.CharacterAdded, function()
	task.wait(0.5)
	applyMovement()
end)

-- Noclip (jalan saat noclip/fly aktif)
Connect(RunService.Stepped, function()
	if CONFIG.noclip or CONFIG.fly then
		local char = LocalPlayer.Character
		if char then
			for _, p in ipairs(char:GetDescendants()) do
				if p:IsA("BasePart") and p.CanCollide then
					p.CanCollide = false
				end
			end
		end
	end
end)

-- Fly
Connect(RunService.RenderStepped, function()
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = getHum(char)
	if CONFIG.fly and hrp then
		if hum and not hum.PlatformStand then
			hum.PlatformStand = true
		end
		local cf = Camera.CFrame
		local dir = Vector3.zero
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then
			dir = dir + cf.LookVector
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then
			dir = dir - cf.LookVector
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then
			dir = dir - cf.RightVector
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then
			dir = dir + cf.RightVector
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
			dir = dir + Vector3.yAxis
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
			dir = dir - Vector3.yAxis
		end
		if dir.Magnitude > 0 then
			hrp.Velocity = dir.Unit * CONFIG.flySpeed
		else
			hrp.Velocity = Vector3.zero
		end
		hrp.CanCollide = false
	elseif hum and hum.PlatformStand then
		hum.PlatformStand = false
	end
end)

-- ============================================================
-- [8] Teleport
-- ============================================================
local function teleportTo(pos)
	pcall(function()
		local hrp = getHRP()
		if not hrp then
			return
		end
		local safe = pos + Vector3.new(0, 4, 0)
		if safe.Y < -60 then
			safe = Vector3.new(safe.X, 5, safe.Z)
		end
		hrp.CFrame = CFrame.new(safe)
	end)
end

local function listFor(category)
	if category == "Player" then
		return cache.players
	elseif category == "Resource" then
		return cache.resources
	elseif category == "Pulau" then
		return cache.islands
	elseif category == "Chest" then
		return cache.chests
	elseif category == "Creature" then
		return cache.creatures
	elseif category == "Boat" then
		return cache.boats
	end
	return nil
end

local function nearestIn(category)
	local list = listFor(category)
	local o = originPos()
	local best, bestD
	for _, e in ipairs(list or {}) do
		local d = (e.pos - o).Magnitude
		if not bestD or d < bestD then
			bestD = d
			best = e
		end
	end
	return best, bestD
end

-- Click teleport
Connect(UserInputService.InputBegan, function(input, gpe)
	if not CONFIG.clickTeleport then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 and not gpe then
		pcall(function()
			local ray = Camera:ScreenPointToRay(input.Position.X, input.Position.Y)
			local params = RaycastParams.new()
			params.FilterDescendantsInstances = { LocalPlayer.Character }
			params.FilterType = Enum.RaycastFilterType.Exclude
			local hit = workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
			if hit then
				teleportTo(hit.Position)
			end
		end)
	end
end)

-- ============================================================
-- [9] Quick Interact (E/F)
-- ============================================================
local Quick = { last = 0 }

local function nearestPrompt(radius)
	local hrp = getHRP()
	if not hrp then
		return nil
	end
	local best, bestD
	for p in pairs(promptSet) do
		if p and p.Parent and p.Enabled then
			local par = p.Parent
			if par and par:IsA("BasePart") then
				local d = (par.Position - hrp.Position).Magnitude
				if d <= radius and (not bestD or d < bestD) then
					bestD = d
					best = p
				end
			end
		end
	end
	return best
end

local function pressKey(keycode, hold)
	pcall(function()
		VirtualInputManager:SendKeyEvent(true, keycode, false, game)
		task.wait(hold or 0.08)
		VirtualInputManager:SendKeyEvent(false, keycode, false, game)
	end)
end

local function fuelNearBonfire()
	-- Auto Fuel: bila dekat bonfire, tekan interaksi utk menambah bahan bakar.
	local bf = cache.bonfire
	if not bf or not bf.Parent then
		return false
	end
	local hrp = getHRP()
	if not hrp then
		return false
	end
	local piv = pivotPos(bf)
	if not piv then
		return false
	end
	if (piv - hrp.Position).Magnitude > (CONFIG.fuelRadius or 24) then
		return false
	end
	-- cari prompt di sekitar bonfire
	local prompt = nearestPrompt(CONFIG.fuelRadius or 24)
	if prompt then
		task.spawn(function()
			pcall(function()
				prompt:InputHoldBegin()
				task.wait(math.max(prompt.HoldDuration or 0, 0.05) + 0.04)
				prompt:InputHoldEnd()
			end)
		end)
		return true
	end
	-- fallback: simulasi E
	task.spawn(function()
		pressKey(Enum.KeyCode.E, 0.12)
	end)
	return true
end

-- ============================================================
-- [10] Render loop (ESP + AutoLock target + Home live update)
-- ============================================================
local UI_EL = {} -- referensi element UI (diisi saat pembuatan UI)
local fpsAcc, fpsCount, fpsVal = 0, 0, 60
local homeAcc = 0

local acc = 0
Connect(RunService.RenderStepped, function(dt)
	-- hitung FPS
	fpsAcc = fpsAcc + dt
	fpsCount = fpsCount + 1
	if fpsAcc >= 0.5 then
		fpsVal = math.floor(fpsCount / fpsAcc + 0.5)
		fpsAcc, fpsCount = 0, 0
	end

	-- refresh cache tiap 0.5s
	acc = acc + dt
	if acc >= 0.5 then
		acc = 0
		pcall(refreshCache)
	end

	-- target lock tiap frame
	LOCK.target = findLockTarget()

	-- auto fire
	tryAutoFire()

	-- ---- ESP ----
	local o = originPos()
	local center = screenCenter()
	local ti, si, ci, li = 1, 1, 1, 1
	local texts = makePool("text", 700)
	local squares = makePool("square", 64)
	local circles = makePool("circle", 500)
	local lines = makePool("line", 64)

	local master = CONFIG.espMaster

	-- PLAYER (box + nama + HP)
	if master and CONFIG.player then
		for _, e in ipairs(cache.players or {}) do
			local sp, onScreen = Camera:WorldToViewportPoint(e.pos)
			if onScreen and si <= #squares then
				local dist = math.floor((e.pos - o).Magnitude)
				local h = math.clamp(1400 / math.max(dist, 1), 18, 320)
				local w = h * 0.6
				local sq = squares[si]
				si += 1
				sq.Visible = true
				sq.Color = col("colPlayer")
				sq.Size = Vector2.new(w, h)
				sq.Position = Vector2.new(sp.X - w / 2, sp.Y - h / 2)

				if ti <= #texts then
					local t = texts[ti]
					ti += 1
					local label = e.name
					if CONFIG.showDist then
						label = string.format("%s [%dm]", label, dist)
					end
					if CONFIG.showHealth and e.hum then
						label = string.format("%s (%dHP)", label, math.floor(e.hum.Health))
					end
					t.Visible = true
					t.Color = Color3.new(1, 1, 1)
					t.Text = label
					t.Size = 14
					t.Position = Vector2.new(sp.X, sp.Y - h / 2 - 16)
				end
			end
		end
	end

	-- LABEL (island / chest / boat / creature)
	local function drawLabels(list)
		if not (master and list) then
			return
		end
		for _, e in ipairs(list) do
			local sp, onScreen = Camera:WorldToViewportPoint(e.pos + Vector3.new(0, 4, 0))
			if onScreen and ti <= #texts then
				local t = texts[ti]
				ti += 1
				local dist = math.floor((e.pos - o).Magnitude)
				local label = e.name
				if CONFIG.showDist then
					label = string.format("%s [%dm]", label, dist)
				end
				t.Visible = true
				t.Color = e.color
				t.Text = label
				t.Size = 13
				t.Position = Vector2.new(sp.X, sp.Y)
			end
		end
	end
	if CONFIG.island then
		drawLabels(cache.islands)
	end
	if CONFIG.chest then
		drawLabels(cache.chests)
	end
	if CONFIG.boat then
		drawLabels(cache.boats)
	end
	if CONFIG.creature then
		drawLabels(cache.creatures)
	end

	-- RESOURCE (titik warna) + tracers
	if master and CONFIG.resource then
		for _, e in ipairs(cache.resources or {}) do
			local sp, onScreen = Camera:WorldToViewportPoint(e.pos)
			if onScreen then
				if ci <= #circles then
					local c = circles[ci]
					ci += 1
					c.Visible = true
					c.Color = e.color
					c.Position = Vector2.new(sp.X, sp.Y)
				end
				if CONFIG.tracers and li <= #lines then
					local ln = lines[li]
					li += 1
					ln.Visible = true
					ln.Color = e.color
					ln.From = Vector2.new(center.X, Camera.ViewportSize.Y)
					ln.To = Vector2.new(sp.X, sp.Y)
				end
			end
		end
	end

	-- LOCK indicator
	if LOCK.target and LOCK.target.Parent then
		local piv = pivotPos(LOCK.target)
		if piv and ti <= #texts then
			local sp, onScreen = Camera:WorldToViewportPoint(piv)
			if onScreen then
				local t = texts[ti]
				ti += 1
				t.Visible = true
				t.Color = col("colLock")
				t.Text = CONFIG.autoFire and "LOCK*" or "LOCK"
				t.Size = 15
				t.Position = Vector2.new(sp.X, sp.Y - 22)
			end
		end
	end

	hideFrom("text", ti)
	hideFrom("square", si)
	hideFrom("circle", ci)
	hideFrom("line", li)

	-- ---- HOME live update ----
	homeAcc = homeAcc + dt
	if homeAcc >= 0.5 then
		homeAcc = 0
		-- re-apply gerakan (tahan reset server & apply perubahan config)
		if CONFIG.speedOn or CONFIG.jumpOn then
			applyMovement()
		end
		pcall(function()
			local char = LocalPlayer.Character
			local hum = getHum(char)
			if UI_EL.healthBar and hum then
				UI_EL.healthBar:Set(math.floor(hum.Health))
			end
			if UI_EL.infoCard then
				local sa = workspace:FindFirstChild("ServerAge")
				local day = sa and math.floor(sa.Value / 60) or 0
				local pos = originPos()
				local tool = char and char:FindFirstChildOfClass("Tool")
				UI_EL.infoCard:SetDesc(string.format(
					"Hari ke-%d   |   FPS %d\nPosisi: %.0f, %.0f, %.0f\nPegangan: %s",
					day,
					fpsVal,
					pos.X,
					pos.Y,
					pos.Z,
					tool and tool.Name or "-"
				))
			end
			if UI_EL.featureCard then
				local n = 0
				if CONFIG.espMaster then
					n = n + 1
				end
				if CONFIG.autoLock then
					n = n + 1
				end
				if CONFIG.autoFire then
					n = n + 1
				end
				if CONFIG.speedOn then
					n = n + 1
				end
				if CONFIG.jumpOn then
					n = n + 1
				end
				if CONFIG.noclip then
					n = n + 1
				end
				if CONFIG.fly then
					n = n + 1
				end
				if CONFIG.clickTeleport then
					n = n + 1
				end
				if CONFIG.quickPrompt or CONFIG.simE or CONFIG.simF then
					n = n + 1
				end
				if CONFIG.autoFuel then
					n = n + 1
				end
				UI_EL.featureCard:SetDesc(string.format("%d fitur aktif saat ini", n))
			end
		end)
	end
end)

-- Loop Quick Interact + Auto Fuel (terpisah, throttle)
Connect(RunService.Heartbeat, function()
	local now = os.clock()
	if now - Quick.last < CONFIG.quickInterval then
		return
	end

	-- Auto Fuel
	if CONFIG.autoFuel then
		Quick.last = now
		pcall(fuelNearBonfire)
		return
	end

	-- Quick Interact prompt
	if CONFIG.quickPrompt then
		local prompt = nearestPrompt(CONFIG.quickRadius)
		if prompt then
			Quick.last = now
			task.spawn(function()
				pcall(function()
					prompt:InputHoldBegin()
					task.wait(math.max(prompt.HoldDuration or 0, 0.05) + 0.03)
					prompt:InputHoldEnd()
				end)
			end)
		end
	end

	-- Simulasi key E/F
	if CONFIG.simE or CONFIG.simF then
		Quick.last = now
		if CONFIG.simE then
			task.spawn(function()
				pressKey(Enum.KeyCode.E)
			end)
		end
		if CONFIG.simF then
			task.spawn(function()
				pressKey(Enum.KeyCode.F)
			end)
		end
	end
end)

-- ============================================================
-- [11] UI (WindUI)
-- ============================================================
local okLoad, WindUI = pcall(function()
	return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
end)
if not okLoad or not WindUI then
	warn("[100days] WindUI gagal load: " .. tostring(WindUI))
	return
end

-- Snapshot gethui() SEBELUM window dibuat, supaya reload hanya menghancurkan
-- milik run ini (mencegah end stacking).
-- Safety net: hancurkan sisa window milik run sebelumnya yang gagal dibersihkan.
-- (Hanya yang mengandung judul kita — tidak menyentuh UI script lain.)
pcall(function()
	local gp = (gethui and gethui()) or game:GetService("CoreGui")
	for _, c in ipairs(gp:GetChildren()) do
		if c:IsA("ScreenGui") then
			local mine = false
			for _, d in ipairs(c:GetDescendants()) do
				if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text == "100 Days Sea" then
					mine = true
					break
				end
			end
			if mine then
				pcall(function()
					c:Destroy()
				end)
			end
		end
	end
end)

local ghParent = (gethui and gethui()) or game:GetService("CoreGui")
local before = {}
for _, g in ipairs(ghParent:GetChildren()) do
	before[g] = true
end

local Window = WindUI:CreateWindow({
	Title = "100 Days Sea",
	Icon = "anchor",
	Author = "ESP • Auto Lock • Teleport • Farm",
	Folder = "100DaysSea",
	Size = UDim2.fromOffset(560, 460),
	MinSize = Vector2.new(480, 380),
	ToggleKey = Enum.KeyCode.RightControl,
})

-- Capture milik run INI secara spesifik (by identity) — hindari race dgn run lama.
local myGuis = {}
for _, g in ipairs(ghParent:GetChildren()) do
	if not before[g] and g:IsA("ScreenGui") then
		myGuis[#myGuis + 1] = g
	end
end

onCleanup(function()
	-- Jika run baru sudah mengambil alih (gen berubah), JANGAN sentuh apa pun —
	-- safety-net run baru sudah membersihkan window lama. Cegah race stacking.
	if getgenv()["_100days_gen"] ~= MYGEN then
		return
	end
	pcall(function()
		if Window and Window.Destroy then
			Window:Destroy()
		end
	end)
	pcall(function()
		if Window and Window.Unload then
			Window:Unload()
		end
	end)
	-- Hancurkan HANYA ScreenGui milik run ini (by identity, bukan scan).
	for _, g in ipairs(myGuis) do
		pcall(function()
			if g.Parent then
				g:Destroy()
			end
		end)
	end
end)

-- Refs element UI utk apply config saat Muat
local UIREF = { toggle = {}, slider = {}, dropdown = {}, color = {} }

local function regToggle(key, el)
	UIREF.toggle[key] = el
	return el
end
local function regSlider(key, el)
	UIREF.slider[key] = el
	return el
end
local function regDropdown(key, el)
	UIREF.dropdown[key] = el
	return el
end
local function regColor(key, el)
	UIREF.color[key] = el
	return el
end

local function notify(title, content, icon)
	pcall(function()
		WindUI:Notify({ Title = title, Content = content, Duration = 5, Icon = icon or "info" })
	end)
end

local function applyMovementAndNotify()
	applyMovement()
end

-- ===== HOME =====
local TabHome = Window:Tab({ Title = "Home", Icon = "house" })
TabHome:Section({ Title = "👤 Pemain", Icon = "user" })
UI_EL.playerCard = TabHome:Paragraph({
	Title = LocalPlayer.DisplayName or LocalPlayer.Name,
	Desc = "Memuat info pemain...",
	ThumbnailSize = 64,
})
UI_EL.healthBar = TabHome:ProgressBar({
	Title = "Kesehatan",
	Desc = "HP",
	Value = { Min = 0, Max = 100, Default = 100 },
})
UI_EL.infoCard = TabHome:Paragraph({
	Title = "📊 Status Server",
	Desc = "Memuat...",
})
TabHome:Section({ Title = "✨ Fitur", Icon = "sparkles" })
UI_EL.featureCard = TabHome:Paragraph({
	Title = "Status Fitur",
	Desc = "0 fitur aktif",
})

TabHome:Section({ Title = "⚡ Aksi Cepat", Icon = "zap" })
TabHome:Button({
	Title = "Perbaiki Kamera",
	Desc = "Reset kamera ke Custom di belakang karakter",
	Icon = "camera",
	Callback = function()
		pcall(function()
			local char = LocalPlayer.Character
			local hum = getHum(char)
			Camera.CameraType = Enum.CameraType.Custom
			if hum then
				Camera.CameraSubject = hum
			end
			notify("Kamera", "Kamera diperbaiki.", "camera")
		end)
	end,
})
TabHome:Button({
	Title = "Matikan Semua ESP",
	Icon = "eye-off",
	Callback = function()
		CONFIG.espMaster = false
		notify("ESP", "Semua ESP dimatikan.", "eye-off")
	end,
})
TabHome:Button({
	Title = "Respawn",
	Desc = "Matiin karakter untuk respawn",
	Icon = "rotate-ccw",
	Callback = function()
		pcall(function()
			local char = LocalPlayer.Character
			local hum = getHum(char)
			if hum then
				hum.Health = 0
			end
		end)
	end,
})
TabHome:Section({ Title = "ℹ️ Tentang", Icon = "info" })
TabHome:Paragraph({
	Title = "100 Days Sea Hub",
	Desc = "Tekan RightCtrl untuk buka/tutup menu.\nFitur: ESP, Auto Lock, Teleport, Quick E/F, Auto Farm, Auto Fuel, Movement.",
})

-- Muat avatar (yield, jalan di task.spawn)
task.spawn(function()
	pcall(function()
		local thumb = Players:GetUserThumbnailAsync(
			LocalPlayer.UserId,
			Enum.ThumbnailType.HeadShot,
			Enum.ThumbnailSize.Size100x100
		)
		if UI_EL.playerCard and UI_EL.playerCard.SetThumbnail then
			UI_EL.playerCard:SetThumbnail(thumb, 64)
			UI_EL.playerCard:SetDesc(string.format("@%s", LocalPlayer.Name))
		end
	end)
end)

-- ===== ESP =====
local TabESP = Window:Tab({ Title = "ESP", Icon = "eye" })
TabESP:Section({ Title = "Master", Icon = "power" })
regToggle("espMaster", TabESP:Toggle({
	Title = "Aktifkan ESP",
	Desc = "Saklar utama semua ESP",
	Value = CONFIG.espMaster,
	Callback = function(s)
		CONFIG.espMaster = s
	end,
}))
TabESP:Section({ Title = "Target ESP", Icon = "list" })
regToggle("player", TabESP:Toggle({
	Title = "ESP Player",
	Desc = "Kotak + nama + HP",
	Value = CONFIG.player,
	Callback = function(s)
		CONFIG.player = s
	end,
}))
regToggle("island", TabESP:Toggle({
	Title = "ESP Pulau",
	Value = CONFIG.island,
	Callback = function(s)
		CONFIG.island = s
	end,
}))
regToggle("chest", TabESP:Toggle({
	Title = "ESP Chest",
	Value = CONFIG.chest,
	Callback = function(s)
		CONFIG.chest = s
	end,
}))
regToggle("resource", TabESP:Toggle({
	Title = "ESP Resource (Debris)",
	Desc = "Kayu, Besi, Makanan mengambang",
	Value = CONFIG.resource,
	Callback = function(s)
		CONFIG.resource = s
	end,
}))
regToggle("boat", TabESP:Toggle({
	Title = "ESP Boat",
	Value = CONFIG.boat,
	Callback = function(s)
		CONFIG.boat = s
	end,
}))
regToggle("creature", TabESP:Toggle({
	Title = "ESP Creature",
	Value = CONFIG.creature,
	Callback = function(s)
		CONFIG.creature = s
	end,
}))
TabESP:Section({ Title = "Pengaturan", Icon = "sliders" })
regToggle("tracers", TabESP:Toggle({
	Title = "Tracer Lines",
	Desc = "Garis dari bawah layar ke resource",
	Value = CONFIG.tracers,
	Callback = function(s)
		CONFIG.tracers = s
	end,
}))
regToggle("showDist", TabESP:Toggle({
	Title = "Tampilkan Jarak",
	Value = CONFIG.showDist,
	Callback = function(s)
		CONFIG.showDist = s
	end,
}))
regToggle("showHealth", TabESP:Toggle({
	Title = "Tampilkan HP Player",
	Value = CONFIG.showHealth,
	Callback = function(s)
		CONFIG.showHealth = s
	end,
}))
regSlider("maxDist", TabESP:Slider({
	Title = "Jarak Maks ESP (studs)",
	Value = { Min = 200, Max = 5000, Default = CONFIG.maxDist },
	Step = 100,
	Callback = function(v)
		CONFIG.maxDist = v
	end,
}))

-- ===== AUTO LOCK =====
local TabLock = Window:Tab({ Title = "Auto Lock", Icon = "crosshair" })
TabLock:Section({ Title = "Aim Lock (Harpoon)", Icon = "target" })
regToggle("autoLock", TabLock:Toggle({
	Title = "Aktifkan Auto Lock",
	Desc = "Saat menembak harpoon, bidikan melengkung ke target terkunci",
	Value = CONFIG.autoLock,
	Callback = function(s)
		CONFIG.autoLock = s
	end,
}))
regDropdown("lockCategory", TabLock:Dropdown({
	Title = "Kategori Target",
	Desc = "Jenis item yang di-lock",
	Values = { "Kayu", "Makanan", "Besi", "Semua" },
	Value = CONFIG.lockCategory,
	Callback = function(v)
		CONFIG.lockCategory = v
	end,
}))
regSlider("lockRange", TabLock:Slider({
	Title = "Jangkauan Lock (studs)",
	Value = { Min = 20, Max = 200, Default = CONFIG.lockRange },
	Step = 5,
	Callback = function(v)
		CONFIG.lockRange = v
	end,
}))
regSlider("fov", TabLock:Slider({
	Title = "FOV Lock (px)",
	Desc = "Lebar area sekitar crosshair yang boleh di-lock",
	Value = { Min = 50, Max = 800, Default = CONFIG.fov },
	Step = 10,
	Callback = function(v)
		CONFIG.fov = v
	end,
}))
TabLock:Section({ Title = "🌾 Auto Farm (Harpoon)", Icon = "wheat" })
regToggle("autoFire", TabLock:Toggle({
	Title = "Auto Fire",
	Desc = "Tembak otomatis saat target terkunci (auto kumpul resource)",
	Value = CONFIG.autoFire,
	Callback = function(s)
		CONFIG.autoFire = s
		if s and not CONFIG.autoLock then
			CONFIG.autoLock = true
			notify("Auto Farm", "Auto Lock otomatis diaktifkan.", "wheat")
		end
	end,
}))
regSlider("fireRate", TabLock:Slider({
	Title = "Fire Rate (detik/tembakan)",
	Value = { Min = 0.15, Max = 1.5, Default = CONFIG.fireRate },
	Step = 0.05,
	Callback = function(v)
		CONFIG.fireRate = v
	end,
}))

-- ===== PLAYER (Movement) =====
local TabPlayer = Window:Tab({ Title = "Player", Icon = "person-standing" })
TabPlayer:Section({ Title = "Gerakan", Icon = "move" })
regToggle("speedOn", TabPlayer:Toggle({
	Title = "Walk Speed",
	Value = CONFIG.speedOn,
	Callback = function(s)
		CONFIG.speedOn = s
		applyMovement()
	end,
}))
regSlider("speed", TabPlayer:Slider({
	Title = "Kecepatan Jalan",
	Value = { Min = 16, Max = 200, Default = CONFIG.speed },
	Step = 1,
	Callback = function(v)
		CONFIG.speed = v
		if CONFIG.speedOn then
			applyMovement()
		end
	end,
}))
regToggle("jumpOn", TabPlayer:Toggle({
	Title = "Jump Power",
	Value = CONFIG.jumpOn,
	Callback = function(s)
		CONFIG.jumpOn = s
		applyMovement()
	end,
}))
regSlider("jump", TabPlayer:Slider({
	Title = "Kekuatan Lompat",
	Value = { Min = 50, Max = 300, Default = CONFIG.jump },
	Step = 5,
	Callback = function(v)
		CONFIG.jump = v
		if CONFIG.jumpOn then
			applyMovement()
		end
	end,
}))
TabPlayer:Section({ Title = "Mode", Icon = "ghost" })
regToggle("noclip", TabPlayer:Toggle({
	Title = "Noclip",
	Desc = "Menembus tembok",
	Value = CONFIG.noclip,
	Callback = function(s)
		CONFIG.noclip = s
	end,
}))
regToggle("fly", TabPlayer:Toggle({
	Title = "Fly",
	Desc = "WASD + Spasi/LeftCtrl terbang",
	Value = CONFIG.fly,
	Callback = function(s)
		CONFIG.fly = s
	end,
}))
regSlider("flySpeed", TabPlayer:Slider({
	Title = "Kecepatan Fly",
	Value = { Min = 20, Max = 300, Default = CONFIG.flySpeed },
	Step = 5,
	Callback = function(v)
		CONFIG.flySpeed = v
	end,
}))

-- ===== TELEPORT =====
local TabTP = Window:Tab({ Title = "Teleport", Icon = "map-pin" })
TabTP:Section({ Title = "Teleport Cepat", Icon = "navigation" })
regDropdown("tpCategory", TabTP:Dropdown({
	Title = "Kategori Tujuan",
	Desc = "Jenis target teleport terdekat",
	Values = { "Resource", "Pulau", "Chest", "Creature", "Boat", "Player" },
	Value = CONFIG.tpCategory,
	Callback = function(v)
		CONFIG.tpCategory = v
	end,
}))
TabTP:Button({
	Title = "Teleport ke Target Terdekat",
	Desc = "Pindah ke kategori tujuan yang dipilih",
	Icon = "zap",
	Callback = function()
		local e, d = nearestIn(CONFIG.tpCategory)
		if e then
			teleportTo(e.pos)
			notify("Teleport", string.format("Menuju %s (%dm)", e.name, math.floor(d)), "map-pin")
		else
			notify("Teleport", "Tidak ada target di dekat kamu.", "alert-triangle")
		end
	end,
})
TabTP:Section({ Title = "🖱️ Click Teleport", Icon = "mouse-pointer" })
regToggle("clickTeleport", TabTP:Toggle({
	Title = "Click Teleport",
	Desc = "Klik kiri di mana pun utk teleport ke situ\ncatatan: menonaktifkan klik normal (aim)",
	Value = CONFIG.clickTeleport,
	Callback = function(s)
		CONFIG.clickTeleport = s
	end,
}))

-- ===== FARM (Quick Interact + Auto Fuel) =====
local TabFarm = Window:Tab({ Title = "Farm", Icon = "wheat" })
TabFarm:Section({ Title = "⚡ Quick Interact (E/F)", Icon = "hand" })
regToggle("quickPrompt", TabFarm:Toggle({
	Title = "Quick Interact (Prompt)",
	Desc = "Otomatis aktivasi prompt terdekat",
	Value = CONFIG.quickPrompt,
	Callback = function(s)
		CONFIG.quickPrompt = s
	end,
}))
regToggle("simE", TabFarm:Toggle({
	Title = "Simulasi Tombol E",
	Desc = "Kirim tombol E sungguhan (untuk sistem interact)",
	Value = CONFIG.simE,
	Callback = function(s)
		CONFIG.simE = s
	end,
}))
regToggle("simF", TabFarm:Toggle({
	Title = "Simulasi Tombol F",
	Desc = "Kirim tombol F sungguhan",
	Value = CONFIG.simF,
	Callback = function(s)
		CONFIG.simF = s
	end,
}))
regSlider("quickRadius", TabFarm:Slider({
	Title = "Radius Interact (studs)",
	Value = { Min = 4, Max = 40, Default = CONFIG.quickRadius },
	Step = 1,
	Callback = function(v)
		CONFIG.quickRadius = v
	end,
}))
regSlider("quickInterval", TabFarm:Slider({
	Title = "Interval (detik)",
	Value = { Min = 0.1, Max = 2, Default = CONFIG.quickInterval },
	Step = 0.05,
	Callback = function(v)
		CONFIG.quickInterval = v
	end,
}))
TabFarm:Section({ Title = "🔥 Auto Fuel (Bonfire)", Icon = "flame" })
regToggle("autoFuel", TabFarm:Toggle({
	Title = "Auto Fuel",
	Desc = "Otomatis isi bahan bakar bonfire saat di dekatnya\n(perlu di area gameplay)",
	Value = CONFIG.autoFuel,
	Callback = function(s)
		CONFIG.autoFuel = s
	end,
}))
regSlider("fuelRadius", TabFarm:Slider({
	Title = "Radius Fuel (studs)",
	Value = { Min = 8, Max = 60, Default = CONFIG.fuelRadius },
	Step = 2,
	Callback = function(v)
		CONFIG.fuelRadius = v
	end,
}))

-- ===== SETTINGS =====
local TabSet = Window:Tab({ Title = "Settings", Icon = "settings" })
TabSet:Section({ Title = "🎨 Warna ESP", Icon = "palette" })
regColor("colPlayer", TabSet:Colorpicker({
	Title = "Warna Player",
	Default = CONFIG.colPlayer,
	Callback = function(c)
		CONFIG.colPlayer = c
	end,
}))
regColor("colResource", TabSet:Colorpicker({
	Title = "Warna Resource (Kayu)",
	Default = CONFIG.colWood,
	Callback = function(c)
		CONFIG.colWood = c
	end,
}))
regColor("colChest", TabSet:Colorpicker({
	Title = "Warna Chest",
	Default = CONFIG.colChest,
	Callback = function(c)
		CONFIG.colChest = c
	end,
}))
regColor("colLock", TabSet:Colorpicker({
	Title = "Warna Lock",
	Default = CONFIG.colLock,
	Callback = function(c)
		CONFIG.colLock = c
	end,
}))
TabSet:Section({ Title = "💾 Config", Icon = "save" })
TabSet:Button({
	Title = "Simpan Config ke File",
	Icon = "save",
	Callback = function()
		pcall(function()
			local plain = {}
			for k, v in pairs(CONFIG) do
				if typeof(v) == "Color3" then
					plain[k] = {
						_c = true,
						r = math.floor(v.R * 255 + 0.5),
						g = math.floor(v.G * 255 + 0.5),
						b = math.floor(v.B * 255 + 0.5),
					}
				else
					plain[k] = v
				end
			end
			writefile("100DaysSea/config.json", HttpService:JSONEncode(plain))
			notify("Config", "Config disimpan.", "save")
		end)
	end,
})
TabSet:Button({
	Title = "Muat Config dari File",
	Icon = "folder-open",
	Callback = function()
		pcall(function()
			if isfile and isfile("100DaysSea/config.json") then
				local data = HttpService:JSONDecode(readfile("100DaysSea/config.json"))
				for k, v in pairs(data) do
					if DEFAULTS[k] ~= nil then
						if type(v) == "table" and v._c then
							CONFIG[k] = Color3.fromRGB(v.r, v.g, v.b)
						else
							CONFIG[k] = v
						end
					end
				end
				for k, el in pairs(UIREF.toggle) do
					pcall(function()
						el:Set(CONFIG[k])
					end)
				end
				for k, el in pairs(UIREF.slider) do
					pcall(function()
						el:Set(CONFIG[k])
					end)
				end
				for k, el in pairs(UIREF.dropdown) do
					pcall(function()
						el:Select(CONFIG[k])
					end)
				end
				for k, el in pairs(UIREF.color) do
					pcall(function()
						el:Set(CONFIG[k])
					end)
				end
				applyMovement()
				notify("Config", "Config dimuat.", "folder-open")
			else
				notify("Config", "Belum ada file config.", "alert-triangle")
			end
		end)
	end,
})
TabSet:Button({
	Title = "Reset ke Default",
	Icon = "trash-2",
	Callback = function()
		for k, v in pairs(DEFAULTS) do
			CONFIG[k] = v
		end
		for k, el in pairs(UIREF.toggle) do
			pcall(function()
				el:Set(CONFIG[k])
			end)
		end
		for k, el in pairs(UIREF.slider) do
			pcall(function()
				el:Set(CONFIG[k])
			end)
		end
		for k, el in pairs(UIREF.dropdown) do
			pcall(function()
				el:Select(CONFIG[k])
			end)
		end
		for k, el in pairs(UIREF.color) do
			pcall(function()
				el:Set(CONFIG[k])
			end)
		end
		applyMovement()
		notify("Config", "Reset ke default.", "trash-2")
	end,
})
TabSet:Section({ Title = "ℹ️ Info", Icon = "info" })
TabSet:Paragraph({
	Title = "Menu Keybind",
	Desc = "RightCtrl = buka/tutup menu\nKode terorganisir per kategori di dalam loadstring.",
})

-- ============================================================
-- [13] Init
-- ============================================================
applyMovement()
WindUI:Notify({
	Title = "100 Days Sea",
	Content = "Hub aktif. RightCtrl untuk buka menu.",
	Duration = 5,
	Icon = "anchor",
})
print("[100days] loaded OK (full hub)")
