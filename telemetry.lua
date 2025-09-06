-- Simple telemetry page showing mode text from a source.
-- Place at /SCRIPTS/TELEMETRY/mode.lua

-- CONFIG: change "srcName" to your input (e.g., "ch5" or "sa")
local srcName  = "ch6"
local LOW_LBL  = "Gyro"
local MID_LBL  = "3D"
local HIGH_LBL = "Manual"
local LOW_RAW  = -500   -- -50%
local HIGH_RAW =  500   -- +50%
local DEAD_RAW =  100   -- 10% deadband around 0

local function pickLabel(v)
  if v <= LOW_RAW then return LOW_LBL end
  if v >= HIGH_RAW then return HIGH_LBL end
  if math.abs(v) <= DEAD_RAW then return MID_LBL end
  return (v < 0) and LOW_LBL or HIGH_LBL
end

local function run(event)
  local v = getValue(srcName) or 0 -- raw -1000..1000
  local label = pickLabel(v)

  lcd.clear()
  lcd.drawText(4, 4, "MODE", 0)
  lcd.drawText(32, 4, label, 0)

  return 0
end

return { run = run }
