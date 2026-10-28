--[[ MenuStatus.lua (Library > Plug-in Extras > NAS Publisher: Status…)
]]

local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'

local State = require 'State'

local function when(t)
	if not t then return 'never' end
	return LrDate.timeToUserFormat(t, '%Y-%m-%d %H:%M:%S')
end

local lines = {
	State.status,
	'',
	'NAS: ' .. (State.nasOnline and 'online' or 'not reachable'),
	'Auto-publish loop: ' .. (State.loopRunning and 'running' or 'not running'),
	'Status updated: ' .. when(State.statusAt),
	'Last publish: ' .. when(State.lastPublishAt) .. (State.lastPublishSummary and (' (' .. State.lastPublishSummary .. ')') or ''),
	'Photos skipped until edited again: ' .. State.failedCount(),
	'',
	'Log: ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/NASPublisher.log',
}
LrDialogs.message('NAS Publisher ' .. State.version, table.concat(lines, '\n'), 'info')
