--!strict
--!native
--!optimize 2


--[[
Thread v1.0.1
Keep a note of the version for tracking updates and changes
]]


-- Pool of idle threads
local _pool: {thread} = {}


-- Execute the function with the parameters passed and return the thread back to pool
const function executeAndSave(func, ...)
	pcall(func, ...)
	table.insert(_pool, coroutine.running())
end


-- Return a never ending infinite yielding thread that expects a function and its parameters when resumed
const function infiniteThread()
	while true do
		executeAndSave(coroutine.yield())
	end
end


-- Spawn a new thread that runs the infinite function
const function createThread()
	return task.spawn(infiniteThread)
end


-- Fetch an old thread from the pool or create a new one
const function fetchThread()
	return table.remove(_pool) or createThread()
end


-- Thread is a constructor that offers methods to create new threads
local Thread = {}


-- Run a function immediately
function Thread.Spawn<T...>(func: (T...)->(), ...: T...)
	return task.spawn(fetchThread(), func, ...)
end


-- Run a function after current frame
function Thread.Defer<T...>(func: (T...)->(), ...: T...)
	return task.defer(fetchThread(), func, ...)
end


-- Run a delayed function
function Thread.Delay<T...>(duration: number, func: (T...)->(), ...: T...)
	return task.delay(duration, fetchThread(), func, ...)
end


-- Return the table
return table.freeze(Thread)