-- Client -> server: send a vehicle to the mechanic (mode 1) or repair it quickly (mode 2).

MechanicJobEvent = {}
local MechanicJobEvent_mt = Class(MechanicJobEvent, Event)

InitEventClass(MechanicJobEvent, "MechanicJobEvent")

function MechanicJobEvent.emptyNew()
    return Event.new(MechanicJobEvent_mt)
end

function MechanicJobEvent.new(vehicle, mode)
    local self = MechanicJobEvent.emptyNew()
    self.vehicle = vehicle
    self.mode = mode
    return self
end

function MechanicJobEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.mode = streamReadUIntN(streamId, 2)
    self:run(connection)
end

function MechanicJobEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUIntN(streamId, self.mode, 2)
end

function MechanicJobEvent:run(connection)
    if self.vehicle ~= nil and self.vehicle:getIsSynchronized() and self.vehicle.mechanicStart ~= nil then
        self.vehicle:mechanicStart(self.mode)
    end
end
