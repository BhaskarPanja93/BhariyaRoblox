--!strict
--!native
--!optimize 2


--[[ 
WHY:
- Pub-Sub functionality helps multiple functions or scripts to wait and get data at the same time.
	(https://en.wikipedia.org/wiki/Publish%E2%80%93subscribe_pattern)


NOTES:
- Linked list based approach has been used to allow easy removes at abrupt indexes avoiding table.remove's element shift


TESTS:
[PASSED] Checked for memory leaks


UPDATES:
- 07-09-2026
	Minor changes and rearrangements for use in external editors
]]


-- Depends on my Threads Module
-- Replace usage with task.spawn and task.defer if threads module is not desired
local Threads = require(script.Parent:WaitForChild("Threads"))


-- Every callback and waiter is wrapped in a Connection object
local Connection = {} :: Connection
Connection.__index = Connection


-- Connection type
export type Connection<ParamsT... = ...any> = {
	Disconnect: (self: Connection<ParamsT...>) -> (),
	_isOnce: boolean,
	_thread: thread?,
	_callback: ((ParamsT...) -> ())?,
	_previous: Connection<ParamsT...>?,
	_next: Connection<ParamsT...>?,
	__index: Connection<ParamsT...>
}


-- Disconnects a connection so it doesn't receive any further fires
function Connection:Disconnect()


	-- Fetch next and previous connections
	local previousConnection = self._previous
	local nextConnection = self._next


	-- If previous exist, set its next node to the current's next
	if previousConnection then previousConnection._next = nextConnection end


	-- If next exist, set its previous node to the current's previous
	if nextConnection then nextConnection._previous = previousConnection end


	-- Dereference current's previous and next
	self._next = nil
	self._previous = nil
end


-- Signal is the main object that listeners can attach callbacks to or wait for
local Signal = {} :: Signal
Signal.__index = Signal


-- Signal type
export type Signal<ParamsT... = ...any> = {
	Fire: (self: Signal<ParamsT...>, ParamsT...) -> (),
	Connect: (self: Signal<ParamsT...>, callback: (ParamsT...) -> ()) -> Connection<ParamsT...>,
	Once: (self: Signal<ParamsT...>, callback: (ParamsT...) -> ()) -> Connection<ParamsT...>,
	Wait: (self: Signal<ParamsT...>) -> ParamsT...,
	_nextConnection: Connection<ParamsT...>?,
	_tailConnection: Connection<ParamsT...>?,
	__index: Signal<ParamsT...>
}


local function addNewConnection(signal:Signal, connection:Connection)


	-- Tail will be missing if no connection was ever added
	if not signal._tailConnection then
		signal._nextConnection = connection
		signal._tailConnection = connection
		return
	end


	-- Old tail
	local oldTail = signal._tailConnection


	-- Fix link changes
	signal._tailConnection = connection
	oldTail._next = connection
	connection._previous = oldTail
end


-- Attach a callback to the signal
function Signal:Connect(callback)
	

	-- Create a new connection
	-- False isOnce says the connection should stay until it's manually disconnected
	-- Save the provided callback to execute when a fire is received
	local connection = setmetatable({}, Connection) :: Connection
	connection._callback = callback
	
	
	-- Insert connection at the end of connection list
	addNewConnection(self, connection)


	-- Return the created connection
	return connection
end



function Signal:Once(callback)
	

	-- Create a new connection
	-- True isOnce says the connection should auto drop after it receives a fire 
	-- Save the provided callback to execute when a fire is received
	local connection = setmetatable({}, Connection) :: Connection
	connection._isOnce = true
	connection._callback = callback


	-- Insert connection at the end of connection list
	addNewConnection(self, connection)


	-- Return the created connection
	return connection
end


function Signal:Wait()
	
	
	-- Create a new connection
	-- True isOnce says the connection should auto drop after it receives a fire 
	-- Save the current thread, for future resumption
	local connection = setmetatable({}, Connection) :: Connection
	connection._isOnce = true
	connection._thread = coroutine.running()
	

	-- Insert connection at the end of connection list
	addNewConnection(self, connection)


	-- Yield the caller thread
	-- Fire will resume the thread with the parameters passed
	return coroutine.yield()
end


-- Fire values to the signal which in turn will be returned to the waiters and attached callbacks
function Signal:Fire(...)
	
	
	-- Fetch the first connection
	local connection = self._nextConnection


	-- Traverse the linked list
	while connection do
		
		
		-- If waiter is a function, execute it via reusable threads
		if connection._thread then task.spawn(connection._thread, ...)
			
			
		-- If waiter is a yielded thread, execute it via task.spawn
		elseif connection._callback then Threads.Spawn(connection._callback, ...)


		end


		-- If connection was a once type, disconnect from the linked list
		if connection._isOnce then connection:Disconnect() end


		-- Get the next connection
		connection = connection._next
	end
end



-- Create a new signal
return function<ParamsT...>() return setmetatable({}, Signal) :: Signal<ParamsT...> end