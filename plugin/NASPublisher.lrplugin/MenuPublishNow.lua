--[[ MenuPublishNow.lua (Library > Plug-in Extras > NAS Publisher: Publish Now)
Publishes every NAS Publisher collection now, without waiting for edits to settle.
]]

local LrTasks = import 'LrTasks'

local AutoPublisher = require 'AutoPublisher'
local State = require 'State'

if State.loopRunning then
	AutoPublisher.publishNow()
else
	LrTasks.startAsyncTask(function() AutoPublisher.cycle(true) end)
end
State.bezel('NAS Publisher: publishing now')
