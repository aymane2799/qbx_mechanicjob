# qbx_mechanicjob
Mechanic Job for Qbox Framework

## Screenshots
![Platform](https://imgur.com/KzmXIaY.png)
![Vehicle Spawner](https://imgur.com/bDYiFoG.png)
![Stash](https://imgur.com/8fvy9FA.png)
![On Duty/Off Duty](https://i.imgur.com/CM34EsL.png)

## Features
- /setmechanic - Sets someone mechanic
- /firemechanic - Fires a mechanic worker
- On Duty/Off Duty
- Placing vehicles to platform for repairing it part by part.
- Towtruck, Blista, Minivan, Flatbed for workers.

## Installation
### Manual
- Download the script and put it in the `[qbx]` directory.
- Add the following code to your server.cfg or resouces.cfg
```
ensure qbx_core
ensure qbx_mechanicjob
```

## Atlas fork

This is a fork of [Qbox-project/qbx_mechanicjob](https://github.com/Qbox-project/qbx_mechanicjob) at commit
`df4f23f`, kept for the Atlas server. One change: **the server checks who sends each request.** Upstream, every
server event and callback of this resource answers any client, whatever its job and wherever it stands.

| Request | Upstream | Fork |
|---|---|---|
| Callback `qbx_mechanicjob:server:spawnVehicle` | Spawns any model at any coordinates for anyone | Only a model of `config/client.lua` `vehicles`, only for a mechanic on duty near the garage point, at the configured place, once per `spawnCooldown` |
| Callback `qbx_mechanicjob:server:checkForItems` | Takes the materials of any part name (an unknown name is a script error) | Known part, mechanic on duty, near a lift. Paying grants one repair of that part for `repairGrantSeconds` |
| `vehiclemod:server:setupVehicleStatus` | Any plate, any values | Only from the driver of the vehicle with that plate; values clamped |
| `vehiclemod:server:updatePart` | Any plate, any part, any level | The driver reports engine and body health of the vehicle driven. A mechanic with a paid repair sets that part to its maximum, for a vehicle standing on a lift. Staff who may use `/setvehiclestatus` set any part of the vehicle they drive. Everything else is refused |
| `vehiclemod:server:fixEverything` | Any plate | Staff who may use `/setvehiclestatus`, for the vehicle they drive |
| `qb-vehicletuning:server:SetAttachedVehicle` | Anyone | Mechanic on duty, near that lift |
| `qb-vehicletuning:server:SaveVehicleProps`, `UpdateDrivingDistance`, `SetPartLevel`, `LoadStatus`, `vehiclemod:server:saveStatus`, callback `IsVehicleOwned` | Any client writes the saved modifications, driving distance, or status of any owned vehicle, or sends any table to every client | Removed. Nothing in this resource calls them: `client/drivingdistance.lua` is not in the manifest, and the two status events were for the old qb-garages |
| `/setvehiclestatus` | Restricted to `group.god` | Restricted to `group.admin`; unknown part names ignored |
| `/setmechanic`, `/firemechanic` | For the citizen ids of `authorizedIds`, with English text in the code | Removed. Staff use `/setjob` |

Refused requests are printed to the server console (`qbx_mechanicjob: … refused`).

Not changed: the vehicle status is still what the driving client reports, and it is kept in memory only (it is
lost on a restart, as upstream). Parts other than engine and body never wear, because the file that wore them
is not loaded upstream either. The lift menu shows the labels of the items `advancedrepairkit`, `plastic`,
`steel`, `iron`, `aluminum`, and the repairs take `metalscrap`, `plastic`, `steel`, `aluminum`, `copper`:
all seven must exist in the item list.

Rebase on a new upstream commit: `git fetch upstream && git rebase upstream/main`. The patch rewrites
`server/main.lua` and `config/server.lua` and touches one call in `client/main.lua` (`spawnListVehicle`).
