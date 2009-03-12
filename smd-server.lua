#! /usr/bin/env lua5.1

require 'lfs'

function transmit(path, what)
	what = what or "all"
	local size = assert(lfs.attributes(path)).size
	local f = assert(io.open(path,"r"))

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
		io.write("chunk " .. size .. "\n")
		io.write(unpack(header))
		return
	end

	if what == "body" then
		local line
		while line ~= "" do
			line = assert(f:read("*l"))
			size = size -1 -string.len(line)
		end
	end

	io.write("chunk " .. size .. "\n")
	while true do
		local data = f:read(4096)
		if data == nil then break end
		io.write(data)
	end

	f:close()
end

transmit(arg[1], arg[2])

-- vim:set ts=4:
