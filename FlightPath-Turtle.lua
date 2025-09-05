local addonName = "FlightPath-Turtle"
local addon = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0", "AceConfig-3.0", "AceHook-3.0")

-- Default database structure
local defaults = {
    char = {
        flightTimes = {},
        flightCosts = {},
        statistics = {
            totalFlights = 0,
            totalTime = 0,
            totalCost = 0,
            longestFlightTime = 0,
            longestFlightPath = "",
        },
        options = {
            autoDismount = true,
            confirmFlights = false,
            showTimer = true,
			announceETA = false,
        },
        timerPosition = {
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = 200,
        }
    }
}

-- Variables
local flightStartTime = 0
local currentFlightFromIndex = 0
local currentFlightToIndex = 0
local pendingFlightCost = nil
local lastClickedTaxiNode = nil
local currentTaxiNodeName = nil
local isConfirming = false
local flightPending = false
local isInFlight = false
local optionsFrame = nil
local isTooltipHooked = false

function addon:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("FlightPathTurtleDB", defaults, "char")

    self:RegisterChatCommand("fp", "ChatCommand")
    self:RegisterChatCommand("flightpath", "ChatCommand")

    self:CreateFlightTimer()
    self:CreateOptionsUI()
    self:CreateUpdateFrame()

    self:Print("Loaded. Type /fp to configure.")
end

function addon:OnEnable()
    self:RegisterEvent("TAXIMAP_OPENED", "OnTaxiMapOpened")
    self:RegisterEvent("TAXIMAP_CLOSED", "OnTaxiMapClosed")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnPlayerEnteringWorld")

    self:RawHook("TakeTaxiNode", "OnTakeTaxiNode", true)
end

function addon:OnDisable()
    self:UnregisterAllEvents()
end

function addon:OnTaxiMapOpened()
	if not isTooltipHooked then
		self:RawHook("TaxiNodeOnButtonEnter", "OnTaxiNodeEnter", true)
		isTooltipHooked = true
	end
	
    if self.db.char.options.autoDismount and IsMounted and IsMounted() then
        Dismount()
    end
    
    local currentNodeIndex = GetCurrentTaxiNode and GetCurrentTaxiNode()
    if not currentNodeIndex then return end

    currentTaxiNodeName = TaxiNodeName(currentNodeIndex)
    
    if not currentTaxiNodeName then return end
end

function addon:OnTakeTaxiNode(nodeIndex)
    local originNodeIndex = 0
    for i = 1, NumTaxiNodes() do
        if TaxiNodeGetType(i) == "CURRENT" then
            originNodeIndex = i
            break
        end
    end

    if originNodeIndex == 0 then return end

    currentFlightFromIndex = originNodeIndex
    currentFlightToIndex = nodeIndex
    pendingFlightCost = TaxiNodeCost(nodeIndex)
    lastClickedTaxiNode = nodeIndex

    if self.db.char.options.confirmFlights and not isConfirming then
        StaticPopup_Show("FLIGHTPATH_TURTLE_CONFIRM", TaxiNodeName(nodeIndex) or "Unknown", self:FormatMoney(pendingFlightCost or 0))
        return
    end

    isConfirming = false
    flightPending = true
	self.startFlightMonitoring()

    return self.hooks.TakeTaxiNode(nodeIndex)
end

function addon:OnPlayerEnteringWorld()
    if isInFlight and not UnitOnTaxi("player") then
        self:RecordFlight()
    end
end

function addon:OnTaxiMapClosed()
    if isTooltipHooked then
        self:Unhook("TaxiNodeOnButtonEnter")
        isTooltipHooked = false
    end
    
    self:ScheduleTimer(function()
        if not isInFlight then
            currentTaxiNodeName = nil
        end
    end, 1)
end

function addon:OnTaxiNodeEnter(button)
    self.hooks.TaxiNodeOnButtonEnter(button)

    local nodeIndex = button:GetID()
    local nodeType = TaxiNodeGetType(nodeIndex)

    if nodeType == "CURRENT" then
        return
    end

    local destination = TaxiNodeName(nodeIndex)
    local origin = nil

    for i = 1, NumTaxiNodes() do
        if TaxiNodeGetType(i) == "CURRENT" then
            origin = TaxiNodeName(i)
            break
        end
    end
	
	local timeText

    if origin and destination and self.db.char.flightTimes[origin] and self.db.char.flightTimes[origin][destination] then
        local flightTime = self.db.char.flightTimes[origin][destination]
		timeText = self:FormatTimeTooltip(flightTime)
	else
		timeText = "--:--"
	end

    GameTooltip:AddLine("Flight Time: " .. timeText, 0.7, 0.7, 0.7)

    GameTooltip:Show()
end

function addon:StartFlight(from, to, cost)
    flightStartTime = GetTime()
	
	local fromTimes = self.db.char.flightTimes[from]
	local knownTime = fromTimes and fromTimes[to]

    local knownTime
    if self.db.char.flightTimes[from] and self.db.char.flightTimes[from][to] then
        knownTime = self.db.char.flightTimes[from][to]
    end

    -- Announce ETA to Party or Raid
    if self.db.char.options.announceETA then
        local chatChannel = nil
        if GetNumRaidMembers() > 0 then
            chatChannel = "RAID"
        elseif GetNumPartyMembers() > 0 then
            chatChannel = "PARTY"
        end

        if chatChannel then
            local etaText
            if knownTime and knownTime > 0 then
                etaText = "ETA: " .. self:FormatTime(knownTime)
            else
                etaText = "ETA: (Timing...)"
            end
            SendChatMessage("Flying to " .. (to or "Unknown") .. ". " .. etaText, chatChannel)
        end
    end

    if self.db.char.options.showTimer then
        local timer = FlightPathTurtleTimer
        timer:Show()
        timer.from = from
        timer.to = to
        timer.startTime = flightStartTime
        timer.duration = knownTime or 0
        timer.cost = cost

        local destinationName = to or "Unknown"
        local zoneName = ""

        local commaPosition = string.find(destinationName, ", ")
        if commaPosition then
            zoneName = string.sub(destinationName, commaPosition + 2)
            destinationName = string.sub(destinationName, 1, commaPosition - 1)
        end
        
        local timingText = ""
        if not knownTime then
            timingText = " (Timing...)"
        end

        timer.text:SetText("To: " .. destinationName .. timingText)
        timer.zone:SetText(zoneName)
    end
end

function addon:RecordFlight()
    local fromName = TaxiNodeName(currentFlightFromIndex)
    local toName = TaxiNodeName(currentFlightToIndex)

    if not fromName or not toName or flightStartTime == 0 then
        self:ResetFlightState()
        return
    end

    local flightDuration = GetTime() - flightStartTime
    local cost = pendingFlightCost or 0

    if flightDuration < 3 then
        self:ResetFlightState()
        return
    end

    if not self.db.char.flightTimes[fromName] then
        self.db.char.flightTimes[fromName] = {}
    end
    self.db.char.flightTimes[fromName][toName] = flightDuration

    if not self.db.char.flightCosts[fromName] then
        self.db.char.flightCosts[fromName] = {}
    end
    self.db.char.flightCosts[fromName][toName] = cost

    local stats = self.db.char.statistics
    stats.totalFlights = stats.totalFlights + 1
    stats.totalTime = stats.totalTime + flightDuration
    stats.totalCost = stats.totalCost + cost

    if flightDuration > stats.longestFlightTime then
        stats.longestFlightTime = flightDuration
        stats.longestFlightPath = fromName .. " -> " .. toName
    end

    self:Print("Flight completed: " .. fromName .. " -> " .. toName .. " (" .. self:FormatTime(flightDuration) .. ", " .. self:FormatMoney(cost) .. ")")

    self:ResetFlightState()
end

function addon:ResetFlightState()
    flightStartTime = 0
    currentFlightFromIndex = 0
    currentFlightToIndex = 0
    pendingFlightCost = nil
    lastClickedTaxiNode = nil
    isInFlight = false
    flightPending = false
    FlightPathTurtleTimer:Hide()
end

function addon:ChatCommand(input)
    LibStub("AceConfigDialog-3.0"):Open(addonName)
end


function addon:CreateUpdateFrame()
    local f = CreateFrame("Frame", "FlightPathTurtleUpdateFrame")
    
    local function startMonitoring()
        f:SetScript("OnUpdate", function()
            if flightPending then
                if UnitOnTaxi("player") then
                    flightPending = false
                    isInFlight = true
                    local fromName = TaxiNodeName(currentFlightFromIndex)
                    local toName = TaxiNodeName(currentFlightToIndex)
                    self:StartFlight(fromName, toName, pendingFlightCost)
                end
            elseif isInFlight then
                if not UnitOnTaxi("player") then
                    self:RecordFlight()
                    f:SetScript("OnUpdate", nil)
                end
            else
                f:SetScript("OnUpdate", nil)
            end
        end)
    end
    
    self.startFlightMonitoring = startMonitoring
end

function addon:CreateFlightTimer()
    local f = CreateFrame("Frame", "FlightPathTurtleTimer", UIParent)
    f:SetWidth(200)
    f:SetHeight(55)
    f:SetPoint(
        self.db.char.timerPosition.point,
        UIParent,
        self.db.char.timerPosition.relativePoint,
        self.db.char.timerPosition.x,
        self.db.char.timerPosition.y
    )
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0, 0, 0, 0.8)
    f:Hide()

    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function()
        if IsShiftKeyDown() then
            FlightPathTurtleTimer:StartMoving()
        end
    end)
    f:SetScript("OnDragStop", function()
        FlightPathTurtleTimer:StopMovingOrSizing()
        local point, _, relativePoint, x, y = FlightPathTurtleTimer:GetPoint()
        addon.db.char.timerPosition = {
            point = point,
            relativePoint = relativePoint,
            x = x,
            y = y,
        }
    end)

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.text:SetPoint("TOP", f, "TOP", 0, -8)
    f.text:SetText("Destination: Unknown")

    f.zone = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.zone:SetPoint("TOP", f.text, "BOTTOM", 0, -2)
    f.zone:SetTextColor(0.8, 0.8, 0.8)

    f.timer = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.timer:SetPoint("TOP", f.zone, "BOTTOM", 0, -2)
    f.timer:SetText("00:00")
    
    local helpButton = CreateFrame("Button", nil, f)
    helpButton:SetWidth(16)
    helpButton:SetHeight(16)
    helpButton:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -5, 5)
    
    local helpText = helpButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    helpText:SetPoint("CENTER", helpButton, "CENTER", 0, 0)
    helpText:SetText("?")
    helpText:SetTextColor(1, 0.82, 0)

    helpButton.tooltipText = "Shift+Drag to move this timer."
    
    helpButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText(this.tooltipText, nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    
    helpButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    f:SetScript("OnUpdate", function(self, elapsed)
        if not FlightPathTurtleTimer.startTime or FlightPathTurtleTimer.startTime == 0 then return end
        local timePassed = GetTime() - FlightPathTurtleTimer.startTime
        local remaining
        if FlightPathTurtleTimer.duration and FlightPathTurtleTimer.duration > 0 then
            remaining = FlightPathTurtleTimer.duration - timePassed
            if remaining < 0 then remaining = timePassed end
        else
            remaining = timePassed
        end
        local minutes = floor(remaining / 60)
        local seconds = floor(mod(remaining, 60))
        FlightPathTurtleTimer.timer:SetText(string.format("%02d:%02d", minutes, seconds))
    end)
end


function addon:FormatTime(seconds)
    if not seconds or seconds <= 0 then return "0s" end
    seconds = floor(seconds)
    local days = floor(seconds / 86400)
    local hours = floor(mod(seconds, 86400) / 3600)
    local mins = floor(mod(seconds, 3600) / 60)
    local secs = floor(mod(seconds, 60))
    local t = {}
    if days > 0 then table.insert(t, days .. "d") end
    if hours > 0 then table.insert(t, hours .. "h") end
    if mins > 0 then table.insert(t, mins .. "m") end
    if secs > 0 or table.getn(t) == 0 then table.insert(t, secs .. "s") end
    return table.concat(t, " ")
end

function addon:FormatTimeTooltip(seconds)
    if not seconds or seconds <= 0 then return "0:00" end
    seconds = floor(seconds)
    local minutes = floor(seconds / 60)
    local secs = floor(mod(seconds, 60))
    return string.format("%d:%02d", minutes, secs)
end

function addon:FormatMoney(copper)
    if not copper or copper == 0 then return "0|cffeda55fC|r" end
    copper = floor(copper)
    local gold = floor(copper / 10000)
    local silver = floor(mod(copper, 10000) / 100)
    local copp = floor(mod(copper, 100))

    local t = {}
    if gold > 0 then table.insert(t, gold .. "|cffffd700G|r") end
    if silver > 0 then table.insert(t, silver .. "|cffc7c7cfS|r") end
    if copp > 0 or table.getn(t) == 0 then table.insert(t, copp .. "|cffeda55fC|r") end

    return table.concat(t, " ")
end

function addon:GetFlyerRank(flightCount)
    if flightCount >= 500 then
        return "|cffFFD700Sky Lord|r"
    elseif flightCount >= 200 then
        return "Elite Skymaster"
    elseif flightCount >= 100 then
        return "Seasoned Aeronaut"
    elseif flightCount >= 50 then
        return "Well-Traveled Flyer"
    elseif flightCount >= 10 then
        return "Frequent Traveler"
    else
        return "Novice Traveler"
    end
end


function addon:CreateOptionsUI()
    local options = {
        name = "FlightPath-Turtle",
        type = "group",
        inline = true, 
        args = {
            description = {
                order = 1,
                type = "description",
                name = "FlightPath-Turtle tracks your flight paths, times, and costs and provides statistics.",
            },
            options_header = {
                order = 10,
                type = "header",
                name = "Options",
            },
            autoDismount = {
                order = 11,
                type = "toggle",
                name = "Auto Dismount",
                desc = "Automatically dismount when you talk to a flight master.",
                get = function(info) return addon.db.char.options.autoDismount end,
                set = function(info, val) addon.db.char.options.autoDismount = val end,
            },
            confirmFlights = {
                order = 12,
                type = "toggle",
                name = "Confirm Flights",
                desc = "Show a confirmation dialog before taking a flight.",
                get = function(info) return addon.db.char.options.confirmFlights end,
                set = function(info, val) addon.db.char.options.confirmFlights = val end,
            },
            showTimer = {
                order = 13,
                type = "toggle",
                name = "In-Flight Timer",
                desc = "Show the timer bar during flights. Shift+Drag to move it.",
                get = function(info) return addon.db.char.options.showTimer end,
                set = function(info, val) addon.db.char.options.showTimer = val end,
            },
            announceETA = {
                order = 14,
                type = "toggle",
                name = "Announce ETA to Party/Raid",
                desc = "Automatically announce your destination and ETA in party or raid chat when you take a flight.",
                get = function(info) return addon.db.char.options.announceETA end,
                set = function(info, val) addon.db.char.options.announceETA = val end,
            },
            stats_header = {
                order = 20,
                type = "header",
                name = "Flight Statistics",
            },
            frequentFlyerRank = {
                order = 21,
                type = "description",
                name = function()
                    local rank = addon:GetFlyerRank(addon.db.char.statistics.totalFlights)
                    return "|cffFFFF00Flyer Rank:|r " .. rank
                end,
            },
            totalFlights = {
                order = 22,
                type = "description",
                name = function() return "|cffFFFF00Total Flights Taken:|r " .. addon.db.char.statistics.totalFlights end,
            },
            totalTime = {
                order = 23,
                type = "description",
                name = function() return "|cffFFFF00Total Time in Flight:|r " .. addon:FormatTime(addon.db.char.statistics.totalTime) end,
            },
            totalCost = {
                order = 24,
                type = "description",
                name = function() return "|cffFFFF00Total Gold Spent:|r " .. addon:FormatMoney(addon.db.char.statistics.totalCost) end,
            },
            longestFlight = {
                order = 25,
                type = "description",
                name = function() 
                    local path = addon.db.char.statistics.longestFlightPath
                    local time = addon.db.char.statistics.longestFlightTime
                    if not path or path == "" then
                        return "|cffFFFF00Longest Flight:|r None recorded yet"
                    else
                        return "|cffFFFF00Longest Flight:|r " .. path .. " (" .. addon:FormatTime(time) .. ")"
                    end
                end,
            },
            spacer = {
                order = 50,
                type = "header",
                name = "",
            },
            reset = {
                order = 51,
                type = "execute",
                name = "Reset All Flight Data",
                desc = "Resets all recorded flight times, costs, and statistics for this character.",
                func = function()
                    StaticPopup_Show("FLIGHTPATH_TURTLE_RESET_STATS")
                end,
            },
        },
    }

    self:RegisterOptionsTable(addonName, options)
    LibStub("AceConfigDialog-3.0"):SetDefaultSize(addonName, 415, 320)

    local ACD = LibStub("AceConfigDialog-3.0")
    local originalOpen = ACD.Open
    ACD.Open = function(self, appName, ...)
        local result = originalOpen(self, appName, unpack(arg))
        if appName == addonName then
            local frame = ACD.OpenFrames[appName]
            if frame and frame.frame and not frame.escapeRegistered then
                local frameName = "FlightPathTurtleOptionsFrame"
                frame.frame.name = frameName
                _G[frameName] = frame.frame
                tinsert(UISpecialFrames, frameName)
                frame.escapeRegistered = true
            end
        end
        return result
    end
end

StaticPopupDialogs["FLIGHTPATH_TURTLE_CONFIRM"] = {
    text = "Take flight to %s for %s?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        if lastClickedTaxiNode then
            isConfirming = true
            TakeTaxiNode(lastClickedTaxiNode)
        end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs["FLIGHTPATH_TURTLE_RESET_STATS"] = {
    text = "Are you sure you want to reset all flight statistics for this character?",
    button1 = "Yes",
    button2 = "Cancel",
    OnAccept = function()
        addon.db.char.statistics = {
            totalFlights = 0,
            totalTime = 0,
            totalCost = 0,
            longestFlightTime = 0,
            longestFlightPath = "",
        }
        addon.db.char.flightTimes = {}
        addon.db.char.flightCosts = {}
        addon:Print("Statistics have been reset.")
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}
