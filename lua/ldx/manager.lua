local function reload(module_name, starts_with_only)
	if starts_with_only == nil then
		starts_with_only = true
	end

	local matcher
	if not starts_with_only then
		matcher = function(pack)
			return string.find(pack, module_name, 1, true)
		end
	else
		local module_name_pattern = vim.pesc(module_name)
		matcher = function(pack)
			return string.find(pack, "^" .. module_name_pattern)
		end
	end

	---@diagnostic disable-next-line: undefined-field
	local luacache = (_G.__luacache or {}).cache

	for pack, _ in pairs(package.loaded) do
		if matcher(pack) then
			package.loaded[pack] = nil

			if luacache then
				luacache[pack] = nil
			end
		end
	end
end

local fs = require("yalms.fs")
---@class DevPluginOpts
---@field path string|fun(): string Absolute path to watch
---@field root? string Root of the plugin's source code
---@field opts? table Options to pass to plugin.setup() on file change

---@class DevPluginRt :DevPluginOpts
---@field path string
---@field title string
---@field scratch_path? string
---@field scratches? string[] Additional scratch names (relative to plugin dir)

---@class DevManagerOpts
---@field dir string
---@field plugins table<string, DevPluginOpts> Key = plugin name, Value = { path, opts }

---@class DevManagerRt : DevManagerOpts
---@field plugins table<string, DevPluginRt> Key = plugin name, Value = { path, opts }
---@field _config_path string Path to persist scratches config

---@class DevManager
---@field _opts DevManagerRt
---@field _watchers table<string, any>
---@field _watch_config_s table<string, DevPluginOpts>
local DevManager = {}
DevManager.__index = DevManager

---@param opts DevManagerOpts
function DevManager:new(opts)
	local instance = setmetatable({}, self)
	instance._watchers = {}
	instance._watch_config_s = {}
	instance:_init(opts)
	return instance
end

---@param opts DevManagerOpts
function DevManager:_init(opts)
	self._opts = vim.deepcopy(opts) --[[@as DevManagerRt]]
	self._opts.dir = self._opts.dir or string.format("%s/pw", vim.fn.stdpath("data"))
	self._opts._config_path = string.format("%s/dev_scratches.json", self._opts.dir)
	self._opts.plugins = fs.safe_read_json(self._opts._config_path, { __jsontype = {} }) --[[@as table<string, DevPluginRt>]]
	self._opts.plugins = vim.tbl_deep_extend("force", opts.plugins or { __jsontype = {} }, self._opts.plugins) --[[@as table<string, DevPluginRt>]]
	local plugins = self:list()

	for name, config in pairs(plugins) do
		config.path = config.path and ((type(config.path) == "string" and config.path) or config.path()) --[[@as string]]
		config.scratch_path = string.format("%s/%s.lua", self._opts.dir, name)
		config.title = string.format("-- %s Scratchpad\n", name)
		config.scratches = {}
		config.root = config.root or config.path
		fs.touch(config.scratch_path, true, config.title)

		local function prepend_root(root)
			if not root then
				return
			end
			if not vim.tbl_contains(vim.opt.rtp:get(), root) then
				vim.opt.rtp:prepend(root)
			end
			-- keep as fallback for modules not on the rtp
			local root_lua = root .. "/lua"
			package.path = string.format("%s/?.lua;%s/?/init.lua;%s", root_lua, root_lua, package.path)
		end

		prepend_root(config.root)
		reload(name) -- instead of package.loaded[name] = nil (also clears tw.*)
		local mod = require(name)

		if mod and mod.setup then
			require(name).setup(config.opts)
		end

		if plugins[name] and plugins[name].scratches then
			config.scratches = plugins[name].scratches
		else
			config.scratches = {}
		end

		self:watch(name, config)
	end
end

---Save scratches config to JSON
function DevManager:_save_config()
	local config = { __jsontype = {} }

	for plugin_name, plugin_config in pairs(self._opts.plugins) do
		config[plugin_name] = {
			scratches = plugin_config.scratches or {},
		}
	end

	fs.write_json(self._opts._config_path, config)
end

function DevManager:_on_file_change(plugin_name)
	vim.defer_fn(function()
		self:_pre(plugin_name)

		---@type DevPluginOpts?
		local config = self._watch_config_s[plugin_name]
		if config then
			local ok, plugin = pcall(require, plugin_name)
			if ok and plugin.setup then
				plugin.setup(config.opts)
			end
		end
	end, 0)
end

function DevManager:watch(plugin_name, config)
	if self._watchers[plugin_name] then
		return
	end

	self._watch_config_s[plugin_name] = config

	local FsWatch = require("yalms.fs_watch")
	local watcher = FsWatch:new({
		root = config.path,
		recursive = true,
		on_change = function(_)
			self:_on_file_change(plugin_name)
		end,
	})

	watcher:start()
	self._watchers[plugin_name] = watcher
end

function DevManager:unwatch(plugin_name)
	if self._watchers[plugin_name] then
		self._watchers[plugin_name]:stop()
		self._watchers[plugin_name] = nil
		self._watch_config_s[plugin_name] = nil
	end
end

---@return table<string, DevPluginRt>
function DevManager:list()
	local plugins = vim.deepcopy(self._opts.plugins)
	plugins.__jsontype = nil
	return plugins
end

function DevManager:add(plugin_name)
	local plugins = self:list()
	if not vim.tbl_contains(plugins, plugin_name) then
		table.insert(plugins, plugin_name)
	end
end

function DevManager:_pre(plugin_path)
	local ok, plugin = pcall(require, plugin_path)
	if ok and plugin.teardown then
		plugin.teardown()
	end

	reload(plugin_path)
end

function DevManager:open(plugin_name)
	local ps = self:list()
	local p = ps[plugin_name]

	if self._opts.plugins and self._opts.plugins[plugin_name] then
		if p.path then
			self:watch(plugin_name, p)
		end
	end

	local run_handler = function(s)
		self:_pre(plugin_name)
		Snacks.debug.run({ buf = s.buf, name = plugin_name .. ".lua" })
	end

	---@type snacks.scratch.Config
	local scratch_opts = {
		file = p.scratch_path,
		ft = "lua",
		win = {
			title = p.title,
			style = "scratch",
			show = true,
			scratch_ft = "lua",
		},
		keys = {
			[plugin_name] = {
				"<CR>",
				run_handler,
				desc = "Run and pre-reload " .. plugin_name,
				mode = { "n", "x" },
			},
		},
	}

	Snacks.scratch.open(scratch_opts)
end

---Open a specific scratch by plugin name and scratch name
---@param plugin_name string
---@param scratch_name string
function DevManager:open_scratch(plugin_name, scratch_name)
	local p = self._opts.plugins[plugin_name]
	if not p then
		return
	end

	local file_path
	local title
	if scratch_name == plugin_name then
		file_path = p.scratch_path
		title = p.title
	else
		file_path = self:_scratch_path(plugin_name, scratch_name)
		title = string.format("-- %s Scratch: %s\n", plugin_name, scratch_name)
	end

	local run_handler = function(s)
		self:_pre(plugin_name)
		Snacks.debug.run({ buf = s.buf, name = plugin_name .. ".lua" })
	end

	---@type snacks.scratch.Config
	local scratch_opts = {
		file = file_path,
		ft = "lua",
		win = {
			title = title,
			style = "scratch",
			show = true,
			scratch_ft = "lua",
		},
		keys = {
			[plugin_name .. ":" .. scratch_name] = {
				"<CR>",
				run_handler,
				desc = "Run and pre-reload " .. plugin_name,
				mode = { "n", "x" },
			},
		},
	}

	Snacks.scratch.open(scratch_opts)
end

---Get the directory for additional scratches for a plugin
---@param plugin_name string
---@return string
function DevManager:_scratch_dir(plugin_name)
	return string.format("%s/%s", self._opts.dir, plugin_name)
end

---Get the full path for an additional scratch
---@param plugin_name string
---@param scratch_name string
---@return string
function DevManager:_scratch_path(plugin_name, scratch_name)
	return string.format("%s/%s/%s.lua", self._opts.dir, plugin_name, scratch_name)
end

---List all scratches for a plugin (including default scratch_path)
---@param plugin_name string
---@return {name: string, file: string, is_default: boolean}[]
function DevManager:list_scratches(plugin_name)
	local p = self._opts.plugins[plugin_name]
	if not p then
		return {}
	end

	local items = {}

	table.insert(items, {
		name = plugin_name,
		file = p.scratch_path,
		is_default = true,
	})

	if p.scratches then
		for _, scratch_name in ipairs(p.scratches) do
			table.insert(items, {
				name = scratch_name,
				file = self:_scratch_path(plugin_name, scratch_name),
				is_default = false,
			})
		end
	end

	return items
end

---Add a new scratch for a plugin
---@param plugin_name string
---@param scratch_name string
---@return boolean success
---@return string|nil err
function DevManager:add_scratch(plugin_name, scratch_name)
	local p = self._opts.plugins[plugin_name]
	if not p then
		return false, "Plugin not found: " .. plugin_name
	end

	scratch_name = scratch_name:gsub("%.lua$", "")

	if p.scratches then
		for _, existing in ipairs(p.scratches) do
			if existing == scratch_name then
				return false, "Scratch already exists: " .. scratch_name
			end
		end
	end

	local scratch_path = self:_scratch_path(plugin_name, scratch_name)
	local scratch_dir = self:_scratch_dir(plugin_name)
	fs.ensure_dir(scratch_dir)
	local title = string.format("-- %s Scratch: %s\n", plugin_name, scratch_name)
	local ok, err = fs.touch(scratch_path, true, title)
	if not ok then
		return ok, err
	end

	p.scratches = p.scratches or {}
	table.insert(p.scratches, scratch_name)
	self:_save_config()

	return true, nil
end

---Remove a scratch for a plugin
---@param plugin_name string
---@param scratch_name string
---@return boolean success
---@return string|nil err
function DevManager:remove_scratch(plugin_name, scratch_name)
	local p = self._opts.plugins[plugin_name]
	if not p then
		return false, "Plugin not found: " .. plugin_name
	end

	scratch_name = scratch_name:gsub("%.lua$", "")

	if scratch_name == plugin_name then
		return false, "Cannot remove default scratch"
	end

	if p.scratches then
		local new_scratches = {}
		local found = false
		for _, existing in ipairs(p.scratches) do
			if existing ~= scratch_name then
				table.insert(new_scratches, existing)
			else
				found = true
			end
		end
		if not found then
			return false, "Scratch not found: " .. scratch_name
		end
		p.scratches = new_scratches
	else
		return false, "Scratch not found: " .. scratch_name
	end

	local scratch_path = self:_scratch_path(plugin_name, scratch_name)
	local ok, err = pcall(function()
		os.remove(scratch_path)
	end)
	if ok then
		self:_save_config()
	end
	return ok, err
end

---Rename a scratch for a plugin
---@param plugin_name string
---@param old_name string
---@param new_name string
---@return boolean success
---@return string|nil err
function DevManager:rename_scratch(plugin_name, old_name, new_name)
	local p = self._opts.plugins[plugin_name]
	if not p then
		return false, "Plugin not found: " .. plugin_name
	end

	old_name = old_name:gsub("%.lua$", "")
	new_name = new_name:gsub("%.lua$", "")

	if old_name == plugin_name then
		return false, "Cannot rename default scratch"
	end

	if old_name == new_name then
		return true, nil
	end

	if not p.scratches then
		return false, "Scratch not found: " .. old_name
	end

	local old_idx = nil
	for i, existing in ipairs(p.scratches) do
		if existing == old_name then
			old_idx = i
			break
		end
	end
	if not old_idx then
		return false, "Scratch not found: " .. old_name
	end

	for _, existing in ipairs(p.scratches) do
		if existing == new_name then
			return false, "Scratch already exists: " .. new_name
		end
	end

	local old_path = self:_scratch_path(plugin_name, old_name)
	local new_path = self:_scratch_path(plugin_name, new_name)

	local f = io.open(old_path, "r")
	if not f then
		return false, "Scratch file not found: " .. old_name
	end
	f:close()

	local ok, err = pcall(function()
		os.rename(old_path, new_path)
	end)
	if not ok then
		return false, err
	end

	p.scratches[old_idx] = new_name
	self:_save_config()

	return true, nil
end

return DevManager
