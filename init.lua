-- CursorTrail lua script for EQ+MQ
-- All particle drawing logic borrowed from im_anim_demo.cpp.
-- Usage: /lua run cursortrail
-- Configuration: /cursortrail

local mq = require('mq')
local imgui = require('ImGui')
local iam = require('ImAnim')

local openGUI, showGUI = false, false
local show_debug_window = false
local s_open_all = 0
local imguiIO = imgui.GetIO()

local configFile = string.format('%s/CursorTrail.lua', mq.configDir)

-- === COLORS ===
local CYAN = IM_COL32(91, 194, 231, 255)
local CORAL = IM_COL32(204, 120, 88, 255)
local TEAL = IM_COL32(100, 220, 180, 255)
local PURPLE = IM_COL32(160, 120, 200, 255)
local GOLD = IM_COL32(230, 190, 90, 255)

local CursorTrailSettings = {
    Colors = { {Label='Cyan',On=true,Color=CYAN}, {Label='Coral',On=true,Color=CORAL}, {Label='Teal',On=true,Color=TEAL}, {Label='Purple',On=true,Color=PURPLE}, {Label='Gold',On=true,Color=GOLD}, },
    Shapes = { {Label='Circle',On=true}, {Label='Ellipse',On=true}, {Label='Rectangle',On=true}, },
    Size = 6,
    Life = 0.8,
    NumParticles = 64,
}

local function GetSafeDeltaTime()
    local dt = imgui.GetIO().DeltaTime
    if dt <= 0 then dt = 1.0 / 60.0 end
    if dt > 0.1 then dt = 0.1 end
    return dt
end

---@enum ParticleShape
local ParticleShape = {
    'Circle',
    'Rectangle',
    'Ellipse',
}

---@class Particle
---@field pos ImVec2
---@field vel ImVec2
---@field life number
---@field max_life number
---@field size number
---@field shape ParticleShape
---@field angle number
---@field spin number
---@field color_idx number

---@return Particle
local function CreateParticle()
    return {
        pos = ImVec2(0, 0),
        vel = ImVec2(0, 0),
        life = 0,
        max_life = 0,
        size = 0,
        shape = 0,
        angle = 0,
        spin = 0,
        color_idx = 0
    }
end

---@return Particle[]
local function CreateParticles(count)
    local particles = {}
    for i = 1, count do
        table.insert(particles, CreateParticle())
    end
    return particles
end

---@param dl ImDrawList
---@param ctr ImVec2
---@param size ImVec2
---@param angle number
---@param fill ImU32
---@param border ImU32
local function DrawRotatedRect(dl, ctr, size, angle, fill, border)
    local c = math.cos(angle)
    local s = math.sin(angle)
    local corners = {
        ImVec2(-size.x * 0.5, -size.y * 0.5),
        ImVec2( size.x * 0.5, -size.y * 0.5),
        ImVec2( size.x * 0.5,  size.y * 0.5),
        ImVec2(-size.x * 0.5,  size.y * 0.5)
    }
    local pts = {
        ImVec2(ctr.x + corners[1].x * c - corners[1].y * s, ctr.y + corners[1].x * s + corners[1].y * c),
        ImVec2(ctr.x + corners[2].x * c - corners[2].y * s, ctr.y + corners[2].x * s + corners[2].y * c),
        ImVec2(ctr.x + corners[3].x * c - corners[3].y * s, ctr.y + corners[3].x * s + corners[3].y * c),
        ImVec2(ctr.x + corners[4].x * c - corners[4].y * s, ctr.y + corners[4].x * s + corners[4].y * c),
    }

    dl:AddConvexPolyFilled(pts, fill)
    if bit32.band(border, 0xff000000) > 0 then
        dl:AddPolyline(pts, border, ImDrawFlags.Closed, 1.5)
    end
end

---@param dl ImDrawList
---@param ctr ImVec2
---@param radii ImVec2
---@param angle number
---@param fill ImU32
---@param segments? number
local function DrawRotatedEllipse(dl, ctr, radii, angle, fill, segments)
    local c = math.cos(angle)
    local s = math.sin(angle)
    segments = segments or 32
    local pts = {}
    for i = 1, segments do
        local a = i / segments * math.pi * 2.0
        local lx = math.cos(a) * radii.x
        local ly = math.sin(a) * radii.y
        table.insert(pts, ImVec2(ctr.x + lx * c - ly * s, ctr.y + lx * s + ly * c))
    end

    dl:AddConvexPolyFilled(pts, fill)
end

local Animation_State = {
    T = 0,
    particles = CreateParticles(CursorTrailSettings.NumParticles),
    particle_count = 0,
    last_mouse = ImVec2(0, 0),
    spawn_accum = 0,
    colors = { CYAN, CORAL, TEAL, PURPLE, GOLD, },
    hover_anim = 0.0,
    was_hovered = false,
}

local function ColorAlpha(col, a)
    return bit32.bor(bit32.band(col, 0xffffff), bit32.lshift(a, 24))
end

local function DrawCursorTrail()
    local state = Animation_State

    local dt = GetSafeDeltaTime()
    state.T = state.T + dt

    local CYCLE = 10
    local t = math.fmod(state.T, CYCLE)

    local dl = imgui.GetForegroundDrawList()
    local cp = imgui.GetCursorScreenPosVec()
    local cs = ImVec2(imguiIO.DisplaySize.x, imguiIO.DisplaySize.y)

    -- === MOUSE TRAIL: Spawn particles when mouse moves inside hero area ===
    do
        local mouse = imgui.GetMousePosVec()
        local in_area = mouse.x >= 0 and mouse.x <= cs.x and mouse.y >= 0 and mouse.y <= cs.y

        if in_area then
            local dx = mouse.x - state.last_mouse.x
            local dy = mouse.y - state.last_mouse.y
            local dist = math.sqrt(dx * dx + dy * dy)

            -- Skip if mouse teleported (e.g., screen capture tool, window switching)
            if dist > 200 then
                state.last_mouse = mouse
                state.spawn_accum = 0
            end

            state.spawn_accum = state.spawn_accum + dist
            local SPAWN_DIST = 15

            local spawned = 0
            local MAX_SPAWN_PER_FRAME = 4

            while state.spawn_accum >= SPAWN_DIST and spawned < MAX_SPAWN_PER_FRAME do
                spawned = spawned + 1
                state.spawn_accum = state.spawn_accum - SPAWN_DIST

                -- Find free slot (expired particle) or use oldest
                local slot = -1
                local oldest_ratio = -1
                local oldest_slot = 1

                for i = 1, CursorTrailSettings.NumParticles do
                    -- Check if particle is dead/expired
                    if state.particles[i].max_life <= 0 or state.particles[i].life >= state.particles[i].max_life then
                        slot = i
                        break
                    end
                    -- Track oldest
                    local ratio = state.particles[i].life / state.particles[i].max_life
                    if ratio > oldest_ratio then
                        oldest_ratio = ratio
                        oldest_slot = i
                    end
                end
                if slot < 0 then
                    slot = oldest_slot -- Reuse oldest if no free slot
                end

                local p = state.particles[slot]
                p.pos = mouse
                -- Velocity: perpendicular to movement + some randomness
                local spread = ((slot % 7) - 3) * 0.5
                local speed = 30 + (slot % 5) * 15
                p.vel = ImVec2(-dy * 0.3 + spread * 20, dx * 0.3 + (slot % 3 - 1) * 30)
                p.vel.x = p.vel.x + ((slot * 7) % 11 - 5) * 8.0
                p.vel.y = p.vel.y - speed * 0.5 -- slight upward bias
                p.life = 0
                p.max_life = CursorTrailSettings.Life + (slot % 4) * 0.2
                p.size = CursorTrailSettings.Size + (slot % 5) * 3.0
                p.shape = (slot % #ParticleShape) + 1
                p.angle = (slot % 10) * .0628
                p.spin = ((slot % 7) - 3) * 2.0
                p.color_idx = (slot % #Animation_State.colors) + 1
            end
        end

        state.last_mouse = mouse

        -- Update and render particles
        for i = 1, CursorTrailSettings.NumParticles do
            local p = state.particles[i]
            if p.life < p.max_life and p.max_life > 0 then
                p.life = p.life + dt
                local lt = p.life / p.max_life

                -- Physics
                p.pos.x = p.pos.x + p.vel.x * dt
                p.pos.y = p.pos.y + p.vel.y * dt
                p.vel.y = p.vel.y + 80.0 * dt -- gravity
                p.vel.x = p.vel.x * 0.98 -- drag
                p.vel.y = p.vel.y * 0.98
                p.angle = p.angle + p.spin * dt

                -- Render with eased alpha and scale
                local alpha = 1.0 - iam.EvalPreset(IamEaseType.InQuad, lt)
                local scale = iam.EvalPreset(IamEaseType.OutBack, math.min(lt * 5.0, 1.0)) * (1.0 - lt * 0.3)
                local a = math.modf(alpha * 200)

                if a > 5 and p.pos.x >= 0 and p.pos.x <= cp.x + cs.x and p.pos.y >= 0 and p.pos.y <= cp.y + cs.y then
                    local col = ColorAlpha(state.colors[p.color_idx], a)
                    local sz = p.size * scale
                    if ParticleShape[p.shape] == 'Circle' then
                        dl:AddCircleFilled(p.pos, sz, col, 0)
                    elseif ParticleShape[p.shape] == 'Rectangle' then
                        DrawRotatedRect(dl, p.pos, ImVec2(sz * 1.4, sz * 0.6), p.angle, col, 0)
                    elseif ParticleShape[p.shape] == 'Ellipse' then
                        DrawRotatedEllipse(dl, p.pos, ImVec2(sz, sz * 0.6), p.angle, col)
                    end
                end
            end
        end
    end
end

local function UpdateSelectedColors()
    Animation_State.colors = {}
    for _,color in ipairs(CursorTrailSettings.Colors) do
        if color.On then
            table.insert(Animation_State.colors, color.Color)
        end
    end
end

local function UpdateSelectedShapes()
    ParticleShape = {}
    for _,shape in ipairs(CursorTrailSettings.Shapes) do
        if shape.On then
            table.insert(ParticleShape, shape.Label)
        end
    end
end

local windowbg = ImVec4(.1, .1, .1, .9)
local bg = ImVec4(0, 0, 0, 1)
local hovered = ImVec4(.4, .4, .4, 1)
local active = ImVec4(.3, .3, .3, 1)
local button = ImVec4(.3, .3, .3, 1)
local text = ImVec4(1, 1, 1, 1)

local function DrawCursorTrailUI()
    DrawCursorTrail()
    if not openGUI then
        return
    end

    ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, 5.0)
    ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, 3.0)
    ImGui.PushStyleVar(ImGuiStyleVar.Alpha, 0.8)
    ImGui.PushStyleColor(ImGuiCol.WindowBg, windowbg)
    ImGui.PushStyleColor(ImGuiCol.TitleBg, bg)
    ImGui.PushStyleColor(ImGuiCol.TitleBgActive, active)
    ImGui.PushStyleColor(ImGuiCol.FrameBg, bg)
    ImGui.PushStyleColor(ImGuiCol.FrameBgHovered, hovered)
    ImGui.PushStyleColor(ImGuiCol.FrameBgActive, active)
    ImGui.PushStyleColor(ImGuiCol.Button, button)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, hovered)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, active)
    ImGui.PushStyleColor(ImGuiCol.Text, text)
    ImGui.PushStyleColor(ImGuiCol.CheckMark, text)
    ImGui.PushStyleColor(ImGuiCol.SliderGrab, button)
    ImGui.PushStyleColor(ImGuiCol.SliderGrabActive, active)

    openGUI, showGUI = ImGui.Begin('CursorTrail', openGUI, bit32.bor(ImGuiWindowFlags.AlwaysAutoResize, ImGuiWindowFlags.NoFocusOnAppearing))
    if showGUI then
        if ImGui.Button('Save') then
            mq.pickle(configFile, CursorTrailSettings)
        end
        ImGui.SameLine()
        local resetAll = false
        if ImGui.Button('Reset') then
            CursorTrailSettings.NumParticles = 64
            CursorTrailSettings.Life = 0.8
            CursorTrailSettings.Size = 6.0
            for _,color in ipairs(CursorTrailSettings.Colors) do color.On = true end
            for _,shape in ipairs(CursorTrailSettings.Shapes) do shape.On = true end
            resetAll = true
        end
        local numParticlesTmp, changed = ImGui.SliderInt('Num Particles', CursorTrailSettings.NumParticles, 16, 128)
        if changed or resetAll then
            CursorTrailSettings.NumParticles = numParticlesTmp
            Animation_State.particles = CreateParticles(CursorTrailSettings.NumParticles)
        end
        local lifeTmp, changed = ImGui.SliderFloat('Max Life', CursorTrailSettings.Life, 0.1, 5.0)
        if changed or resetAll then
            CursorTrailSettings.Life = lifeTmp
        end
        local sizeTmp, changed = ImGui.SliderFloat('Size', CursorTrailSettings.Size, 1.0, 18.0)
        if changed or resetAll then
            CursorTrailSettings.Size = sizeTmp
        end
        ImGui.Text('Colors:')
        local updateColors = false
        for _,color in ipairs(CursorTrailSettings.Colors) do
            local colorOn, changed = ImGui.Checkbox(color.Label, color.On)
            if changed then
                color.On = colorOn
                updateColors = true
            end
            ImGui.SameLine()
        end
        if updateColors or resetAll then
            UpdateSelectedColors()
        end
        ImGui.NewLine()
        ImGui.Text('Shapes:')
        local updateShapes = false
        for _,shape in ipairs(CursorTrailSettings.Shapes) do
            local shapeOn, changed = ImGui.Checkbox(shape.Label, shape.On)
            if changed then
                shape.On = shapeOn
                updateShapes = true
            end
            ImGui.SameLine()
        end
        if updateShapes or resetAll then
            UpdateSelectedShapes()
        end
    end
    ImGui.End()
    ImGui.PopStyleVar(3)
    ImGui.PopStyleColor(13)
end

local function FileExists(file_name)
    local f = io.open(file_name, "r")
    if f ~= nil then io.close(f) return true else return false end
end

if FileExists(configFile) then
    local loadConfig = loadfile(configFile)()
    CursorTrailSettings.Life = loadConfig.Life
    CursorTrailSettings.Size = loadConfig.Size
    CursorTrailSettings.NumParticles = loadConfig.NumParticles
    for i,color in ipairs(loadConfig.Colors) do CursorTrailSettings.Colors[i].On = color.On end
    UpdateSelectedColors()
    for i,shape in ipairs(loadConfig.Shapes) do CursorTrailSettings.Shapes[i].On = shape.On end
    UpdateSelectedShapes()
end

imgui.Register('CursorTrail', DrawCursorTrailUI)

local function CursorTrailBind()
    openGUI, showGUI = true, true
end

mq.bind('/cursortrail', CursorTrailBind)

while true do
    mq.delay(1000)
end
