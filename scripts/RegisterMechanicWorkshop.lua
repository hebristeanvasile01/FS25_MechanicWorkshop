-- Registers the MechanicWorkshop specialization, the workshop buttons and the service timer.

MechanicManager = {}

local modName = g_currentModName
local modDirectory = g_currentModDirectory

g_specializationManager:addSpecialization("mechanicWorkshop", "MechanicWorkshop", modDirectory .. "scripts/MechanicWorkshop.lua", modName)

local function addToVehicleTypes(typeManager)
    if typeManager.typeName ~= "vehicle" then
        return
    end

    local specName = modName .. ".mechanicWorkshop"

    for typeName, typeEntry in pairs(typeManager:getTypes()) do
        local specs = typeEntry.specializations
        local isTrain = Locomotive ~= nil and SpecializationUtil.hasSpecialization(Locomotive, specs)

        if not isTrain and SpecializationUtil.hasSpecialization(Wearable, specs) then
            typeManager:addSpecialization(typeName, specName)
        end
    end
end

TypeManager.finalizeTypes = Utils.prependedFunction(TypeManager.finalizeTypes, addToVehicleTypes)

------------------------------------------------------------------------------
-- Hide / show vehicles and finish services (runs on the server and on the clients)
------------------------------------------------------------------------------

-- node fields of a wheel that can hang outside the vehicle hierarchy
local WHEEL_NODE_KEYS = {"repr", "driveNode", "linkNode", "steeringNode", "wheelTire", "wheelOuterRim", "wheelInnerRim", "fenderNode"}

local function setVehicleVisible(vehicle, visible)
    if vehicle.rootNode ~= nil then
        setVisibility(vehicle.rootNode, visible)
    end

    if vehicle.components ~= nil then
        for _, component in ipairs(vehicle.components) do
            if component.node ~= nil then
                setVisibility(component.node, visible)
            end
        end
    end

    if vehicle.getWheels ~= nil then
        local wheels = vehicle:getWheels()

        for _, wheel in ipairs(wheels or {}) do
            local sources = {wheel}
            if wheel.visualWheel ~= nil then
                table.insert(sources, wheel.visualWheel)
            end
            for _, visualWheel in ipairs(wheel.visualWheels or {}) do
                table.insert(sources, visualWheel)
            end

            for _, source in ipairs(sources) do
                for _, key in ipairs(WHEEL_NODE_KEYS) do
                    local node = source[key]
                    if type(node) == "number" and node > 0 and entityExists(node) then
                        setVisibility(node, visible)
                    end
                end
            end
        end
    end
end

local function setPhysics(vehicle, away)
    local fn = away and vehicle.removeFromPhysics or vehicle.addToPhysics

    if fn ~= nil then
        local ok, err = pcall(fn, vehicle)
        if not ok then
            print("[MechanicWorkshop] Physics switch failed: " .. tostring(err))
        end
    end
end

local function applyState(vehicle)
    local job = vehicle.mechanicJob

    if job.applied == job.away then
        return
    end

    if job.applied == nil and not job.away then
        job.applied = false
        return
    end

    local wasAway = job.applied == true
    job.applied = job.away

    -- dual wheels and similar parts stay attached and travel with the vehicle
    local parts = {vehicle}
    for _, part in ipairs(MechanicWorkshop.getParts(vehicle)) do
        table.insert(parts, part)
    end
    if job.partsHidden ~= nil and not job.away then
        parts = job.partsHidden
    elseif job.away then
        job.partsHidden = parts
    end

    for _, part in ipairs(parts) do
        setVehicleVisible(part, not job.away)

        if vehicle.isServer then
            setPhysics(part, job.away)
        end
    end

    if not job.away then
        job.partsHidden = nil
    end

    -- the service is done: tell the owner
    if wasAway and not job.away and vehicle.isClient and g_currentMission ~= nil and vehicle:getOwnerFarmId() == g_currentMission:getFarmId() then
        local text = string.format(g_i18n:getText("mw_ready", modName), vehicle:getFullName())

        if g_currentMission.addIngameNotification ~= nil and FSBaseMission ~= nil then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, text)
        else
            g_currentMission:showBlinkingWarning(text, 6000)
        end
    end
end

function MechanicManager:update(dt)
    if g_currentMission == nil then
        return
    end

    local vehicles = g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or g_currentMission.vehicles
    if vehicles == nil then
        return
    end

    self.timer = (self.timer or 0) + dt
    if self.timer < 1000 then
        return
    end
    self.timer = 0

    local now = MechanicWorkshop.getNowMinutes()

    for _, vehicle in ipairs(vehicles) do
        local job = vehicle.mechanicJob

        if job ~= nil then
            if job.away and vehicle.isServer and now >= job.finish then
                vehicle:mechanicFinish()
            end

            local ok, err = pcall(applyState, vehicle)
            if not ok and not MechanicManager.loggedError then
                MechanicManager.loggedError = true
                print("[MechanicWorkshop] Could not apply state: " .. tostring(err))
            end
        end
    end
end

addModEventListener(MechanicManager)

------------------------------------------------------------------------------
-- Workshop screen: "Send to mechanic" and "Quick repair" buttons
------------------------------------------------------------------------------

local KEY_MECHANIC = Input ~= nil and Input.KEY_m or nil
local KEY_QUICK = Input ~= nil and Input.KEY_f or nil

local function cloneButton(screen, field, mode)
    if screen[field] ~= nil then
        return screen[field]
    end

    local source = screen.repairButton
    if source == nil or source.clone == nil or source.parent == nil then
        return nil
    end

    local button = source:clone(source.parent)

    -- the clone must not share the key of the repair button
    button.inputActionName = nil
    if button.setInputAction ~= nil then
        pcall(button.setInputAction, button, nil)
    end

    button.onClickCallback = function(target)
        MechanicManager.onButton(screen, mode)
    end
    button.onClickCallbackName = nil
    button.target = screen

    screen[field] = button

    if source.parent.invalidateLayout ~= nil then
        source.parent:invalidateLayout()
    end

    return button
end


-- FS25 removed g_gui:showInfoDialog, so try the known ways to show a message
local function showMessage(text)
    local ok = pcall(function()
        if g_gui.showInfoDialog ~= nil then
            g_gui:showInfoDialog({text = text})
        elseif InfoDialog ~= nil and InfoDialog.show ~= nil then
            InfoDialog.show(text)
        else
            error("no message dialog")
        end
    end)

    if not ok and g_currentMission ~= nil then
        g_currentMission:showBlinkingWarning(text, 5000)
    end
end

function MechanicManager.onButton(screen, mode)
    local vehicle = screen.vehicle

    if vehicle == nil or vehicle.mechanicJob == nil or vehicle.mechanicJob.away then
        return
    end

    local quote = MechanicWorkshop.getQuote(vehicle)
    local needs = mode == MechanicWorkshop.MODE_QUICK and quote.needsRepair or quote.needsService
    local cost = mode == MechanicWorkshop.MODE_QUICK and quote.quickCost or quote.standardCost

    if not needs then
        showMessage(g_i18n:getText("mw_nothingToDo", modName))
        return
    end

    local farm = g_farmManager:getFarmById(vehicle:getOwnerFarmId())
    if farm == nil or farm.money < cost then
        showMessage(string.format(g_i18n:getText("mw_noMoney", modName), g_i18n:formatMoney(cost, 0, true, true)))
        return
    end

    -- get out of the vehicle before it leaves
    if mode == MechanicWorkshop.MODE_STANDARD and g_currentMission.controlledVehicle == vehicle then
        pcall(function()
            g_currentMission:onLeaveVehicle()
        end)
    end

    if g_server ~= nil then
        vehicle:mechanicStart(mode)
    else
        g_client:getServerConnection():sendEvent(MechanicJobEvent.new(vehicle, mode))
    end

    if mode == MechanicWorkshop.MODE_STANDARD then
        local days = string.format(g_i18n:getText("mw_days", modName), quote.days)

        pcall(function()
            if screen.onClickBack ~= nil then
                screen:onClickBack()
            end
        end)

        showMessage(string.format(g_i18n:getText("mw_sent", modName), days))
    elseif screen.updateButtons ~= nil then
        screen:updateButtons()
    end
end

local function updateButtons(screen)
    local ok, err = pcall(function()
        local vehicle = screen.vehicle
        local hasSpec = vehicle ~= nil and vehicle.mechanicJob ~= nil

        local mechanic = cloneButton(screen, "mwMechanicButton", MechanicWorkshop.MODE_STANDARD)
        local quick = cloneButton(screen, "mwQuickButton", MechanicWorkshop.MODE_QUICK)
        if mechanic == nil or quick == nil then
            return
        end

        -- the instant repair of the game is replaced by the two buttons of this mod
        if hasSpec and screen.repairButton ~= nil then
            screen.repairButton:setVisible(false)
            screen.repairButton:setDisabled(true)
        end

        mechanic:setVisible(hasSpec)
        quick:setVisible(hasSpec)

        if hasSpec then
            local quote = MechanicWorkshop.getQuote(vehicle)

            mechanic:setText(string.format("%s (%s, %s)  [M]", g_i18n:getText("mw_btnMechanic", modName), g_i18n:formatMoney(quote.standardCost, 0, true, true), string.format(g_i18n:getText("mw_days", modName), quote.days)))
            mechanic:setDisabled(not quote.needsService)

            quick:setText(string.format("%s (%s)  [F]", g_i18n:getText("mw_btnQuick", modName), g_i18n:formatMoney(quote.quickCost, 0, true, true)))
            quick:setDisabled(not quote.needsRepair)
        end
    end)

    if not ok and not MechanicManager.loggedButtonError then
        MechanicManager.loggedButtonError = true
        print("[MechanicWorkshop] Could not update the workshop buttons: " .. tostring(err))
    end
end

if WorkshopScreen == nil then
    for name, _ in pairs(_G) do
        if type(name) == "string" and string.find(name, "Workshop") ~= nil then
            print("[MechanicWorkshop] Found global: " .. name)
        end
    end
end

if WorkshopScreen ~= nil then
    if WorkshopScreen.updateButtons ~= nil then
        WorkshopScreen.updateButtons = Utils.appendedFunction(WorkshopScreen.updateButtons, updateButtons)
    elseif WorkshopScreen.setVehicle ~= nil then
        WorkshopScreen.setVehicle = Utils.appendedFunction(WorkshopScreen.setVehicle, updateButtons)
    else
        print("[MechanicWorkshop] WorkshopScreen has no updateButtons/setVehicle, buttons not added.")
    end

    if WorkshopScreen.keyEvent ~= nil then
        WorkshopScreen.keyEvent = Utils.appendedFunction(WorkshopScreen.keyEvent, function(screen, unicode, sym, modifier, isDown)
            if not isDown then
                return
            end

            local button, mode
            if sym == KEY_MECHANIC then
                button, mode = screen.mwMechanicButton, MechanicWorkshop.MODE_STANDARD
            elseif sym == KEY_QUICK then
                button, mode = screen.mwQuickButton, MechanicWorkshop.MODE_QUICK
            end

            if button ~= nil and button:getIsVisible() and not button:getIsDisabled() then
                MechanicManager.onButton(screen, mode)
            end
        end)
    end
else
    print("[MechanicWorkshop] WorkshopScreen not found, buttons not added.")
end
