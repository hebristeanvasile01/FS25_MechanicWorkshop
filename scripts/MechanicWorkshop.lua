-- MechanicWorkshop specialization (FS25)
-- A vehicle can be taken to the mechanic: it disappears for 1-2 days and comes back repaired.

MechanicWorkshop = {}

MechanicWorkshop.MOD_NAME = g_currentModName

------------------------------------------------------------------------------
-- SETTINGS - edit these to taste
------------------------------------------------------------------------------
MechanicWorkshop.QUICK_FACTOR = 2     -- quick repair costs this many times the normal repair price
MechanicWorkshop.MIN_DAYS     = 1     -- service duration without damage (game days)
MechanicWorkshop.MAX_DAYS     = 2     -- service duration at 100% damage (game days)
------------------------------------------------------------------------------

MechanicWorkshop.MODE_STANDARD = 1
MechanicWorkshop.MODE_QUICK = 2

-- functions that must say "no" while the vehicle is at the mechanic
MechanicWorkshop.BLOCKED_FUNCTIONS = {"getIsEnterable", "getIsEnterableFromMenu", "getIsTabbable"}

function MechanicWorkshop.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Wearable, specializations)
end

function MechanicWorkshop.initSpecialization()
    local schema = Vehicle.xmlSchemaSavegame
    local base = "vehicles.vehicle(?)." .. MechanicWorkshop.MOD_NAME .. ".mechanicWorkshop"
    schema:register(XMLValueType.BOOL, base .. "#away", "Vehicle is at the mechanic")
    schema:register(XMLValueType.INT, base .. "#finish", "Game minute when the service is finished")
    schema:register(XMLValueType.BOOL, base .. "#tires", "Tires are replaced during the service")
end

function MechanicWorkshop.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "mechanicStart", MechanicWorkshop.mechanicStart)
    SpecializationUtil.registerFunction(vehicleType, "mechanicFinish", MechanicWorkshop.mechanicFinish)
end

function MechanicWorkshop.registerOverwrittenFunctions(vehicleType)
    for _, name in ipairs(MechanicWorkshop.BLOCKED_FUNCTIONS) do
        if vehicleType.functions ~= nil and vehicleType.functions[name] ~= nil then
            SpecializationUtil.registerOverwrittenFunction(vehicleType, name, function(self, superFunc, ...)
                if self.mechanicJob ~= nil and self.mechanicJob.away then
                    return false
                end

                return superFunc(self, ...)
            end)
        end
    end
end

function MechanicWorkshop.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", MechanicWorkshop)
    SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", MechanicWorkshop)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", MechanicWorkshop)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", MechanicWorkshop)
    SpecializationUtil.registerEventListener(vehicleType, "onReadUpdateStream", MechanicWorkshop)
    SpecializationUtil.registerEventListener(vehicleType, "onWriteUpdateStream", MechanicWorkshop)
end

------------------------------------------------------------------------------
-- Time and prices
------------------------------------------------------------------------------

-- current game time in minutes since the start of the savegame
function MechanicWorkshop.getNowMinutes()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil then
        return 0
    end

    return (env.currentMonotonicDay - 1) * 1440 + math.floor(env.dayTime / 60000)
end

-- everything the UI and the server need to know about a possible service
function MechanicWorkshop.getQuote(vehicle)
    local quote = {}

    quote.damage = vehicle.getDamageAmount ~= nil and vehicle:getDamageAmount() or 0
    quote.repairPrice = vehicle.getRepairPrice ~= nil and vehicle:getRepairPrice() or 0

    -- Tire Wear mod (optional)
    quote.tiresWorn = false
    quote.tireCost = 0
    if vehicle.tireWear ~= nil and vehicle.getTireReplaceCost ~= nil and TireWear ~= nil then
        quote.tiresWorn = vehicle.tireWear.wear >= TireWear.MIN_WEAR_TO_REPLACE
        if quote.tiresWorn then
            quote.tireCost = vehicle:getTireReplaceCost()
        end
    end

    quote.needsRepair = quote.repairPrice > 0
    quote.needsService = quote.needsRepair or quote.tiresWorn

    quote.standardCost = quote.repairPrice + quote.tireCost
    quote.quickCost = quote.repairPrice * MechanicWorkshop.QUICK_FACTOR

    quote.days = MechanicWorkshop.MIN_DAYS + (MechanicWorkshop.MAX_DAYS - MechanicWorkshop.MIN_DAYS) * math.min(math.max(quote.damage, 0), 1)

    return quote
end


-- attached wheel sets and similar parts travel with the vehicle: no tank, no work area
function MechanicWorkshop.isPart(object)
    return object ~= nil
        and object.getWheels ~= nil
        and object.spec_fillUnit == nil
        and object.spec_workArea == nil
        and object.spec_motorized == nil
end

function MechanicWorkshop.getParts(vehicle)
    local parts = {}

    if vehicle.getAttachedImplements ~= nil then
        for _, implement in ipairs(vehicle:getAttachedImplements()) do
            if MechanicWorkshop.isPart(implement.object) then
                table.insert(parts, implement.object)
            end
        end
    end

    return parts
end

function MechanicWorkshop.repairNow(vehicle)
    if vehicle.setDamageAmount ~= nil then
        vehicle:setDamageAmount(0, true)
    elseif vehicle.repairVehicle ~= nil then
        vehicle:repairVehicle()
    end
end

------------------------------------------------------------------------------
-- Load / save / sync
------------------------------------------------------------------------------

function MechanicWorkshop:onLoad(savegame)
    self.mechanicJob = {
        away = false,
        finish = 0,
        tires = false,
        applied = nil,
        dirtyFlag = self:getNextDirtyFlag()
    }
end

function MechanicWorkshop:onPostLoad(savegame)
    if savegame ~= nil then
        local job = self.mechanicJob
        local key = savegame.key .. "." .. MechanicWorkshop.MOD_NAME .. ".mechanicWorkshop"

        job.away = savegame.xmlFile:getValue(key .. "#away", false)
        job.finish = savegame.xmlFile:getValue(key .. "#finish", 0)
        job.tires = savegame.xmlFile:getValue(key .. "#tires", false)
    end
end

function MechanicWorkshop:saveToXMLFile(xmlFile, key, usedModNames)
    local job = self.mechanicJob

    xmlFile:setValue(key .. "#away", job.away)
    xmlFile:setValue(key .. "#finish", job.finish)
    xmlFile:setValue(key .. "#tires", job.tires)
end

function MechanicWorkshop:onWriteStream(streamId, connection)
    local job = self.mechanicJob

    streamWriteBool(streamId, job.away)
    streamWriteInt32(streamId, job.finish)
    streamWriteBool(streamId, job.tires)
end

function MechanicWorkshop:onReadStream(streamId, connection)
    local job = self.mechanicJob

    job.away = streamReadBool(streamId)
    job.finish = streamReadInt32(streamId)
    job.tires = streamReadBool(streamId)
end

function MechanicWorkshop:onWriteUpdateStream(streamId, connection, dirtyMask)
    if not connection:getIsServer() then
        local job = self.mechanicJob

        if streamWriteBool(streamId, bitAND(dirtyMask, job.dirtyFlag) ~= 0) then
            streamWriteBool(streamId, job.away)
            streamWriteInt32(streamId, job.finish)
            streamWriteBool(streamId, job.tires)
        end
    end
end

function MechanicWorkshop:onReadUpdateStream(streamId, timestamp, connection)
    if connection:getIsServer() then
        if streamReadBool(streamId) then
            local job = self.mechanicJob

            job.away = streamReadBool(streamId)
            job.finish = streamReadInt32(streamId)
            job.tires = streamReadBool(streamId)
        end
    end
end

------------------------------------------------------------------------------
-- Server: start and finish a service
------------------------------------------------------------------------------

local function charge(vehicle, cost)
    local farmId = vehicle:getOwnerFarmId()
    local farm = g_farmManager:getFarmById(farmId)

    if farm == nil or farm.money < cost then
        return false
    end

    if cost > 0 then
        g_currentMission:addMoney(-cost, farmId, MoneyType.VEHICLE_REPAIR, true, true)
    end

    return true
end

-- mode 1: send to the mechanic, mode 2: quick repair (instant, costs more)
function MechanicWorkshop:mechanicStart(mode)
    if not self.isServer then
        return
    end

    local job = self.mechanicJob
    if job.away then
        return
    end

    local quote = MechanicWorkshop.getQuote(self)

    if mode == MechanicWorkshop.MODE_QUICK then
        if not quote.needsRepair or not charge(self, quote.quickCost) then
            return
        end

        MechanicWorkshop.repairNow(self)

        return
    end

    if not quote.needsService or not charge(self, quote.standardCost) then
        return
    end

    -- the vehicle has to be stopped and free of implements before it disappears
    pcall(function()
        if self.stopMotor ~= nil then
            self:stopMotor()
        end

        if self.getAttachedImplements ~= nil and self.detachImplementByObject ~= nil then
            local implements = self:getAttachedImplements()
            for i = #implements, 1, -1 do
                local object = implements[i].object
                if object ~= nil and not MechanicWorkshop.isPart(object) then
                    self:detachImplementByObject(object)
                end
            end
        end

        if self.getAttacherVehicle ~= nil then
            local parent = self:getAttacherVehicle()
            if parent ~= nil and parent.detachImplementByObject ~= nil then
                parent:detachImplementByObject(self)
            end
        end
    end)

    job.away = true
    job.tires = quote.tiresWorn
    job.finish = MechanicWorkshop.getNowMinutes() + math.ceil(quote.days * 1440)

    self:raiseDirtyFlags(job.dirtyFlag)
end

function MechanicWorkshop:mechanicFinish()
    if not self.isServer then
        return
    end

    local job = self.mechanicJob

    job.away = false

    MechanicWorkshop.repairNow(self)

    if job.tires and self.setTireWear ~= nil then
        self:setTireWear(0)
    end
    job.tires = false

    self:raiseDirtyFlags(job.dirtyFlag)
end
