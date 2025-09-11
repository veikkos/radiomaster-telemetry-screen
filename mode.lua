-- Telemetry page showing battery voltage, signal quality (stacked), flight mode, and timer 1
-- Top-right: upper = battery %, lower = signal quality (if available; falls back to RSSI)
-- CONFIG: screen resolution
local RES_X = 128
local RES_Y = 64
local PADDING = 5
local PADDING_B = 20

-- CONFIG: Model with
local BEECH_MODEL_NAME = "Beech"

-- CONFIG: Battery telemetry sources
local BATTERY_SOURCE_BEECH = "A1"
local BATTERY_SOURCE_GENERIC = "RxBt"

-- CONFIG: flight mode source
local MODE_SRC = "ch6"
local LOW_LBL = "Gyro"
local MID_LBL = "3D"
local HIGH_LBL = "Manual"
local LOW_RAW = -500
local HIGH_RAW = 500
local DEAD_RAW = 100

-- CONFIG: cell count override (set to nil for auto-detect)
local CELL_COUNT = nil

-- MOCK CONFIG
local USE_MOCK = false
local MOCK_BAT = 4.074 * 2
local MOCK_RSSI = 92 -- also used as mock signal quality if RQly not present
local MOCK_MODE = 0 -- Try -600, 0, or 600 for Gyro/3D/Manual
local MOCK_TIMER = 123 -- seconds

-- Per-cell voltage to percentage lookup table
local lipoPercent = {{3.000, 0}, {3.196, 2}, {3.401, 4}, {3.544, 6}, {3.637, 8}, {3.679, 10}, {3.689, 12}, {3.705, 14},
                     {3.713, 16}, {3.720, 18}, {3.735, 20}, {3.753, 22}, {3.758, 24}, {3.767, 26}, {3.780, 28},
                     {3.786, 30}, {3.794, 32}, {3.800, 34}, {3.805, 36}, {3.811, 38}, {3.818, 40}, {3.825, 42},
                     {3.833, 44}, {3.840, 46}, {3.847, 48}, {3.854, 50}, {3.860, 52}, {3.866, 54}, {3.874, 56},
                     {3.888, 58}, {3.897, 60}, {3.906, 62}, {3.918, 64}, {3.928, 66}, {3.943, 68}, {3.955, 70},
                     {3.968, 72}, {3.981, 74}, {3.994, 76}, {4.007, 78}, {4.021, 80}, {4.036, 82}, {4.052, 84},
                     {4.074, 86}, {4.095, 88}, {4.111, 90}, {4.120, 92}, {4.129, 94}, {4.145, 96}, {4.179, 98},
                     {4.200, 100}}

-- Helpers
local function lerp(a, b, t)
    return a + (b - a) * t
end

-- Convert per-cell voltage to a percentage using the table with linear interpolation
local function cellVoltageToPercent(v)
    if not v then
        return nil
    end
    local n = #lipoPercent
    if v <= lipoPercent[1][1] then
        return lipoPercent[1][2]
    end
    if v >= lipoPercent[n][1] then
        return lipoPercent[n][2]
    end
    for i = 1, n - 1 do
        local v1, p1 = lipoPercent[i][1], lipoPercent[i][2]
        local v2, p2 = lipoPercent[i + 1][1], lipoPercent[i + 1][2]
        if v >= v1 and v <= v2 then
            local t = (v - v1) / (v2 - v1)
            return math.floor(lerp(p1, p2, t) + 0.5)
        end
    end
    return nil
end

local function pickLabel(v)
    if v <= LOW_RAW then
        return LOW_LBL
    end
    if v >= HIGH_RAW then
        return HIGH_LBL
    end
    if math.abs(v) <= DEAD_RAW then
        return MID_LBL
    end
    return (v < 0) and LOW_LBL or HIGH_LBL
end

-- Try to get a link-quality style metric; fall back to RSSI
-- Common sensors: "RQly" (ELRS/CRSF), "RSNR" (ELRS), "SNR", "RSSI"
local function readSignalQuality()
    if USE_MOCK then
        return "RSSI", MOCK_RSSI, "%"
    end
    local rqly = getValue("RQly")
    if rqly ~= nil and rqly ~= false and rqly > 0 then
        return "RQly", rqly, "%"
    end
    local rsnr = getValue("RSNR")
    if rsnr ~= nil and rsnr ~= false and rsnr > 0 then
        return "RSNR", rsnr, "dB"
    end
    local snr = getValue("SNR")
    if snr ~= nil and snr ~= false and snr > 0 then
        return "SNR", snr, "dB"
    end
    local rssi = getValue("RSSI")
    if rssi ~= nil and rssi ~= false and rssi > 0 then
        return "RSSI", rssi, "dB"
    end
    return nil, nil, nil
end

local MODEL_NAME
local function getModelName()
    if FORCE_MODEL_NAME ~= nil then
        return FORCE_MODEL_NAME
    end
    if MODEL_NAME ~= nil then
        return MODEL_NAME
    end
    -- OpenTX/EdgeTX: model.getInfo().name
    if model and model.getInfo then
        local info = model.getInfo()
        if info and info.name and #info.name > 0 then
            MODEL_NAME = info.name
            return MODEL_NAME
        end
    end
    -- EdgeTX alt API: radio.getModelName()
    if radio and radio.getModelName then
        local n = radio.getModelName()
        if n and #n > 0 then
            MODEL_NAME = n
            return MODEL_NAME
        end
    end
    MODEL_NAME = ""
    return MODEL_NAME
end

-- Auto cell count detection (cached)
local DETECTED_CELL_COUNT = nil
local function getCellCount(voltage)
    if CELL_COUNT ~= nil then
        return CELL_COUNT
    end
    if DETECTED_CELL_COUNT ~= nil then
        return DETECTED_CELL_COUNT
    end
    if not voltage or voltage <= 0 then
        return nil
    end

    -- Guess between 1S and 6S
    local bestCount, bestDiff = nil, 999
    for cells = 1, 6 do
        local perCell = voltage / cells
        local diff = math.abs(perCell - 3.9) -- assume mid-discharge reference ~3.9V/cell
        if diff < bestDiff then
            bestDiff = diff
            bestCount = cells
        end
    end
    DETECTED_CELL_COUNT = bestCount
    return bestCount
end

local function run(event)
    lcd.clear()

    local name = getModelName()

    -- Battery voltage (configurable source) big, top-left
    local isBeech = (name == BEECH_MODEL_NAME)
    local batterySource = isBeech and BATTERY_SOURCE_BEECH or BATTERY_SOURCE_GENERIC
    local bat = USE_MOCK and MOCK_BAT or getValue(batterySource)
    local batText = "--"
    if bat and bat > 0 then
        if isBeech then
            batText = bat >= 8 and "OK" or "LOW"
        else
            batText = string.format("%.2fV", bat)
        end
    end
    lcd.drawText(PADDING, PADDING, batText, DBLSIZE)

    -- Compute battery percent (top-right upper, small)
    local pctText = "--%"
    if bat then
        if isBeech then
            -- XK2 "Beech" has no battery %, show model name instead
            pctText = name
        else
            -- Generic model - use cell detection and percentage
            local cells = getCellCount(bat)
            if cells and cells > 0 then
                local cellV = bat / cells
                local pct = cellVoltageToPercent(cellV)
                if pct then
                    pctText = "Bat (" .. tostring(cells) .. "S) " .. tostring(pct) .. "%"
                end
            end
        end
    end
    lcd.drawText(RES_X - PADDING, PADDING, pctText, RIGHT)

    -- Signal quality (top-right lower, small)
    local type, sig, unit = readSignalQuality()
    local sigText = sig and (type .. " " .. tostring(math.floor(sig + 0.5)) .. (unit or "")) or "--"
    lcd.drawText(RES_X - PADDING, PADDING_B, sigText, RIGHT)

    -- Flight mode or model name big, bottom-left
    local v = USE_MOCK and MOCK_MODE or (getValue(MODE_SRC) or 0)
    local label = pickLabel(v)
    -- If the model name is exactly "Beech", show flight mode; otherwise show model name
    local bottomLeftText = (name == BEECH_MODEL_NAME or name == nil or name == "") and label or name
    lcd.drawText(PADDING, RES_Y - PADDING_B, bottomLeftText, DBLSIZE)

    -- Timer 1 big, bottom-right (MM:SS)
    local timer = USE_MOCK and MOCK_TIMER or getValue("timer1")
    local timerText = "--:--"
    if timer then
        local min = math.floor(timer / 60)
        local sec = math.floor(timer % 60)
        timerText = string.format("%02d:%02d", min, sec)
    end
    lcd.drawText(RES_X - 45, RES_Y - PADDING_B, timerText, DBLSIZE)

    return 0
end

return {
    run = run
}
