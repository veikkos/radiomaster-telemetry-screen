-- Telemetry page showing battery voltage, RSSI, flight mode, and timer 1 (no labels).

-- CONFIG: screen resolution
local RES_X = 128
local RES_Y = 64

-- CONFIG: flight mode source
local srcName  = "ch6"
local LOW_LBL  = "Gyro"
local MID_LBL  = "3D"
local HIGH_LBL = "Manual"
local LOW_RAW  = -500
local HIGH_RAW =  500
local DEAD_RAW =  100

-- MOCK CONFIG
local USE_MOCK = false

local MOCK_BAT   = 11.85
local MOCK_RSSI  = 92
local MOCK_MODE  = 0    -- Try -600, 0, or 600 for Gyro/3D/Manual
local MOCK_TIMER = 123  -- seconds

local function pickLabel(v)
  if v <= LOW_RAW then return LOW_LBL end
  if v >= HIGH_RAW then return HIGH_LBL end
  if math.abs(v) <= DEAD_RAW then return MID_LBL end
  return (v < 0) and LOW_LBL or HIGH_LBL
end

local function run(event)
  lcd.clear()

  -- Top left: Battery voltage (RxBt)
  local bat = USE_MOCK and MOCK_BAT or getValue("RxBt")
  lcd.drawText(10, 10, bat and string.format("%.2fV", bat) or "--", DBLSIZE)

  -- Top right: RSSI (dB)
  local rssi = USE_MOCK and MOCK_RSSI or getValue("RSSI")
  local rssiText = rssi and (tostring(rssi) .. " dB") or "--"
  lcd.drawText(RES_X - 50, 10, rssiText, DBLSIZE)

  -- Bottom left: Flight mode
  local v = USE_MOCK and MOCK_MODE or (getValue(srcName) or 0)
  local label = pickLabel(v)
  lcd.drawText(10, RES_Y - 28, label, DBLSIZE)

  -- Bottom right: Timer 1 (MM:SS)
  local timer = USE_MOCK and MOCK_TIMER or getValue("timer1")
  local timerText = "--:--"
  if timer then
    local min = math.floor(timer / 60)
    local sec = math.floor(timer % 60)
    timerText = string.format("%02d:%02d", min, sec)
  end
  lcd.drawText(RES_X - 50, RES_Y - 28, timerText, DBLSIZE)

  return 0
end

return { run = run }
