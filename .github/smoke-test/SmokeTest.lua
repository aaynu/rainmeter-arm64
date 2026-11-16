-- Script measure of SmokeTest.ini. It reports one log line, which Run.ps1 compares against the
-- expected text, so every value here has to be deterministic.

function Initialize()
	local results = {}
	local function add(name, value)
		results[#results + 1] = name .. '=' .. tostring(value)
	end

	-- Arithmetic, strings and tables.
	local sum = 0
	for i = 1, 100000 do
		sum = sum + i % 7
	end
	add('sum', sum)
	add('format', string.format('%.3f|%05d|%s', math.pi, 42, ('x'):rep(3)))
	add('integer', 2 ^ 53)

	local numbers = { 5, 3, 9, 1 }
	table.sort(numbers)
	add('sort', table.concat(numbers, ','))
	add('gsub', (('a1b22c333'):gsub('%d+', function(digits) return '<' .. #digits .. '>' end)))

	-- Errors raised by Lua code, by C code and by the VM itself, each caught by pcall.
	local ok1, message = pcall(function() error('boom', 0) end)
	local ok2 = pcall(string.rep)
	local ok3 = pcall(function() local nothing = nil; return nothing.field end)
	add('pcall', table.concat({ tostring(ok1), message, tostring(ok2), tostring(ok3) }, ':'))

	-- Coroutines.
	local resume = coroutine.wrap(function(a)
		local b = coroutine.yield(a + 1)
		return a + b
	end)
	add('coroutine', resume(1) .. ',' .. resume(10))

	-- The implicit 'arg' table of Lua 5.0, which Rainmeter's LuaJIT keeps for old skins.
	local function count(...)
		return arg.n
	end
	add('vararg', count('a', 'b', 'c'))

	-- Rainmeter's own bindings.
	add('option', SELF:GetOption('Marker', ''))
	add('config', SKIN:GetVariable('CURRENTCONFIG', ''))

	SKIN:Bang('!Log', 'SMOKETEST lua ' .. table.concat(results, ' '), 'Notice')
end

function Update()
	return 42
end
