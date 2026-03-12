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
    local prev = page
    page = util.clamp(page + d, 1, NUM_PAGES)
    if page ~= prev then
      rand_flash = 0.0
      rand_timer = 0.0
      -- send current stored value for new page; engine will switch effect
      send_value(page, values[page])
    end
  elseif n == 2 then
    values[page] = util.clamp(values[page] + d * 0.02, 0.0, 1.0)
    send_value(page, values[page])
  end
end

function key(n, z)
  if n == 3 and z == 1 then
    smart_randomize()
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

  -- K3 randomize hint (top right), flashes on press
  local rnd_lv = rand_flash > 0 and math.floor(rand_flash * 12) or 2
  screen.level(rnd_lv)
  screen.move(109, 9)
  screen.text("RND")

  -- page dots (bottom)
  draw_dots()

  screen.update()
end

function cleanup()
end
