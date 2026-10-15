return {
    -- How close to a lift (shared.lua, plates) a mechanic and the vehicle must be for a repair, in metres.
    liftDistance = 15.0,
    -- How close to the dispatcher (shared.lua, locations.dispatcher) a mechanic must be to take or return a
    -- work vehicle, in metres (Atlas fork; upstream measured from the vehicle spot).
    garageDistance = 6.0,
    -- Seconds between two job vehicles for the same mechanic.
    spawnCooldown = 30,
    -- Seconds a paid repair stays usable. The repair animation takes 5 to 10.
    repairGrantSeconds = 30,
}
