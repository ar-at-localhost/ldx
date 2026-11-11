local M = {}

---@class Global
---@field __ldx DevManager

---@class DevOpts
---@field dir? string Scratch storage
---@field plugins table<string, DevPluginOpts> Key = plugin name, Value = { path, opts }

function M.default()
	return {
		plugins = {},
	}
end

---@param opts? DevOpts|true
function M.setup(opts)
	if _G.__ldx then
		return _G.__ldx
	end

	opts = (not opts or opts == true) and M.default() or opts
	local DevManager = require("ldx.manager")
	local dev = DevManager:new(opts --[[@as DevManagerOpts]])
	_G.__ldx = dev
	return _G.__ldx
end

function M.get()
	return _G.__ldx
end

function M.teardown()
	if _G.__ldx then
		for plugin_name, _ in pairs(_G.__ldx._watchers) do
			_G.__ldx:unwatch(plugin_name)
		end
		_G.__ldx = nil
	end
end

return M
