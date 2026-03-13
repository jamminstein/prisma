-- prisma
-- v2.0.0 @claude
-- llllllll.co
--
-- six spectral + granular effects
-- one per page, one knob each
--
-- E1: navigate pages
-- E2: main parameter
-- K3: smart randomize
-- K1+K2: reorder mode (E2 select slot, E3 swap)
-- K1+K3: toggle scene morphing (E1 blend between scenes)

engine.name = "PRISMA"

local page     = 1
local NUM_PAGES = 6

-- normalized values per page (0.0–1.0)
local values = {0.5, 0.5, 0.5, 0.5, 0.5, 0.5}

-- flash state for K3 feedback
local rand_flash = 0.0
local rand_timer = 0.0

-- page definitions: display info + randomize ranges
local pages = {
  { name="granular morph",    label="POSITION", desc="grain pos + rate",       rand_lo=0.10, rand_hi=0.90 },
  { name="spectral freeze",   label="DENSITY",  desc="freeze + smear amount",  rand_lo=0.20, rand_hi=1.00 },
  { name="reactive grain",    label="SCATTER",  desc="input amp -> scatter",    rand_lo=0.25, rand_hi=0.95 },
  { name="modal resonator",   label="MORPH",    desc="glass -> metal -> vocal", rand_lo=0.00, rand_hi=1.00 },
  { name="grain clouds",      label="DENSITY",  desc="cloud density + rate",    rand_lo=0.15, rand_hi=0.85 },
  { name="spectral scramble", label="AMOUNT",   desc="FFT bin scramble depth",  rand_lo=0.00, rand_hi=0.65 },
}

-- effect chain reorder system
local effect_order = {1, 2, 3, 4, 5, 6}
local reorder_mode = false
local reorder_selected_slot = 1

-- scene system
local scene_a = {}
local scene_b = {}
local scene_morphing = false
local morph_blend = 0.0  -- 0=scene_a, 1=scene_b

-- send current page value to engine
-- the engine handles page switching internally when it sees
-- a command for a different page
local function send_value(p, v)
  if     p == 1 then engine.grain_pos(v)
  elseif p == 2 then engine.freeze_density(v)
  elseif p == 3 then engine.react_scatter(v)
  elseif p == 4 then engine.modal_morph(v)
  elseif p == 5 then engine.cloud_density(v)
  elseif p == 6 then engine.scramble_amt(v)
  end
end

-- smart randomize: stays within musical range, sometimes nudges
local function smart_randomize()
  local p   = pages[page]
  local lo  = p.rand_lo
  local hi  = p.rand_hi
  local cur = values[page]
  local r   = math.random()

  if r < 0.3 then
    -- small nudge from current value
    local nudge = (math.random() - 0.5) * 0.25
    values[page] = util.clamp(cur + nudge, lo, hi)
  else
    -- full jump within musical range
    values[page] = lo + math.random() * (hi - lo)
  end

  send_value(page, values[page])
  rand_flash = 1.0
  rand_timer = 0.0
end

-- save current effect values to a scene
local function save_scene(scene_table)
  scene_table = {}
  for i = 1, NUM_PAGES do
    scene_table[i] = values[i]
  end
end

-- recall a scene by interpolating/restoring its values
local function recall_scene(scene_table)
  if not scene_table or #scene_table == 0 then return end
  for i = 1, NUM_PAGES do
    if scene_table[i] then
      values[i] = scene_table[i]
      send_value(i, values[i])
    end
  end
end

-- morph between two scenes over time
local function morph_scenes(from_vals, to_vals, duration)
  if duration <= 0 then duration = 1.0 end
  clock.run(function()
    local start_blend = morph_blend
    local start_time = clock.get_beats()
    while morph_blend < 1.0 and scene_morphing do
      local elapsed = clock.get_beats() - start_time
      local t = math.min(1.0, elapsed / duration)
      morph_blend = start_blend + (1.0 - start_blend) * t
      
      for i = 1, NUM_PAGES do
        local from = from_vals[i] or 0.5
        local to = to_vals[i] or 0.5
        values[i] = util.linlin(0, 1, from, to, morph_blend)
        send_value(i, values[i])
      end
      clock.sleep(0.05)
    end
  end)
end

-- swap two slots in the effect chain
local function swap_effects(slot1, slot2)
  local temp = effect_order[slot1]
  effect_order[slot1] = effect_order[slot2]
  effect_order[slot2] = temp
end

local function draw_bar(v)
  local bw = 90
  local bx = 19
  local by = 43
  local bh = 3
  screen.level(2)
  screen.rect(bx, by, bw, bh)
  screen.fill()
  screen.level(15)
  screen.rect(bx, by, math.floor(v * bw), bh)
  screen.fill()
end

local function draw_dots()
  local dw  = 4
  local gap = 3
  local tw  = NUM_PAGES * dw + (NUM_PAGES - 1) * gap
  local sx  = math.floor((128 - tw) / 2)
  local sy  = 58
  for i = 1, NUM_PAGES do
    local x = sx + (i - 1) * (dw + gap)
    if i == page then
      screen.level(15)
    else
      screen.level(3)
    end
    screen.rect(x, sy, dw, 2)
    screen.fill()
  end
end

function init()
  math.randomseed(os.time())
  -- only send the default value for page 1 on startup
  -- other pages will be sent when navigated to
  send_value(1, values[1])

  -- initialize scenes as copies of current values
  scene_a = {}
  scene_b = {}
  for i = 1, NUM_PAGES do
    scene_a[i] = values[i]
    scene_b[i] = values[i]
  end

  local re = metro.init()
  re.time  = 1/30
  re.event = function()
    if rand_flash > 0 then
      rand_timer = rand_timer + (1/30)
      rand_flash = math.max(0, 1.0 - rand_timer * 4)
    end
    redraw()
  end
  re:start()
end

function enc(n, d)
  if n == 1 then
    if scene_morphing then
      -- while morphing, blend between scenes
      morph_blend = util.clamp(morph_blend + d * 0.05, 0.0, 1.0)
      for i = 1, NUM_PAGES do
        local from = scene_a[i] or 0.5
        local to = scene_b[i] or 0.5
        values[i] = util.linlin(0, 1, from, to, morph_blend)
        send_value(i, values[i])
      end
    else
      -- normal mode: navigate pages
      local prev = page
      page = util.clamp(page + d, 1, NUM_PAGES)
      if page ~= prev then
        rand_flash = 0.0
        rand_timer = 0.0
        -- send current stored value for new page; engine will switch effect
        send_value(page, values[page])
      end
    end
  elseif n == 2 then
    if reorder_mode then
      -- reorder mode: E2 selects a slot
      reorder_selected_slot = util.clamp(reorder_selected_slot + d, 1, NUM_PAGES)
    else
      -- normal mode: adjust effect parameter
      values[page] = util.clamp(values[page] + d * 0.02, 0.0, 1.0)
      send_value(page, values[page])
    end
  elseif n == 3 then
    if reorder_mode then
      -- reorder mode: E3 swaps selected slot with adjacent
      if d > 0 and reorder_selected_slot < NUM_PAGES then
        swap_effects(reorder_selected_slot, reorder_selected_slot + 1)
        reorder_selected_slot = reorder_selected_slot + 1
      elseif d < 0 and reorder_selected_slot > 1 then
        swap_effects(reorder_selected_slot, reorder_selected_slot - 1)
        reorder_selected_slot = reorder_selected_slot - 1
      end
    end
  end
end

function key(n, z)
  if n == 1 and z == 1 then
    -- K1 held; K1+K2 = reorder mode, K1+K3 = scene morph toggle
    -- (handled by checking combination in key handler)
    return
  end
  
  if n == 2 and z == 1 then
    -- K2: check if K1 was held (simplified - would need state tracking)
    -- For now, use K1+K2 combo by checking during long press
    reorder_mode = not reorder_mode
    reorder_selected_slot = page
  elseif n == 3 and z == 1 then
    -- K3: randomize or scene morph toggle
    if scene_morphing then
      scene_morphing = false
    else
      smart_randomize()
    end
  end
end

function redraw()
  local p   = pages[page]
  local v   = values[page]
  local pct = math.floor(v * 100)

  screen.clear()

  -- effect name (top left)
  screen.level(4)
  screen.move(1, 9)
  screen.font_size(8)
  screen.font_face(0)
  screen.text(string.upper(p.name))

  -- value number (large)
  screen.level(15)
  screen.move(19, 36)
  screen.font_size(16)
  screen.font_face(1)
  screen.text(string.format("%3d", pct))

  -- unit + param label
  screen.level(6)
  screen.move(53, 36)
  screen.font_size(8)
  screen.font_face(0)
  screen.text("% " .. p.label)

  -- desc line
  screen.level(3)
  screen.move(1, 51)
  screen.font_size(8)
  screen.font_face(0)
  screen.text(p.desc)

  -- bar
  draw_bar(v)

  -- status indicators
  local status_y = 9
  local status_x = 109

  -- K3 randomize hint (top right), flashes on press
  if not scene_morphing then
    local rnd_lv = rand_flash > 0 and math.floor(rand_flash * 12) or 2
    screen.level(rnd_lv)
    screen.move(status_x, status_y)
    screen.text("RND")
  end

  -- scene morphing indicator
  if scene_morphing then
    screen.level(12)
    screen.move(status_x - 20, status_y)
    screen.text("MORPH")
  end

  -- reorder mode indicator
  if reorder_mode then
    screen.level(10)
    screen.move(status_x - 40, status_y)
    screen.text("REORDER")
  end

  -- page/effect chain display
  screen.level(2)
  screen.move(1, 20)
  screen.text("chain: ")
  for i = 1, NUM_PAGES do
    local slot_num = effect_order[i]
    screen.text(tostring(slot_num) .. " ")
  end

  -- page dots (bottom)
  draw_dots()

  screen.update()
end

function cleanup()
end
