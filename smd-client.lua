#!/usr/bin/env lua5.1

function receive(inf,outfile)
	local outf = assert(io.open(outfile,"w"))

	local line = inf:read("*l")
	local len = tonumber(line:match('^chunk (%d+)'))
	while len > 0 do
		local next_chunk = 4096
		if len < next_chunk then next_chunk = len end
		local data = inf:read(next_chunk)
		len = len - data:length()
		outf:write(data)
	end
	outf:close()
end

function receive_delta(inf)
	local cmds = {}
	local line = ""

	repeat
		line = inf:read("*l")
		if line ~= "END" then cmds[#cmds+1] = line end
	until line == "END"

	return cmds
end

function execute(cmd)
	local opcode = cmd:match('^(%S+)')

	if opcode == "ADD" then
		local name, hsha, bsha = cmd:match('ADD (%S+) (%S+) (%S+)')

	elseif opcode == "DELETE" then
		local name, hsha, bsha = cmd:match('DELETE (%S+) (%S+) (%S+)')

	elseif opcode == "REPLACEHEADER" then
		local name1, hsha1, name2, hsha2 = 
			cmd:match('REPLACEHEADER (%S+) (%S+) WITH (%S+) (%S+)')

	elseif opcode == "COPYBODY" then
		local name1, bsha1, name2, bsha2 = 
			cmd:match('COPYBODY (%S+) (%S+) WITH (%S+) (%S+)')

	elseif opcode == "REPLACE" then
		local name1, hsha1, bsha1, name2, hsha2, bsha2 = 
		   cmd:match('REPLACE (%S+) (%S+) (%S+) WITH (%S+) (%S+) (%S+)')

	else
		error('Unknown opcode '..opcode)
	end
end

