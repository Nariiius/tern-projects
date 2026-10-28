--!strict
-- tern-projects window half: commands, toggle logic, and guarded launch routes.
-- iOS has no tern.process; skip setup on that platform.
if tern.runtime.os == "ios" then
	return
end

local fmt = require("./lib/fmt")
local unpct = fmt.unpct

local KIND = "tern-projects.panel"
local WIDTH = 44

-- Per-pane state for toggle tracking.
local last_mode: { [number]: string } = {}
local prev_focus: { [number]: number } = {}

-- Toggle or open the projects panel in `mode` for the current tab.
local function toggle(cx: SessionContext, mode: string)
	local f = cx.session:focused()
	local fi = f ~= nil and cx.session:pane(f) or nil
	local tab = fi ~= nil and fi.tab or nil
	if tab == nil then
		return
	end

	-- Find an existing panel pane on this tab.
	local panel: number? = nil
	for _, p in cx.session:panes() do
		if p.block == KIND and p.tab == tab then
			panel = p.pane
			break
		end
	end

	if panel ~= nil then
		if f == panel and last_mode[panel] == mode then
			-- Same key again while panel is focused: close it.
			cx.layout:close(panel)
			local pf = prev_focus[panel]
			if pf ~= nil then
				-- Try to refocus the previous pane.
				for _, p in cx.session:panes() do
					if p.pane == pf then
						cx.layout:focus(pf)
						break
					end
				end
			end
			return
		end
		-- Retarget the existing panel to the new mode/cwd.
		local new_cwd = (f ~= panel and fi ~= nil) and (fi.cwd or "") or ""
		cx.session:event(panel, {
			ev = "action",
			id = "main",
			act = "open=" .. mode .. ":" .. new_cwd,
			value = mode .. ":" .. new_cwd,
		})
		cx.layout:focus(panel)
		last_mode[panel] = mode
		if f ~= panel then
			prev_focus[panel] = f :: number
		end
		return
	end

	-- Create a new panel.
	pcall(tern.fs.remove, tern.plugin.data .. "/panel-cols")
	local new_cwd = fi ~= nil and (fi.cwd or "") or ""
	local new_pane = cx.layout:split(f :: number, "left", { block = KIND, args = { mode, new_cwd } })
	if new_pane == nil then
		cx:toast("error", "Projects block unavailable", "tern plugin list")
		return
	end
	last_mode[new_pane] = mode
	prev_focus[new_pane] = f :: number

	-- After the block reports its width, resize the split.
	tern.timer(400, function(cx2: SessionContext)
		local ok, data = pcall(tern.fs.read, tern.plugin.data .. "/panel-cols")
		if not ok then
			return
		end
		local c = tonumber(data)
		if c ~= nil and c > WIDTH + 2 then
			cx2.layout:resize(new_pane :: number, "right", -(c - WIDTH))
		end
	end)
end

-- User overrides take precedence over plugin defaults. Migrate only exact old actions.
local function migrate_keybinds(cx: SessionContext)
	local replacements = {
		["plugin.tern-sessions.sessions"] = "plugin.tern-projects.projects",
		["plugin.tern-sessions.search"] = "plugin.tern-projects.search",
	}
	for chord, value in cx.settings:keybinds() do
		if type(value) == "string" then
			local replacement = replacements[value]
			if replacement ~= nil then cx.settings:bind(chord, replacement) end
		else
			local changed = false
			local actions: { string } = {}
			for _, action in value do
				local replacement = replacements[action]
				table.insert(actions, replacement or action)
				if replacement ~= nil then changed = true end
			end
			if changed then cx.settings:bind(chord, actions) end
		end
	end
end

tern.on("window_start", function(cx: SessionContext)
	migrate_keybinds(cx)
end)

tern.command({
	id = "projects",
	title = "Projects",
	icon = "folder",
	keys = { if tern.runtime.os == "macos" then "cmd+alt+s" else "ctrl+alt+s" },
	run = function(cx)
		migrate_keybinds(cx)
		toggle(cx, "projects")
	end,
})

tern.command({
	id = "search",
	title = "Projects: Search",
	icon = "search",
	keys = { if tern.runtime.os == "macos" then "ctrl+alt+cmd+s" else "ctrl+alt+shift+s" },
	run = function(cx)
		migrate_keybinds(cx)
		toggle(cx, "search")
	end,
})

tern.command({
	id = "settings",
	title = "Projects: Settings",
	icon = "settings",
	run = function(cx) toggle(cx, "settings") end,
})

-- Clean up tracking state when a pane closes.
tern.on("pane_closed", function(ev: any, _cx: any)
	last_mode[ev.pane] = nil
	prev_focus[ev.pane] = nil
end)

local function trusted_origin(link: any, cx: any): boolean
	local pane = link.pane ~= nil and cx.session:pane(link.pane) or nil
	return pane ~= nil and pane.block == KIND and cx.session:focused() == link.pane
end

local function launch(cx: any, cwd: string, cmd: string)
	local ok, pane = pcall(function()
		return cx.layout:new_tab({ cwd = cwd, command = cmd })
	end)
	if not ok or pane == nil then
		cx:toast("error", "Could not open chat tab", if ok then "Tern did not create a tab." else tostring(pane))
	end
end

local function focus_live(cx: any, panes: any, file: string): boolean
	for _, candidate in panes do
		if candidate.omp_session_file ~= file or type(candidate.exited) == "number" then continue end
		local pane = cx.session:pane(candidate.pane)
		if pane == nil or type(pane.exited) == "number" then continue end
		-- Consult the current layout, not the original tab: Agent Wall may have moved it.
		local tab = cx.session:tab_of(pane.pane)
		local session = nil
		for _, t in cx.session:tabs() do
			if t.id == tab then session = t.session; break end
		end
		if session == nil and pane.parked then session = candidate.session end
		local local_session = false
		for _, s in cx.sessions:list() do
			if s.id == session and s.host == cx.hosts:current().id then local_session = true; break end
		end
		if not local_session then
			cx:toast("error", "Could not open live chat", "Its local session is unavailable. No duplicate was started.")
			return true
		end
		local ok, err = pcall(function()
			cx.sessions:switch(session)
			if pane.parked then
				local restored, reason = cx.layout:unpark(pane.pane)
				assert(restored, reason)
			end
			cx.layout:focus(pane.pane)
		end)
		if not ok then cx:toast("error", "Could not open live chat", tostring(err)) end
		return true
	end
	return false
end

-- Host-generated commands must execute only on the originating local window.
tern.route.link(function(link: any, cx: SessionContext)
	local route, q = string.match(link.url, "^tern%-projects://([a-z]+)%?(.*)$")
	if route ~= "resume" and route ~= "launch" then return nil end
	if not trusted_origin(link, cx) then
		-- A custom URL in unrelated terminal/chat content is not a launch request.
		return { handled = true }
	end
	if cx.hosts:current().kind ~= "local" then
		cx:toast("error", "Cannot launch a local chat on a remote host", "Switch to the local host first.")
		return { handled = true }
	end
	local function field(name: string): string
		return unpct(string.match("&" .. q, "&" .. name .. "=([^&]*)") or "")
	end
	local cwd, cmd = field("cwd"), field("cmd")
	if cmd == "" or cwd == "" or string.find(cwd, "[%z\r\n]") or string.find(cmd, "[%z\r\n]") then
		cx:toast("error", "Invalid chat launch", "The working directory or command is missing or invalid.")
		return { handled = true }
	end
	local file = field("file")
	if route == "resume" and field("agent") == "omp" and file ~= "" then
		if string.find(file, "[%z\r\n]") then
			cx:toast("error", "Invalid chat launch", "The session file is invalid.")
			return { handled = true }
		end
		local host = cx.hosts:current().id
		local ok, err = pcall(function()
			tern.process.run({tern.getenv("TERN_BINARY") or "tern", "inspect", "--json"}, {timeout_ms = 5000}, function(result: any, fresh: any)
				if fresh == nil or not trusted_origin(link, fresh) then return end
				local current = fresh.hosts:current()
				if current.kind ~= "local" or current.id ~= host then return end
				-- Failed or capped inspection cannot establish absence; never risk a duplicate.
				local decoded, snapshot = false, nil
				if result.status == 0 and #(result.stdout or "") < 4 * 1024 * 1024 then
					decoded, snapshot = pcall(tern.json.decode, result.stdout)
				end
				if not decoded or type(snapshot) ~= "table" or type(snapshot.panes) ~= "table" then
					fresh:toast("error", "Could not inspect live chats", "No chat was started. Try Resume again.")
					return
				end
				if not focus_live(fresh, snapshot.panes, file) then launch(fresh, cwd, cmd) end
			end)
		end)
		if not ok then cx:toast("error", "Could not inspect live chats", tostring(err)) end
	else
		-- Other harnesses expose no exact live identity; retain their existing resume behavior.
		launch(cx, cwd, cmd)
	end
	return { handled = true }
end)

