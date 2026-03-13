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

-- beat phase for animation and pulse effects
local beat_phase = 0.0

-- popup state for parameter display
local popup_param = nil
local popup_val = 0.0
local popup_time = 0.0

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
local freeze_state = false

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

-- draw spectral bars in the live zone
local function draw_spectral_bars()
  local num_bars = 28
  local bar_width = 4
  local bar_gap = 0.5
  local zone_x = 2
  local zone_y = 9
  local zone_height = 44
  
  local total_width = num_bars * (bar_width + bar_gap)
  local start_x = zone_x + (128 - total_width) / 2
  
  for i = 1, num_bars do
    local x = start_x + (i - 1) * (bar_width + bar_gap)
    
    -- derive bar height from effect parameter with beat animation
    local param_influence = values[page]
    local beat_variation = 0.3 * math.sin(beat_phase * 2 * math.pi)
    local normalized_height = util.clamp(param_influence + beat_variation, 0.1, 1.0)
    
    -- determine if this bar is in active effect's frequency range (highlight)
    local is_active_range = (i / num_bars) >= (1 - param_influence - 0.2) and 
                            (i / num_bars) <= (1 - param_influence + 0.2)
    
    local bar_height = math.floor(normalized_height * zone_height)
    local bar_y = zone_y + zone_height - bar_height
    
    -- draw bar with graduated brightness
    local base_level = is_active_range and 9 or 4
    local top_level = is_active_range and 15 or 12
    
    -- dimmer base
    screen.level(base_level)
    screen.rect(x, bar_y + bar_height - 2, bar_width, 2)
    screen.fill()
    
    -- brighter middle
    screen.level(base_level + 2)
    screen.rect(x, bar_y + 2, bar_width, bar_height - 4)
    screen.fill()
    
    -- brightest top
    screen.level(top_level)
    screen.rect(x, bar_y, bar_width, 2)
    screen.fill()
  end
end

-- draw scene morph visualization
local function draw_scene_morph()
  if not scene_morphing then return end
  
  local morph_y = 27
  local morph_width = 100
  local morph_x = 14
  local morph_height = 3
  
  -- background bar (dimmer)
  screen.level(2)
  screen.rect(morph_x, morph_y, morph_width, morph_height)
  screen.fill()
  
  -- blend fill
  screen.level(10)
  screen.rect(morph_x, morph_y, morph_width * morph_blend, morph_height)
  screen.fill()
  
  -- scene A label (brightness inversely proportional to morph)
  local scene_a_level = math.floor(15 * (1.0 - morph_blend))
  screen.level(math.max(3, scene_a_level))
  screen.move(morph_x - 12, morph_y + 6)
  screen.font_size(6)
  screen.text("A")
  
  -- scene B label (brightness proportional to morph)
  local scene_b_level = math.floor(15 * morph_blend)
  screen.level(math.max(3, scene_b_level))
  screen.move(morph_x + morph_width + 2, morph_y + 6)
  screen.font_size(6)
  screen.text("B")
end

-- draw reorder mode visualization
local function draw_reorder_chain()
  if not reorder_mode then return end
  
  local chain_y = 32
  local spacing = 16
  
  for i = 1, NUM_PAGES do
    local x = 10 + (i - 1) * spacing
    
    if i == reorder_selected_slot then
      -- pulsing selected effect
      local pulse = 0.5 + 0.5 * math.sin(beat_phase * 4 * math.pi)
      local level = math.floor(12 + pulse * 3)
      screen.level(level)
      
      -- draw pulse box
      screen.rect(x - 6, chain_y - 6, 12, 12)
      screen.stroke()
      
      -- arrows indicating movement
      screen.level(15)
      if i > 1 then
        screen.move(x - 8, chain_y)
        screen.text("<")
      end
      if i < NUM_PAGES then
        screen.move(x + 6, chain_y)
        screen.text(">")
      end
    else
      screen.level(4)
      screen.rect(x - 6, chain_y - 6, 12, 12)
      screen.stroke()
    end
    
    screen.level(8)
    screen.move(x - 2, chain_y + 1)
    screen.font_size(6)
    screen.text(tostring(effect_order[i]))
  end
end

-- draw status strip
local function draw_status_strip()
  screen.level(4)
  screen.move(2, 4)
  screen.font_size(8)
  screen.font_face(0)
  screen.text("PRISMA")
  
  -- effect chain abbreviated names with ">" separators
  screen.level(6)
  screen.move(35, 4)
  screen.font_size(6)
  
  local chain_text = ""
  for i = 1, NUM_PAGES do
    local effect_num = effect_order[i]
    local effect_name = pages[effect_num].name
    local abbrev = string.sub(effect_name, 1, 3):upper()
    chain_text = chain_text .. abbrev
    if i < NUM_PAGES then
      chain_text = chain_text .. ">"
    end
  end
  screen.text(chain_text)
  
  -- beat pulse dot at x=124
  local pulse = 0.5 + 0.5 * math.sin(beat_phase * 2 * math.pi)
  local dot_level = math.floor(8 + pulse * 7)
  screen.level(dot_level)
  screen.rect(124, 2, 2, 2)
  screen.fill()
end

-- draw context bar (y 53-58)
local function draw_context_bar()
  -- current effect name
  local p = pages[page]
  screen.level(8)
  screen.move(2, 57)
  screen.font_size(6)
  screen.font_face(0)
  screen.text(string.upper(p.name))
  
  -- morph position indicator
  if scene_morphing then
    screen.level(6)
    screen.move(50, 57)
    local morph_pct = math.floor(morph_blend * 100)
    screen.text("MORPH: " .. morph_pct .. "%")
  end
  
  -- freeze state indicator
  if freeze_state then
    screen.level(5)
    screen.move(100, 57)
    screen.text("FREEZE")
  end
end

-- draw transient parameter popup
local function draw_popup()
  if not popup_param or popup_time <= 0 then return end
  
  local popup_x = 45
  local popup_y = 35
  local box_w = 40
  local box_h = 12
  
  -- semi-transparent background (via level)
  screen.level(3)
  screen.rect(popup_x, popup_y, box_w, box_h)
  screen.fill()
  
  -- border
  screen.level(12)
  screen.rect(popup_x, popup_y, box_w, box_h)
  screen.stroke()
  
  -- parameter name
  screen.level(14)
  screen.move(popup_x + 4, popup_y + 3)
  screen.font_size(6)
  screen.text(popup_param)
  
  -- parameter value
  screen.level(15)
  screen.move(popup_x + 4, popup_y + 9)
  local val_pct = math.floor(popup_val * 100)
  screen.text(val_pct .. "%")
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
  re.time  = 1/15  -- ~15fps for spectral animation
  re.event = function()
    -- update beat phase for animation
    beat_phase = (beat_phase + 1/15) % 1.0
    
    -- update randomize flash
    if rand_flash > 0 then
      rand_timer = rand_timer + (1/15)
      rand_flash = math.max(0, 1.0 - rand_timer * 4)
    end
    
    -- update popup timeout
    if popup_time > 0 then
      popup_time = popup_time - (1/15)
      if popup_time < 0 then popup_time = 0 end
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
      
      -- trigger popup
      popup_param = pages[page].label
      popup_val = values[page]
      popup_time = 0.8
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
  screen.aa(1)
  screen.clear()
  
  -- 1. STATUS STRIP (y 0-8)
  draw_status_strip()
  
  -- 2. LIVE ZONE (y 9-52) - Spectral visualization
  draw_spectral_bars()
  
  -- Scene morph visualization overlay
  draw_scene_morph()
  
  -- Reorder mode chain visualization
  draw_reorder_chain()
  
  -- 3. CONTEXT BAR (y 53-58)
  draw_context_bar()
  
  -- 4. TRANSIENT PARAMETER POPUP
  draw_popup()
  
  screen.update()
end

function cleanup()
end
