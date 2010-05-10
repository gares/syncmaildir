-- Released under the terms of GPLv3 or at your option any later version.
-- No warranties.
-- Copyright 2008-2010 Enrico Tassi <gares@fettunta.org>
--
-- common code for smd-client/server

local PROTOCOL_VERSION="1.0"

local verbose = false
local dryrun = false
local wait_for_disconnection = false

local PREFIX = '@PREFIX@'
local BUGREPORT_ADDRESS = 'syncmaildir-users@lists.sourceforge.net'

local __G = _G
local __error = _G.error

module('syncmaildir',package.seeall)

-- set mddiff path
MDDIFF = ""
if string.sub(PREFIX,1,1) == '@' then
		MDDIFF = './mddiff'
		io.stderr:write('smd-client not installed, assuming mddiff is: ',
			MDDIFF,'\n')
else
		MDDIFF = PREFIX .. '/bin/mddiff'
end

-- set sha1sum executable name
SHA1SUM = '@SHA1SUM@'
if string.sub(SHA1SUM,1,1) == '@' then
		SHA1SUM = 'sha1sum'
end

-- set xdelta executable name
XDELTA = '@XDELTA@'
if string.sub(XDELTA,1,1) == '@' then
		XDELTA = 'xdelta'
end

-- set mkfifo executable name
MKFIFO = '@MKFIFO@'
if string.sub(MKFIFO,1,1) == '@' then
		MKFIFO = 'mkfifo'
end

-- set mkdir executable name
MKDIR = '@MKDIR@'
if string.sub(MKDIR,1,1) == '@' then
		MKDIR = 'mkdir -p'
end

-- set smd version 
SMDVERSION = '@SMDVERSION@'
if string.sub(SMDVERSION,1,1) == '@' then
		SMDVERSION = '0.0.0'
end

-- you should use logs_tags_and_fail
function error(msg)
	local d = debug.getinfo(1,"nl")
	__error((d.name or '?')..': '..(d.currentline or '?')..
	' :attempt to call error instead of log_tags_and_fail')
end

function log_tags_and_fail(msg,...)
	log_tags(...)
	__error({text=msg})
end

function log_internal_error_and_fail(msg,...)
	log_internal_error_tags(msg,...)
	__error({text=msg})
end

function set_verbose(v)
	verbose = v
end

function set_dry_run(v)
	dryrun = v
end

function set_wait_for_disconnection(v)
	wait_for_disconnection = v
end

function dry_run() return dryrun end

function log(msg)
	if verbose then
		io.stderr:write(msg,'\n')
	end
end

function log_error(msg)
	io.stderr:write('ERROR: ',msg,'\n')
end

function log_tag(tag)
	io.stderr:write('TAGS: ',tag,'\n')
end

-- this function shoud be used only by smd-client leaves
function log_tags(context, cause, human, ...)
	if human then human = "necessary" else human = "avoidable" end
	local suggestions = {}
	local suggestions_string = ""
	if select('#',...) > 0 then 
			suggestions_string = 
				"suggested-actions("..table.concat({...}," ")..")"
	else 
			suggestions_string = "" 
	end
	log_tag("error::context("..context..") "..
		"probable-cause("..cause..") "..
		"human-intervention("..human..") ".. suggestions_string)
end

-- ======================== data transmission protocol ======================

function transmit(out, path, what)
	what = what or "all"
	local f, err = io.open(path,"r")
	if not f then
		log_error("Unable to open "..path..": "..(err or "no error"))
		log_error("The problem should be transient, please retry.")
		log_tags_and_fail('Unable to open requested file.',
			"transmit", "simultaneous-mailbox-edit",false,"retry")
	end
	local size, err = f:seek("end")
	if not size then
		log_error("Unable to calculate the size of "..path)
		log_error("If it is not a regular file, please move it away.")
		log_error("If it is a regular file, please report the problem.")
		log_tags_and_fail('Unable to calculate the size of the requested file.',
			"transmit", "non-regular-file",true,
			"display-permissions("..quote(path)..")")
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
			log_tags_and_fail("Unable to write incoming data",
				"receive", "non-writeable-file",true,
				"display-permissions("..quote(outfile)..")")
	end

	local line = inf:read("*l")
	if line == nil or line == "ABORT" then
		log_error("Data transmission failed.")
		log_error("This problem is transient, please retry.")
		log_tags_and_fail('server sent ABORT or connection died',
			"receive","network",false,"retry")
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

	-- if true the db file is deleted after SHA1 computation
	local kill_db_file_ASAP = false

	-- if the db file was not there and --dry-run, we schedule its deletion
	if dry_run() and not exists(dbfile) then kill_db_file_ASAP = true end
	
	-- we must have at least an empty file to compute its SHA1 sum
	touch(dbfile)
	local inf = io.popen(SHA1SUM..' '.. dbfile,'r')
	
	local db_sha = inf:read('*a'):match('^(%S+)')
	io.write('dbfile ',db_sha,'\n')
	io.flush()

	-- but if the file was not there and --dry-run, we should not create it
	if kill_db_file_ASAP then os.remove(dbfile) end

	-- check protocol version and dbfile sha
	local line = io.read('*l')
	if line == nil then
		log_error("Network error.")
		log_error("Unable to get any data from the other endpoint.")
		log_error("This problem may be transient, please retry.")
		log_error("Hint: did you correctly setup the SERVERNAME variable")
		log_error("on your client? Did you add an entry for it in your ssh")
		log_error("configuration file?")
		log_tags_and_fail('Network error',"handshake", "network",false,"retry")
	end
	local protocol = line:match('^protocol (.+)$')
	if protocol ~= PROTOCOL_VERSION then
		log_error('Wrong protocol version.')
		log_error('The same version of syncmaildir must be used on '..
			'both endpoints')
		log_tags_and_fail('Protocol version mismatch',
			"handshake", "protocol-mismatch",true)
	end
	line = io.read('*l')
	if line == nil then
		log_error "The client disconnected during handshake"
		log_tags_and_fail('Network error',"handshake", "network",false,"retry")
	end
	local sha = line:match('^dbfile (%S+)$')
	if sha ~= db_sha then
		log_error('Local dbfile and remote db file differ.')
		log_error('Remove both files and push/pull again.')
		log_tags_and_fail('Database mismatch',
			"handshake", "db-mismatch",true,"run(rm "..
			quote(dbfile)..")")
	end
end

function wait_disconnect(f)
	if wait_for_disconnection then
		local data = f:read('*l')
		if data ~= nil then
			log_internal_error_and_fail('protocol error', "wait_disconnect")
		end
	end
end

function dbfile_name(endpoint, mailboxes)
	local HOME = os.getenv('HOME')
	os.execute(MKDIR..' '..HOME..'/.smd/')
	local dbfile = HOME..'/.smd/' ..endpoint:gsub('/$',''):gsub('/','_').. '__' 
		..table.concat(mailboxes,'__'):gsub('/$',''):gsub('/','_').. '.db.txt'
	return dbfile
end

-- =================== fast/maildir aware mkdir -p ==========================

local mkdir_p_cache = {}

-- function to create the dir calling the real mkdir command
-- pieces is a list components of the patch, they are concatenated
-- separated by '/' and if absolute is true prefixed by '/'
function make_dir_aux(absolute, pieces)
	local root = ""
	if absolute then root = '/' end
	local dir = root .. table.concat(pieces,'/')
	if not mkdir_p_cache[dir] then
		local rc = os.execute(MKDIR..' '..dir)
		if rc ~= 0 then
			log_error("Unable to create directory "..dir)
			log_error('It may be caused by bad directory permissions, '..
				'please check.')
			log_tags_and_fail("Directory creation failed",
				"mkdir", "wrong-permissions",true,
				"display-permissions("..quote(dir)..")")
		end
		mkdir_p_cache[dir] = true
	end
end

-- creates a directory that can contains a path, should be equivalent
-- to mkdir -p `dirname path`. moreover, if the last component is 'tmp',
-- 'cur' or 'new', they are all are created too. exampels:
--  mkdir_p('/foo/bar')     creates /foo
--  mkdir_p('/foo/bar/')    creates /foo/bar/
--  mkdir_p('/foo/tmp/baz') creates /foo/tmp/, /foo/cur/ and /foo/new/
function mkdir_p(path)
	local t = {} 

	local absolute = false
	if string.byte(path,1) == string.byte('/',1) then absolute = true end

	-- tokenization
	for m in path:gmatch('([^/]+)') do t[#t+1] = m end

	-- strip last component is not ending with '/'
	if string.byte(path,string.len(path)) ~= string.byte('/',1) then 
		table.remove(t,#t) 
	end

	make_dir_aux(absolute, t)

	--  ensure new, tmp and cur are there
	local todo = { ["new"] = true, ["cur"] = true, ["tmp"]=true }
	if todo[t[#t]] == true then
		todo[t[#t]] = nil
		for x, _ in pairs(todo) do
			t[#t] = x
			make_dir_aux(absolute, t)
		end
	end
end

-- ============== maildir aware tempfile name generator =====================

-- complex function to generate a valid tempfile name for path, possibly using
-- the tmp directory if a subdir of path is new or cur and use_tmp is true
--
function tmp_for(path,use_tmp)
	if use_tmp == nil then use_tmp = true end
	local t = {} 
	local absolute = ""
	if string.byte(path,1) == string.byte('/',1) then absolute = '/' end
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
	make_dir_aux(absolute == '/', t)
	local newpath
	if not found then
		time = os.date("%s")
		t[#t+1] = time..'.'..pid..'.'..host..tags
	else
		t[#t+1] = fname
	end
	newpath = absolute .. table.concat(t,'/') 
	local attempts = 0
	while exists(newpath) do 
		if attempts > 10 then
			log_internal_error_and_fail('unable to generate a fresh tmp name',
				"tmp_for")
		else 
			time = os.date("%s")
			host = host .. 'x'
			t[#t] = time..'.'..pid..'.'..host..tags
			newpath = absolute .. table.concat(t,'/') 
			attempts = attempts + 1
		end
	end
	return newpath
end

-- =========================== misc helpers =================================

-- like s:match(spec) but chencks no captures are numm
function parse(s,spec)
	local res = {s:match(spec)}
	local _,expected = spec:gsub('%b()','')
	if #res ~= expected then
		log_internal_error_and_fail('Error parsing "'..s..'"', "protocol")
	end
	return unpack(res)
end

local mddiff_handler = {}

function sha_file(name)
	local pipe, rm_pipe = nil, false
	if mddiff_handler.inf == nil then
		local rc
		local base_dir
		local home = os.getenv('HOME')
		local user = os.getenv('USER') or 'nobody'
		local mangled_name = string.gsub(name,"/","-")
		local attempt = 0
		if home ~= nil then
			base_dir = home ..'/.smd/fifo/'
		else
			base_dir = '/tmp/'
		end
		repeat 
			pipe = base_dir..'smd-'..user..os.time()..mangled_name..attempt
			attempt = attempt + 1
			mkdir_p(pipe)
			rc = os.execute(MKFIFO..' -m 600 '..pipe)
		until rc == 0 or attempt > 10
		if rc ~= 0 then
			log_internal_error_and_fail('unable to create fifo', "sha_file")
		end
		mddiff_handler.inf = io.popen(MDDIFF .. ' ' .. pipe)
		mddiff_handler.outf = io.open(pipe,'w')
		rm_pipe = true
	end
	mddiff_handler.outf:write(name..'\n')
	mddiff_handler.outf:flush()
	local data = mddiff_handler.inf:read('*l')
	if data:match('^ERROR') then
		log_tags_and_fail('Failed to sha1 a message',
			'sha_file','modify-while-update',false,'retry')
	end
	local hsha, bsha = data:match('(%S+) (%S+)') 
	if hsha == nil or bsha == nil then
		log_internal_error_and_fail('mddiff incorrect behaviour', "mddiff")
	end
	-- we are now sure that both endpoints opened the file, thus
	-- we can safely garbage collect it
	if rm_pipe then os.remove(pipe) end
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

function cp(src,tgt)
	local s,err = io.open(src,'r')
	if not s then return 1 end
	local t,err = io.open(tgt,'w+')
	if not t then return 1 end
	local data
	repeat
		data = s:read(4096)
		if data then t:write(data) end
	until data == nil
	t:close()
	s:close()
	return 0
end

function touch(f)
	local h = io.open(f,'r')
	if h == nil then
		h = io.open(f,'w')
		if h == nil then
			log_error('Unable to touch '..quote(f))
			log_tags_and_fail("Unable to touch a file",
				"touch","bad-permissions",true,
				"display-permissions("..quote(f)..")")
		else
			h:close()
		end
	else
		h:close()
	end
end

function quote(s)
	return '"' .. s:gsub('"','\\"'):gsub("%)","\\)").. '"'
end

function homefy(s)
	if string.byte(s,1) == string.byte('/',1) then
		return s
	else
		return os.getenv('HOME')..'/'..s
	end
end	

function assert_exists(name)
	local name = name:match('^([^ ]+)')
	local rc = os.execute('type '..name..' >/dev/null 2>&1')
	assert(rc == 0,'Not found: "'..name..'"')
end

-- a bit brutal, but correct
function url_quote(txt)
	return string.gsub(txt,'.',
		function(x) return string.format("%%%02X",string.byte(x)) end)
end

function log_internal_error_tags(msg,ctx)
	log_tags("internal-error",ctx,true,
	'run(gnome-open "mailto:'..BUGREPORT_ADDRESS..'?'..
		'subject='..url_quote("[smd-bug] internal error")..'&'..
		'body='..url_quote(
			'This email reports an internal error, '..
			'something that should never happen.\n'..
			'To help the developers to find and solve the issue, please '..
			'send this email.\n'..
			'If you are able to reproduce the bug, please attach a '..
			'detailed description\n'..
			'of what you do to help the developers to experience the '..
			'same malfunctioning.'..
			'\n\n'..
			'smd-version: '..SMDVERSION..'\n'..
			'error-message: '..tostring(msg)..'\n'..
			'backtrace:\n'..debug.traceback()
		)..'")')
end

-- parachute
function parachute(f,rc)
	xpcall(f,function(msg)
		if type(msg) == "table" then
			log_error(tostring(msg.text))
		else
			log_internal_error_tags("unknown","unknown")
			log_error(tostring(msg))
			log_error(debug.traceback())
		end
		os.exit(rc)
	end)
end

-- prints the stack trace. idiom is 'rewturn(trance(x))' so that
-- we have in the log the path for the leaf that computed x
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

-- strict access to the global environment
function set_strict()
	setmetatable(__G,{
		__newindex = function (t,k,v)
			local d = debug.getinfo(2,"nl")
			__error((d.name or '?')..': '..(d.currentline or '?')..
				' :attempt to create new global '..k)
		end;
		__index = function(t,k)
			local d = debug.getinfo(2,"nl")
			__error((d.name or '?')..': '..(d.currentline or '?')..
				' :attempt to read undefined global '..k)
		end;
	})
end

-- vim:set ts=4:
