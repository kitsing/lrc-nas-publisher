--[[ NAS Publisher
A publish service that renders edited RAWs living on the NAS and hands the JPEGs to the
lrc-nas-publisher container, which files them under the NAS's export folder in the same folders
as the RAWs. While Lightroom runs, a background task publishes on its own once edits settle.
]]

return {
	LrSdkVersion = 14.0,
	LrSdkMinimumVersion = 10.0,
	LrToolkitIdentifier = 'com.kitsing.lrc.naspublisher',
	LrPluginName = 'NAS Publisher',
	LrPluginInfoUrl = 'https://github.com/kitsing/lrc-nas-publisher',

	LrExportServiceProvider = {
		title = 'NAS Publisher',
		file = 'PublishServiceProvider.lua',
	},

	-- Start the auto-publish loop when Lightroom starts. Lightroom only honors LrForceInitPlugin
	-- for plugins that also have a menu item, hence the Library > Plug-in Extras items.
	LrInitPlugin = 'Init.lua',
	LrForceInitPlugin = true,
	LrShutdownPlugin = 'Shutdown.lua',

	LrLibraryMenuItems = {
		{ title = 'NAS Publisher: Publish Now', file = 'MenuPublishNow.lua' },
		{ title = 'NAS Publisher: Status…', file = 'MenuStatus.lua' },
	},

	VERSION = { major = 1, minor = 1, revision = 1, build = 1 },
}
