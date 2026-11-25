--- @since 26.9.1
--- Browse btrbk snapshots of the current directory, opening the same relative path in a new tab.

local TITLE = "btrbk"
local CONF_DIR = "/etc/btrbk"

local get_cwd = ya.sync(function() return cx.active.current.cwd end)

local function fail(fmt, ...)
	ya.notify { title = TITLE, content = string.format(fmt, ...), timeout = 6, level = "error" }
end

local function run(cmd, args)
	local out, err = Command(cmd):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not out then
		return nil, string.format("failed to run `%s`: %s", cmd, tostring(err))
	elseif not out.status.success then
		local msg = out.stderr:gsub("%s+$", "")
		return nil, string.format("`%s` failed: %s", cmd, msg ~= "" and msg or ("exit " .. tostring(out.status.code)))
	end
	return out.stdout
end

-- Path helpers -------------------------------------------------------------

--- Relative path of `path` under `root` (both absolute, normalized), or nil if outside.
local function under(path, root)
	if path == root then
		return ""
	elseif root == "/" then
		return path:sub(2)
	elseif path:sub(1, #root + 1) == root .. "/" then
		return path:sub(#root + 2)
	end
end

local function join(a, b)
	if b == "" then
		return a
	end
	return (a:sub(-1) == "/" and a or a .. "/") .. b
end

-- Mount resolution ---------------------------------------------------------

local located = {}

--- Resolve a path to its location inside a btrfs filesystem.
--- @return { real: string, dev: string, fspath: string }?, string?
local function locate(path)
	if located[path] then
		return located[path]
	end

	local real, err = run("realpath", { "-e", "--", path })
	if not real then
		return nil, err
	end
	real = real:gsub("\n$", "")

	local out, err = run("findmnt", { "-P", "-n", "-o", "TARGET,FSROOT,FSTYPE,MAJ:MIN", "-T", real })
	if not out then
		return nil, err
	end

	local m = {}
	for k, v in out:match("[^\n]*"):gmatch('([%w:]+)="(.-)"') do
		m[k] = v:gsub("\\x(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
	end
	if m.FSTYPE ~= "btrfs" then
		return nil, string.format("%s is not on btrfs (fstype: %s)", real, m.FSTYPE or "unknown")
	end

	local rel = under(real, m.TARGET)
	if not rel then
		return nil, string.format("%s is not under its mount point %s", real, m.TARGET)
	end

	located[path] = { real = real, dev = m["MAJ:MIN"], fspath = join(m.FSROOT, rel) }
	return located[path]
end

-- btrbk config -------------------------------------------------------------

--- All local snapshot configs from /etc/btrbk/*.conf, via `btrbk list config`.
local function load_configs()
	local files, err = fs.read_dir(Url(CONF_DIR), {})
	if not files then
		return nil, string.format("cannot read %s: %s", CONF_DIR, tostring(err))
	end

	local entries, seen, errors = {}, {}, {}
	for _, f in ipairs(files) do
		local name = tostring(f.name)
		if name:match("%.conf$") then
			local conf = join(CONF_DIR, name)
			-- `--lockfile=/dev/null` overrides the root-owned lockfile from the config
			local out, err = run("btrbk", { "-c", conf, "--lockfile=/dev/null", "--format=raw", "list", "config" })
			if not out then
				errors[#errors + 1] = err
			end
			for line in (out or ""):gmatch("[^\n]+") do
				local e = { conf = conf }
				for k, v in line:gmatch("([%w_]+)='([^']*)'") do
					e[k] = v
				end
				local key = table.concat({ e.source_subvolume or "", e.snapshot_path or "", e.snapshot_name or "" }, "\0")
				if e.source_subvolume and e.snapshot_path and e.snapshot_name and e.source_host == "" and not seen[key] then
					seen[key] = true
					entries[#entries + 1] = e
				end
			end
		end
	end
	return entries, errors
end

-- Snapshot discovery -------------------------------------------------------

local function format_time(stamp)
	local y, mo, d, rest = stamp:match("^(%d%d%d%d)(%d%d)(%d%d)(.*)$")
	if not y then
		return stamp
	end
	local s = string.format("%s-%s-%s", y, mo, d)
	local h, mi, sec = rest:match("^T(%d%d)(%d%d)(%d?%d?)")
	if h then
		s = s .. string.format(" %s:%s", h, mi) .. (sec ~= "" and ":" .. sec or "")
	end
	return s
end

local function find_snapshots(entry, rel)
	local root = entry.snapshot_path
	local files, err = fs.read_dir(Url(root), {})
	if not files then
		return nil, string.format("cannot read snapshot directory %s: %s", root, tostring(err))
	end

	local prefix = entry.snapshot_name .. "."
	local found, total = {}, 0
	for _, f in ipairs(files) do
		local name = tostring(f.name)
		local stamp = name:sub(1, #prefix) == prefix and name:sub(#prefix + 1)
		if stamp and stamp:match("^%d") and f.cha.is_dir then
			total = total + 1
			local target = join(join(root, name), rel)
			local cha = fs.cha(Url(target)) -- lstat: never follow symlinks out of the snapshot
			if cha and cha.is_dir then
				found[#found + 1] = { name = name, time = format_time(stamp), target = target }
			end
		end
	end
	table.sort(found, function(a, b) return a.name > b.name end)
	return found, total
end

-- UI -----------------------------------------------------------------------

local function pick(items, header)
	local permit = ui.hide()
	local child, err = Command("fzf")
		:arg({
			"--layout=reverse",
			"--delimiter=\t",
			"--with-nth=1,2",
			"--accept-nth=3",
			"--header=" .. header,
			"--header-first",
			"--preview=ls -lA --group-directories-first --color=always -- {3}",
			"--preview-window=right,55%",
		})
		:stdin(Command.PIPED)
		:stdout(Command.PIPED)
		:spawn()

	if not child then
		permit:drop()
		return nil, string.format("failed to start `fzf`: %s", tostring(err))
	end
	for _, it in ipairs(items) do
		child:write_all(string.format("%s\t%s\t%s\n", it.time, it.name, it.target))
	end
	child:flush()

	local out, err = child:wait_with_output()
	permit:drop()
	if not out then
		return nil, string.format("cannot read `fzf` output: %s", tostring(err))
	elseif not out.status.success and out.status.code ~= 1 and out.status.code ~= 130 then
		return nil, string.format("`fzf` exited with code %s", out.status.code)
	end
	return (out.stdout:gsub("\n$", ""))
end

-- Entry --------------------------------------------------------------------

local function entry()
	local cwd_url = get_cwd()
	if cwd_url.spec and cwd_url.spec.is_virtual then
		return fail("Virtual filesystems are not supported")
	end

	local cwd, err = locate(tostring(cwd_url))
	if not cwd then
		return fail("%s", err)
	end

	local entries, errors = load_configs()
	if not entries then
		return fail("%s", errors)
	end

	-- Longest matching subvolume on the same filesystem wins
	local best, best_rel, problems = nil, nil, {}
	for _, e in ipairs(entries) do
		local snap = locate(e.snapshot_path)
		if snap and snap.dev == cwd.dev and under(cwd.fspath, snap.fspath) then
			return fail("Already inside btrbk snapshot directory %s", e.snapshot_path)
		end

		local sub, err = locate(e.source_subvolume)
		if not sub then
			problems[#problems + 1] = string.format("%s: %s", e.conf, err)
		elseif sub.dev == cwd.dev then
			local rel = under(cwd.fspath, sub.fspath)
			if rel and (not best or #sub.fspath > #best.sub.fspath) then
				best, best_rel = { e = e, sub = sub }, rel
			end
		end
	end

	if not best then
		for _, p in ipairs(errors) do
			problems[#problems + 1] = p
		end
		return fail(
			"No btrbk config in %s/*.conf matches subvolume %s%s",
			CONF_DIR,
			cwd.fspath,
			#problems > 0 and ("\n" .. table.concat(problems, "\n")) or ""
		)
	end

	local e = best.e
	if not locate(e.snapshot_path) then
		return fail("Snapshot directory %s (from %s) does not exist", e.snapshot_path, e.conf)
	end

	local items, total = find_snapshots(e, best_rel)
	if not items then
		return fail("%s", total)
	elseif total == 0 then
		return fail("No snapshots named %s.* found in %s", e.snapshot_name, e.snapshot_path)
	elseif #items == 0 then
		return fail("None of the %d snapshots of %s contain directory /%s", total, e.snapshot_name, best_rel)
	end

	local header = string.format("%s  /%s   (%d/%d snapshots)",
		e.snapshot_name, best_rel, #items, total)
	local target, err = pick(items, header)
	if not target then
		return fail("%s", err)
	elseif target ~= "" then
		ya.emit("tab_create", { Url(target) })
	end
end

return { entry = entry }
