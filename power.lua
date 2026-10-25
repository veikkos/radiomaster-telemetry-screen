-- Power monitor telemetry page: current and power (RxBt * Curr), max and average, plus a power history chart
-- Top: power (left) and current (right), big
-- Bottom-left: Max / Avg table for W and A, battery voltage/remaining %, energy and capacity used
-- Bottom-right: power history chart (peak per column)
-- Stats reset with the radio's Reset session / Reset telemetry
-- CONFIG: screen resolution (layout is designed for 128x64 and scaled for bigger screens)
local RES_X = LCD_W or 128
local RES_Y = LCD_H or 64
local SX = RES_X / 128
local SY = RES_Y / 64
local PADDING = 1

-- CONFIG: telemetry sources
local VOLTAGE_SOURCE = "RxBt"
local CURRENT_SOURCE = "Curr"
local CAPACITY_SOURCE = "Capa" -- used if available, otherwise mAh is integrated from current
local LINK_SOURCE = "RQly" -- readings only count while this is above 0, falls back to RSSI if missing
local BATTERY_PCT_SOURCE = "Bat%" -- remaining % from the current sensor (e.g. ERS-CU01 with battery capacity set), hidden if missing

-- CONFIG: Bat row blinks when remaining % is at or below this
local LOW_PERCENT = 20

-- CONFIG: averages count from the first time current reaches this (so time on the ground before takeoff doesn't dilute them)
local FLIGHT_START_CURRENT = 0.5

-- CONFIG: chart
local CHART_SECONDS = 300 -- history shown, each chart column holds the peak of CHART_SECONDS / chart width
local CHART_MIN_W = 10 -- minimum full scale of the chart

-- Layout helpers (positions are given in 128x64 coordinates)
local function X(v)
    return math.floor(v * SX + 0.5)
end

local function Y(v)
    return math.floor(v * SY + 0.5)
end

local TOP_H = Y(16)
local ROW_H = Y(8)
local STATS_Y = TOP_H + Y(2)
local COL1_R = X(40) -- right edge of W column
local COL2_R = X(67) -- right edge of A column
local CHART_X = X(70)
local CHART_W = RES_X - CHART_X - PADDING
local CHART_Y = STATS_Y + ROW_H -- first row above the chart holds the scale label
local CHART_H = RES_Y - CHART_Y - PADDING
local SAMPLE_MS = CHART_SECONDS * 1000 / CHART_W

-- State
local hist = {} -- ring buffer of power samples, one per chart column
local histHead = 0 -- index of newest sample
local histCount = 0
local samplePeak = 0 -- peak power within the current sample interval
local lastSampleTime = nil
local lastTime = nil

local maxP, maxI = 0, 0
local energyWs = 0 -- all energy used, watt-seconds
local chargeAs = 0 -- all charge used, amp-seconds
local flightStarted = false -- current has reached FLIGHT_START_CURRENT
local flightTime = 0 -- seconds with readings since the flight started
local flightEnergyWs = 0
local flightChargeAs = 0
local minV = nil

local volt, curr = nil, nil

local function resetStats()
    hist = {}
    histHead = 0
    histCount = 0
    samplePeak = 0
    lastSampleTime = nil
    maxP, maxI = 0, 0
    energyWs, chargeAs = 0, 0
    flightStarted = false
    flightTime, flightEnergyWs, flightChargeAs = 0, 0, 0
    minV = nil
end

-- Sensors keep their last value after the link drops, so check the link before trusting them
local function linkUp()
    if getFieldInfo and not getFieldInfo(LINK_SOURCE) then
        return getRSSI == nil or getRSSI() > 0
    end
    local q = getValue(LINK_SOURCE)
    return type(q) == "number" and q > 0
end

local function readSensors()
    if not linkUp() then
        return nil, nil
    end
    local v = getValue(VOLTAGE_SOURCE)
    local i = getValue(CURRENT_SOURCE)
    if type(v) ~= "number" or v <= 0 or type(i) ~= "number" then
        return nil, nil
    end
    return v, i
end

local function readCapacity()
    if getFieldInfo and not getFieldInfo(CAPACITY_SOURCE) then
        return nil
    end
    local c = getValue(CAPACITY_SOURCE)
    if type(c) == "number" and c > 0 then
        return c
    end
    return nil
end

local function readBatteryPercent()
    if not volt then
        return nil
    end
    if getFieldInfo and not getFieldInfo(BATTERY_PCT_SOURCE) then
        return nil
    end
    local pct = getValue(BATTERY_PCT_SOURCE)
    if type(pct) == "number" then
        return pct
    end
    return nil
end

local function pushSample(p)
    histHead = (histHead % CHART_W) + 1
    hist[histHead] = p
    if histCount < CHART_W then
        histCount = histCount + 1
    end
end

-- Scripts get no event for the radio's reset, but it zeroes every sensor's max,
-- so the radio's own max current (e.g. "Curr+") going down means a reset
local lastRadioMaxI = nil
local function checkRadioReset()
    local m = getValue(CURRENT_SOURCE .. "+")
    if type(m) ~= "number" then
        return
    end
    if lastRadioMaxI and m < lastRadioMaxI then
        resetStats()
    end
    lastRadioMaxI = m
end

-- Called from both run and background so stats keep accumulating while another page is shown
local function update()
    checkRadioReset()
    local now = getTime() -- 10ms ticks
    volt, curr = readSensors()
    local dt = lastTime and (now - lastTime) / 100 or 0
    lastTime = now

    if volt then
        local p = volt * curr

        if p > maxP then
            maxP = p
        end
        if curr > maxI then
            maxI = curr
        end
        if minV == nil or volt < minV then
            minV = volt
        end

        if curr >= FLIGHT_START_CURRENT then
            flightStarted = true
        end

        -- Skip integrating over long gaps (script paused, telemetry dropout)
        if dt > 0 and dt < 2 then
            energyWs = energyWs + p * dt
            chargeAs = chargeAs + curr * dt
            if flightStarted then
                flightTime = flightTime + dt
                flightEnergyWs = flightEnergyWs + p * dt
                flightChargeAs = flightChargeAs + curr * dt
            end
        end

        if p > samplePeak then
            samplePeak = p
        end
    end

    -- Chart starts with the first reading, then keeps scrolling without readings so a link loss shows as a gap
    if lastSampleTime == nil then
        if volt then
            lastSampleTime = now
        end
    elseif (now - lastSampleTime) * 10 >= SAMPLE_MS then
        pushSample(samplePeak)
        samplePeak = 0
        lastSampleTime = now
    end
end

local function fmtPower(p)
    if p == nil then
        return "--"
    end
    if p < 100 then
        return string.format("%.1f", p)
    end
    return string.format("%d", math.floor(p + 0.5))
end

local function fmtCurrent(i)
    if i == nil then
        return "--"
    end
    if i < 100 then
        return string.format("%.1f", i)
    end
    return string.format("%d", math.floor(i + 0.5))
end

local function drawRow(y, label, a, b)
    lcd.drawText(PADDING, y, label, SMLSIZE)
    lcd.drawText(COL1_R, y, a, SMLSIZE + RIGHT)
    lcd.drawText(COL2_R, y, b, SMLSIZE + RIGHT)
end

local function drawChart()
    local bottom = CHART_Y + CHART_H - 1

    -- Full scale from the visible history
    local top = CHART_MIN_W
    for k = 1, histCount do
        if hist[k] > top then
            top = hist[k]
        end
    end

    -- Scale label and history length above the chart
    if histCount > 0 then
        lcd.drawText(CHART_X, STATS_Y, fmtPower(top) .. "W", SMLSIZE)
    end
    local span = CHART_SECONDS < 60 and (CHART_SECONDS .. "s") or (math.floor(CHART_SECONDS / 60 + 0.5) .. "min")
    lcd.drawText(RES_X - PADDING, STATS_Y, span, SMLSIZE + RIGHT)

    -- Axes
    lcd.drawLine(CHART_X, CHART_Y, CHART_X, bottom, SOLID, 0)
    lcd.drawLine(CHART_X, bottom, CHART_X + CHART_W - 1, bottom, SOLID, 0)

    -- Bars, oldest on the left, newest on the right edge
    local usable = CHART_H - 1
    for k = 0, histCount - 1 do
        local idx = ((histHead - 1 - k) % CHART_W) + 1
        local h = math.floor(hist[idx] / top * usable + 0.5)
        local x = CHART_X + CHART_W - 1 - k
        if h > 0 and x > CHART_X then
            lcd.drawLine(x, bottom - 1, x, bottom - h, SOLID, 0)
        end
    end
end

local function run(event)
    update()
    lcd.clear()

    -- Power and current big, top row
    local p = volt and volt * curr or nil
    lcd.drawText(PADDING, 0, fmtPower(p) .. "W", DBLSIZE)
    lcd.drawText(RES_X - PADDING, 0, fmtCurrent(curr) .. "A", DBLSIZE + RIGHT)
    lcd.drawLine(0, TOP_H, RES_X - 1, TOP_H, SOLID, 0)

    -- Stats table
    local avgP = flightTime > 0 and flightEnergyWs / flightTime or nil
    local avgI = flightTime > 0 and flightChargeAs / flightTime or nil
    local y = STATS_Y
    drawRow(y, "", "W", "A")
    y = y + ROW_H
    -- minV is set on the first reading, until then there is no max either
    drawRow(y, "Max", minV and fmtPower(maxP) or "--", minV and fmtCurrent(maxI) or "--")
    y = y + ROW_H
    drawRow(y, "Avg", fmtPower(avgP), fmtCurrent(avgI))
    -- Battery and usage rows are anchored to the bottom, the gap separates them from the W/A table
    y = RES_Y - 2 * ROW_H
    -- Voltage now / remaining % as one value, two columns don't fit
    local batText = "--"
    local batFlags = SMLSIZE
    if volt then
        local pct = readBatteryPercent()
        if pct then
            batText = string.format("%.1fV/%d%%", volt, math.floor(pct + 0.5))
        else
            batText = string.format("%.2fV", volt)
        end
        if pct and pct <= LOW_PERCENT then
            batFlags = batFlags + BLINK
        end
    end
    lcd.drawText(PADDING, y, "Bat", batFlags)
    lcd.drawText(COL2_R, y, batText, batFlags + RIGHT)
    y = y + ROW_H
    -- Energy and capacity used, no label so the values get the full width
    local wh = energyWs / 3600
    local whText = wh < 10 and string.format("%.1fWh", wh) or string.format("%dWh", math.floor(wh + 0.5))
    local mah = readCapacity() or chargeAs / 3.6
    lcd.drawText(PADDING, y, whText, SMLSIZE)
    lcd.drawText(COL2_R, y, string.format("%dmAh", math.floor(mah + 0.5)), SMLSIZE + RIGHT)

    drawChart()

    return 0
end

return {
    run = run,
    background = update
}
