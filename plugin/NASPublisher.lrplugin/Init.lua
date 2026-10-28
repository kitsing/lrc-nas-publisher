--[[ Init.lua (LrInitPlugin)
Starts the auto-publish loop when Lightroom loads the plugin. It has to be a task with its own
function context: a plain LrTasks.startAsyncTask here is cancelled when this script returns.
]]

local LrFunctionContext = import 'LrFunctionContext'

local AutoPublisher = require 'AutoPublisher'

LrFunctionContext.postAsyncTaskWithContext('NAS Publisher auto-publish', function(context)
	AutoPublisher.run()
end)
