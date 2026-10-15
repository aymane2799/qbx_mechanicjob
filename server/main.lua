local config = require 'config.server'
local clientConfig = require 'config.client'
local sharedConfig = require 'config.shared'
local vehicleStatus = {}
local vehicleDrivingDistance = {}
local repairGrants = {}
local lastSpawn = {}
-- Atlas fork: the work vehicle of each mechanic (net id by citizenid), returned at the dispatcher.
local workVehicles = {}
-- How far from its parking spot (locations.vehicle) a work vehicle may stand when it is returned.
local returnRange = 40.0
local stash = {
    id = 'mechanicstash',
    label = locale('labels.stash'),
    slots = 500,
    weight = 4000000,
    owner = false,
    groups = {mechanic = 0},
    coords = sharedConfig.locations.stash
}
exports.ox_inventory:RegisterStash(stash.id, stash.label, stash.slots, stash.weight, stash.owner, stash.groups, stash.coords)

-- Functions

local function getVehicleStatus(plate)
    local result = MySQL.query.await('SELECT status FROM player_vehicles WHERE plate = ?', {plate})
    if result[1] and result[1].status then
        return json.decode(result[1].status)
    end
end

---@param source number
---@return boolean
local function isMechanicOnDuty(source)
    local player = exports.qbx_core:GetPlayer(source)
    local job = player and player.PlayerData.job
    return job ~= nil and job.type == 'mechanic' and job.onduty == true
end

---@param source number
---@param coords vector3
---@param maxDistance number
---@return boolean
local function isNear(source, coords, maxDistance)
    local ped = GetPlayerPed(source)
    return ped ~= 0 and #(GetEntityCoords(ped) - coords) <= maxDistance
end

---@param source number
---@return boolean
local function isNearLift(source)
    for i = 1, #sharedConfig.plates do
        if isNear(source, sharedConfig.plates[i].coords.xyz, config.liftDistance) then
            return true
        end
    end
    return false
end

---@param plate any
---@return boolean
local function isPlate(plate)
    return type(plate) == 'string' and #plate > 0 and #plate <= 8
end

---@param value any
---@return boolean
local function isNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

---The player drives a vehicle with the given plate.
---@param source number
---@param plate string
---@return boolean
local function isDriverOf(source, plate)
    local ped = GetPlayerPed(source)
    if ped == 0 then return false end

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 or GetPedInVehicleSeat(vehicle, -1) ~= ped then return false end

    return qbx.getVehiclePlate(vehicle) == plate
end

---A vehicle with the given plate stands on one of the lifts.
---@param plate string
---@return boolean
local function isOnLift(plate)
    local vehicles = GetAllVehicles()
    for i = 1, #vehicles do
        local vehicle = vehicles[i]
        if qbx.getVehiclePlate(vehicle) == plate then
            local coords = GetEntityCoords(vehicle)
            for j = 1, #sharedConfig.plates do
                if #(coords - sharedConfig.plates[j].coords.xyz) <= config.liftDistance then
                    return true
                end
            end
        end
    end
    return false
end

---@param part string
---@param level number
---@return number
local function clampLevel(part, level)
    local maxLevel = sharedConfig.maxStatusValues[part]
    return level < 0 and 0 or level > maxLevel and maxLevel or level
end

---@param source number
---@param what string
local function refuse(source, what)
    lib.print.warn(('qbx_mechanicjob: %s from source %s refused'):format(what, source))
end

-- Callbacks

lib.callback.register('qb-vehicletuning:server:GetDrivingDistances', function()
    return vehicleDrivingDistance
end)

lib.callback.register('qb-vehicletuning:server:GetAttachedVehicle', function()
    return sharedConfig.plates
end)

lib.callback.register('qbx_mechanicjob:server:spawnVehicle', function(source, vehicleName)
    if type(vehicleName) ~= 'string' or not clientConfig.vehicles[vehicleName] then
        return refuse(source, 'spawnVehicle with an unlisted model')
    end
    -- Atlas fork: taken at the dispatcher, one work vehicle per mechanic.
    if not isMechanicOnDuty(source) or not isNear(source, sharedConfig.locations.dispatcher.coords.xyz, config.garageDistance) then
        return refuse(source, 'spawnVehicle off duty or away from the garage')
    end

    local citizenid = exports.qbx_core:GetPlayer(source).PlayerData.citizenid
    local current = workVehicles[citizenid] and NetworkGetEntityFromNetworkId(workVehicles[citizenid])
    if current and current ~= 0 and DoesEntityExist(current) then
        exports.qbx_core:Notify(source, locale('notifications.vehicle_already_out'), 'error')
        return
    end

    local now = os.time()
    if lastSpawn[source] and now - lastSpawn[source] < config.spawnCooldown then return end
    lastSpawn[source] = now

    local netId = qbx.spawnVehicle({
        model = joaat(vehicleName),
        spawnSource = sharedConfig.locations.vehicle,
        warp = GetPlayerPed(source)
    })
    workVehicles[citizenid] = netId
    return netId
end)

-- Atlas fork: the work vehicle is returned at the dispatcher, on foot. Upstream deleted the vehicle the
-- client sat in, wherever it was. Here the server refuses while the vehicle is away from the garage and
-- deletes it itself.
---@return boolean returned
lib.callback.register('qbx_mechanicjob:server:returnVehicle', function(source)
    if not isMechanicOnDuty(source) or not isNear(source, sharedConfig.locations.dispatcher.coords.xyz, config.garageDistance) then
        refuse(source, 'returnVehicle off duty or away from the garage')
        return false
    end

    local citizenid = exports.qbx_core:GetPlayer(source).PlayerData.citizenid
    local netId = workVehicles[citizenid]
    local vehicle = netId and NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        workVehicles[citizenid] = nil
        exports.qbx_core:Notify(source, locale('notifications.no_work_vehicle'), 'error')
        return false
    end

    if #(GetEntityCoords(vehicle) - sharedConfig.locations.vehicle.xyz) > returnRange then
        exports.qbx_core:Notify(source, locale('notifications.vehicle_too_far'), 'error')
        return false
    end

    DeleteEntity(vehicle)
    workVehicles[citizenid] = nil
    return true
end)

lib.callback.register('qbx_mechanicjob:server:checkForItems', function(source, part)
    local cost = type(part) == 'string' and sharedConfig.repairCostAmount[part]
    if not cost then
        refuse(source, 'checkForItems with an unknown part')
        return false
    end
    if not isMechanicOnDuty(source) or not isNearLift(source) then
        refuse(source, 'checkForItems off duty or away from a lift')
        return false
    end

    local amount = exports.ox_inventory:Search(source, 'count', cost.item)
    if amount < cost.costs or not exports.ox_inventory:RemoveItem(source, cost.item, cost.costs) then
        return false
    end

    -- What was paid for: one repair of this part, used by the updatePart that follows the progress bar.
    repairGrants[source] = {part = part, expires = os.time() + config.repairGrantSeconds}
    return true
end)

-- Events

RegisterNetEvent('vehiclemod:server:setupVehicleStatus', function(plate, engineHealth, bodyHealth)
    local src = source
    if not isPlate(plate) or not isDriverOf(src, plate) then return end

    engineHealth = isNumber(engineHealth) and clampLevel('engine', engineHealth) or sharedConfig.maxStatusValues.engine
    bodyHealth = isNumber(bodyHealth) and clampLevel('body', bodyHealth) or sharedConfig.maxStatusValues.body

    local statusInfo = vehicleStatus[plate] or getVehicleStatus(plate) or
        {
            engine = engineHealth,
            body = bodyHealth,
            radiator = sharedConfig.maxStatusValues.radiator,
            axle = sharedConfig.maxStatusValues.axle,
            brakes = sharedConfig.maxStatusValues.brakes,
            clutch = sharedConfig.maxStatusValues.clutch,
            fuel = sharedConfig.maxStatusValues.fuel
        }

    vehicleStatus[plate] = statusInfo
    TriggerClientEvent("vehiclemod:client:setVehicleStatus", -1, plate, statusInfo)
end)

-- Three senders are accepted. The driver of the vehicle reports its engine and body health. A mechanic who
-- has just paid for a part (checkForItems) repairs that part of a vehicle standing on a lift, to its maximum.
-- Staff who may use /setvehiclestatus set any part of the vehicle they drive.
RegisterNetEvent('vehiclemod:server:updatePart', function(plate, part, level)
    local src = source
    if not isPlate(plate) or type(part) ~= 'string' or not sharedConfig.maxStatusValues[part] or not isNumber(level) then return end
    if not vehicleStatus[plate] then return end

    local grant = repairGrants[src]
    if grant and grant.part == part then
        repairGrants[src] = nil
        if os.time() > grant.expires or not isMechanicOnDuty(src) or not isOnLift(plate) then
            return refuse(src, ('repair of %s'):format(part))
        end
        level = sharedConfig.maxStatusValues[part]
    elseif not isDriverOf(src, plate) then
        return
    elseif part ~= 'engine' and part ~= 'body' and not IsPlayerAceAllowed(src, 'command.setvehiclestatus') then
        return refuse(src, ('updatePart of %s'):format(part))
    end

    vehicleStatus[plate][part] = clampLevel(part, level)
    TriggerClientEvent("vehiclemod:client:setVehicleStatus", -1, plate, vehicleStatus[plate])
end)

RegisterNetEvent('vehiclemod:server:fixEverything', function(plate)
    local src = source
    if not isPlate(plate) or not vehicleStatus[plate] then return end
    if not IsPlayerAceAllowed(src, 'command.setvehiclestatus') or not isDriverOf(src, plate) then
        return refuse(src, 'fixEverything')
    end

    for k, v in pairs(sharedConfig.maxStatusValues) do
        vehicleStatus[plate][k] = v
    end

    TriggerClientEvent("vehiclemod:client:setVehicleStatus", -1, plate, vehicleStatus[plate])
end)

RegisterNetEvent('qb-vehicletuning:server:SetAttachedVehicle', function(k, veh)
    local src = source
    local plate = math.type(k) == 'integer' and sharedConfig.plates[k]
    if not plate or (veh ~= false and math.type(veh) ~= 'integer') then return end
    if not isMechanicOnDuty(src) or not isNear(src, plate.coords.xyz, config.liftDistance) then
        return refuse(src, 'SetAttachedVehicle')
    end

    plate.AttachedVehicle = veh
    TriggerClientEvent('qb-vehicletuning:client:SetAttachedVehicle', -1, veh, k)
end)

AddEventHandler('playerDropped', function()
    repairGrants[source] = nil
    lastSpawn[source] = nil
end)

-- Commands

lib.addCommand('setvehiclestatus', {
    help = 'Set Vehicle Status',
    params = {
        {
            name = 'part',
            type = 'string',
            help = 'Type The Part You Want To Edit',
        },
        {
            name = 'amount',
            type = 'number',
            help = 'The Percentage Fixed',
        },
    },
    restricted = 'group.admin'
}, function(source, args)
    local part = args.part:lower()
    local level = args.amount
    if not sharedConfig.maxStatusValues[part] then return end
    TriggerClientEvent("vehiclemod:client:setPartLevel", source, part, level)
end)
