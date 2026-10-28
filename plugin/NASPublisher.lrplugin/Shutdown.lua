--[[ Shutdown.lua (LrShutdownPlugin)
Stops the auto-publish loop when the plugin is disabled, reloaded or Lightroom quits.
]]

require('AutoPublisher').stop()
