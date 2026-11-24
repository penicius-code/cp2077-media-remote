# Changelog

All versions are for game version 2.5. 1.0.3 is in use in the author's game and working; no version has a written test record.

## 1.0.3 - 2026-11-23
### Fixed
- A radio set back to 100 % while it is off gets its 100 % values at once. Before, it played at its old, lower level when turned on later, because the station-start wrap only applies levels below 100.

Only `MediaRemote.reds` changed; the window stays at 1.0.2.

## 1.0.2 - 2026-11-22
### Fixed
- While the station or channel dropdown was open, the current row tuned the device again on every frame. CET's `ImGui.Selectable` returns the selected state, not "was clicked"; a row now counts as clicked only when it is not the current one.

Only the window (`init.lua`) changed. The mock test now stubs `Selectable` as CET does.

## 1.0.1 - 2026-11-22
### Fixed
- One lock guards the device list and the saved levels, which the game's device tasks and the CET window touch from different threads.
- A quest or scene unmute puts the saved TV level back after its fade, instead of leaving the TV at full volume.
- The window's device key comes from the entity id as a decimal string (1.0.0 converted an unsigned hash to a signed number).

## 1.0.0 - 2026-11-22
- First version: window and remote keys for power, station or channel, volume and mute of nearby radios and TVs; volume levels kept in the save.
