-- Released under the terms of GPLv3 or at your option any later version.
-- No warranties.
-- Copyright 2009 Enrico Tassi <gares@fettunta.org>

local PROTOCOL_VERSION="1.0"

local verbose = false

local mkdir_p_cache = {}

local PREFIX = '@PREFIX@'

local __G = _G

module('syncmaildir',package.seeall)

MDDIFF = ""
if string.sub(PREFIX,1,1) == '@' then
		MDDIFF = os.getenv('HOME')..'/SYNC/syncmaildir/mddiff '
		io.stderr:write('smd-client not installed, assuming mddiff is: ',
			MDDIFF,'\n')
else
		MDDIFF = PREFIX .. '/bin/mddiff '
end

function set_verbose(v)
	verbose = v
end

function log(msg)
	if verbose then
		io.stderr:write(msg,'\n')
	end
end

function log_error(msg)
	io.stderr:write('ERROR: ',msg,'\n')
end

function log_tag(tag)
	io.stderr:write('TAG: ',tag,'\n')
end

function log_tags(context, cause, human, ...)
	if human then human = "necessary" else human = "avoidable" end
	log_tag("error::context::"..context)
	log_tag("error::probable-cause::"..cause)
	log_tag("error::human-intervention::"..human)
	for i=1,select('#',...) do
		log_tag("error::suggested-action::"..select(i,...))
	end
end

function trace(x)
	if verbose then
		local t = {}
		local n = 2
		while true do
			local d = debug.getinfo(n,"nl")
			if not d or not d.name then break end
			t[#t+1] = d.name ..":".. (d.currentline or "?")
			n=n+1
		end
		io.stderr:write('TRACE: ',table.concat(t," | "),'\n')
	end
	return x
end

function transmit(out, path, what)
	what = what or "all"
	local f, err = io.open(path,"r")
	if not f then
		log_error("Unable to open "..path..": "..(err or "no error"))
		log_error("The problem should be transient, please retry.")
		error('Unable to open requested file.')
	end
	local size, err = f:seek("end")
	if not size then
		log_error("Unable to calculate the size of "..path)
		log_error("If it is not a regular file, please move it away.")
		log_error("If it is a regular file, please report the problem.")
		error('Unable to calculate the size of the requested file.')
	end
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
		out:flush()
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
		local data = f:read(16384)
		if data == nil then break end
		out:write(data)
	end
	out:flush()

	f:close()
end

function receive(inf,outfile)
	local outf = io.open(outfile,"w")
	if not outf then
			log_error("Unable to open "..outfile.." for writing.")
			log_error('It may be caused by bad directory permissions, '..
				'please check.')
			os.exit(1)
	end

	local line = inf:read("*l")
	if line == nil or line == "ABORT" then
		log_error("Data transmission failed.")
		log_error("This problem is transient, please retry.")
		error('server sent ABORT or connection died')
	end
	local len = tonumber(line:match('^chunk (%d+)'))
	while len > 0 do
		local next_chunk = 16384
		if len < next_chunk then next_chunk = len end
		local data = inf:read(next_chunk)
		len = len - data:len()
		outf:write(data)
	end
	outf:close()
end

function handshake(dbfile)
	-- send the protocol version and the dbfile sha1 sum
	io.write('protocol ',PROTOCOL_VERSION,'\n')
	touch(dbfile)
	local inf = io.popen('sha1sum '.. dbfile,'r')
	local db_sha = inf:read('*a'):match('^(%S+)')
	io.write('dbfile ',db_sha,'\n')
	io.flush()

	-- check protocol version and dbfile sha
	local line = io.read('*l')
	if line == nil then
		log_error("Network error.")
		log_error("Unable to get any data from the other endpoint.")
		log_error("This problem may be transient, please retry.")
		log_error("Hint: did you correctly setup the SERVERNAME variable")
		log_error("on your client? Did you add an entry for it in your ssh")
		log_error("configuration file?")
		os.exit(1)
	end
	local protocol = line:match('^protocol (.+)$')
	if protocol ~= PROTOCOL_VERSION then
		log_error('Wrong protocol version.')
		log_error('The same version of syncmaildir must be user on '..
			'both endpoints')
		os.exit(1)
	end
	line = io.read('*l')
	if line == nil then
		log_error "The client disconnected during handshake"
		os.exit(1)
	end
	local sha = line:match('^dbfile (%S+)$')
	if sha ~= db_sha then
		log_error('Local dbfile and remote db file differ.')
		log_error('Remove both files and push/pull again.')
		os.exit(1)
	end
end

function dbfile_name(endpoint, mailboxes)
	local HOME = os.getenv('HOME')
	os.execute('mkdir -p '..HOME..'/.smd')
	local dbfile = HOME..'/.smd/' ..endpoint:gsub('/$',''):gsub('/','_').. '__' 
		..table.concat(mailboxes,'__'):gsub('/$',''):gsub('/','_').. '.db.txt'
	return dbfile
end

function mkdir_p(path)
	local t = {} 
	for m in path:gmatch('([^/]+)') do t[#t+1] = m end
	table.remove(t,#t)
	local make = function(t)
		local dir = table.concat(t,'/')
		if not mkdir_p_cache[dir] then
			local rc = os.execute('mkdir -p '..dir)
			if rc ~= 0 then
				log_error("Unable to create directory "..dir)
				log_error('It may be caused by bad directory permissions, '..
					'please check.')
				os.exit(1)
			end
			mkdir_p_cache[dir] = true
		end
	end
	make(t)
	if t[#t] == "tmp" then
		t[#t] = "new"
		make(t)
		t[#t] = "cur"
		make(t)
	end
end

function tmp_for(path,use_tmp)
	if use_tmp == nil then use_tmp = true end
	local t = {} 
	for m in path:gmatch('([^/]+)') do t[#t+1] = m end
	local fname = t[#t]
	local time, pid, host, tags = fname:match('^(%d+)%.(%d+)%.([^:]+)(.*)$')
	time = time or os.date("%s")
	pid = pid or "1"
	host = host or "localhost"
	tags = tags or ""
	table.remove(t,#t)
	local i, found = 0, false
	if use_tmp then
		for i=#t,1,-1 do
			if t[i] == 'cur' or t[i] == 'new' then 
				t[i] = 'tmp' 
				found = true
				break
			end
		end
	end
	local newpath
	if not found then
		time = os.date("%s")
		t[#t+1] = time..'.'..pid..'.'..host..tags
		newpath = table.concat(t,'/') 
	else
		t[#t+1] = fname
		newpath = table.concat(t,'/') 
	end
	mkdir_p(newpath)
	local attempts = 0
	while exists(newpath) do 
		if attempts > 10 then
			error('unable to generate a fresh tmp name')			
		else 
			time = os.date("%s")
			host = host .. 'x'
			t[#t] = time..'.'..pid..'.'..host..tags
			newpath = table.concat(t,'/') 
			attempts = attempts + 1
		end
	end
	return newpath
end

function sha_file(name)
	local inf = io.popen(MDDIFF .. name)
	local hsha, bsha = inf:read('*a'):match('(%S+) (%S+)') 
	inf:close()
	return hsha, bsha
end
function exists(name)
	local f = io.open(name,'r')
	if f ~= nil then
		f:close()
		return true
	else
		return false		
	end
end

function exists_and_sha(name)
	if exists(name) then
		local h, b = sha_file(name)
		return true, h, b
	else
		return false
	end
end

function touch(f)
	local h = io.open(f,'r')
	if h == nil then
		h = io.open(f,'w')
		if h == nil then
			log_error('Unable to touch '..f)
			os.exit(1)
		else
			h:close()
		end
	else
		h:close()
	end
end

function quote(s)
	return "'" .. s:gsub("'","\\'"):gsub("%)","\\)").. "'"
end

function set_strict()
-- strict access to the global environment
	setmetatable(__G,{
		__newindex = function (t,k,v)
			local d = debug.getinfo(2,"nl")
			error((d.name or '?')..': '..(d.currentline or '?')..
				' :attempt to create new global '..k)
		end;
		__index = function(t,k)
			local d = debug.getinfo(2,"nl")
			error((d.name or '?')..': '..(d.currentline or '?')..
				' :attempt to read undefined global '..k)
		end;
	})
end

-- vim:set ts=4:
