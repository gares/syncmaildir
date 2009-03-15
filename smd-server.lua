#! /usr/bin/env lua5.1

function transmit(out, path, what)
	what = what or "all"
	local f = assert(io.open(path,"r"))
	local size = assert(f:seek("end"))
	f:seek("set")

	if what == "header" then
		local line
		local header = {}
		size = 0
		while line ~= "" do
			line = assert(f:read("*l"))
			header[#header+1] = line
			header[#header+1] = "\n"
			size = size + 1 + string.len(line)
		end
		f:close()
		out:write("chunk " .. size .. "\n")
		out:write(unpack(header))
		return
	end

	if what == "body" then
		local line
		while line ~= "" do
			line = assert(f:read("*l"))
			size = size -1 -string.len(line)
		end
	end

	out:write("chunk " .. size .. "\n")
	while true do
		local data = f:read(4096)
		if data == nil then break end
		out:write(data)
	end

	f:close()
end

-- ============================= MAIN =====================================

local endpoint = arg[1]
if endpoint == nil or not endpoint:match('^[a-zA-Z]+$') then
	io.stderr:write([[
Usage: ]]..arg[0]..[[ endpointname [mailbox] [dbfile]
]])
	os.exit(1)
end

local mailbox = '~/Mail'
if arg[2] ~= nil then mailbox = arg[2] end
local mailbox_opt = ' ' .. mailbox

local database = mailbox..'.'..endpoint..'.db.txt'
if arg[3] ~= nil then database = arg[3] end
local database_opt = ' --db-file '..database

-- run mddiff and send the output to the client
local r = io.popen("./mddiff"..database_opt..mailbox_opt,"r")
while true do
	local l = r:read("*l")
	if l ~= nil then
		io.write(l,'\n')
	else
		break
	end
end
r:close()

-- end the first phase, now the client should
-- apply the diff eventually asking for the transmission
-- of some data
io.write('END\n')

-- process client commands
while true do
	local l = io.read('*l')
	if l == nil then 
		-- end of input stream
		io.stderr:write('Client died\n')
		return 2
	end
	if l:match('^COMMIT$') then
		-- the client applied the diff, the new mailbox
		-- fingerprint should be used for the next sync
		os.rename(database..".new", database) 
		return 0
	elseif l:match('^GET ') then
		local path = l:match('GET ([^%s]+)')
		transmit(io.stdout, path, "all")
	elseif l:match('^GETHEADER ') then
		local path = l:match('GETHEADER ([^%s]+)')
		transmit(io.stdout, path, "header")
	elseif l:match('^GETBODY ') then
		local path = l:match('GETBODY ([^%s]+)')
		transmit(io.stdout, path, "body")
	else
		-- protocol error
		io.stderr:write('Invalid command '..l..'\n')
		return 1
	end
end

-- vim:set ts=4:
