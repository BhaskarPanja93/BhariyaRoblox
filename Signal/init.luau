--!strict
--!native
--!optimize 2


--[[
Signal v1.0.1
Keep a note of the version for tracking updates and changes
]]


-- Depends on my Thread Module
-- Replace usage with task.spawn and task.defer if thread module is not desired
const Thread = require(script.Parent:WaitForChild("Thread"))


-- Connection type
export type Connection<T... = ...any> = {
	Connected: boolean,
	Disconnect: (self: Connection<T...>) -> (),
	_isOnce: boolean,
	_thread: thread?,
	_callback: ((T...) -> ())?,
	_previous: Connection<T...>|Signal<T...>|nil,
	_next: Connection<T...>|Signal<T...>|nil,
	__index: Connection<T...>
}


-- Signal type
export type Signal<T... = ...any> = {
	Fire: (self: Signal<T...>, T...) -> (),
	Connect: (self: Signal<T...>, callback: (T...) -> ()) -> Connection<T...>,
	Once: (self: Signal<T...>, callback: (T...) -> ()) -> Connection<T...>,
	Wait: (self: Signal<T...>) -> T...,
	DisconnectAll: (self: Signal<T...>) -> (),
	_next: Connection<T...>?,
	_previous: Connection<T...>?,
	__index: Signal<T...>
}


-- Every callback and waiter is wrapped in a Connection object
const Connection = {} :: Connection
Connection.__index = Connection


-- Disconnects a connection so it doesn't receive any further fires
function Connection:Disconnect()


	-- Update the connection's Connected flag
	self.Connected = false


	-- If previous exist, set its next node to the current's next
	if self._previous then
		self._previous._next = self._next
	end


	-- If next exist, set its previous node to the current's previous
	if self._next then
		self._next._previous = self._previous
	end
end


-- Signal is the main object that listeners can attach callbacks to or wait for
const Signal = {} :: Signal
Signal.__index = Signal


-- Append a new connection to the signal
const function addNewConnection(signal: Signal, connection: Connection)


	connection.Connected = true


	-- Add connection to head if no head exist
	if not signal._next then
		signal._next = connection
		connection._previous = signal
	end


	-- If a tail exists, link that as self's previous
	if signal._previous then
		signal._previous._next = connection
		connection._previous = signal._previous
	end


	-- Set new connection as the new tail
	signal._previous = connection
	connection._next = signal
end


-- Attach a callback to the signal
function Signal:Connect(callback)


	-- Create a new connection
	-- False isOnce says the connection should stay until it's manually disconnected
	-- Save the provided callback to execute when a fire is received
	const connection = setmetatable({_callback = callback}, Connection) :: Connection


	-- Insert connection at the end of connection list
	addNewConnection(self, connection)


	-- Return the created connection
	return connection
end



function Signal:Once(callback)


	-- Create a new connection
	-- True isOnce says the connection should auto drop after it receives a fire
	-- Save the provided callback to execute when a fire is received
	const connection = setmetatable({_isOnce = true, _callback = callback}, Connection) :: Connection


	-- Insert connection at the end of connection list
	addNewConnection(self, connection)


	-- Return the created connection
	return connection
end


function Signal:Wait()


	-- Create a new connection
	-- True isOnce says the connection should auto drop after it receives a fire
	-- Save the current thread, for future resumption
	const connection = setmetatable({_isOnce=true, _thread = coroutine.running()}, Connection) :: Connection


	-- Insert connection at the end of connection list
	addNewConnection(self, connection)


	-- Yield the caller thread
	-- Fire will resume the thread with the parameters passed
	return coroutine.yield()
end


-- Fire values to the signal which in turn will be returned to the waiters and attached callbacks
function Signal:Fire(...)


	-- Fetch the first connection
	local connection = self._next


	-- Traverse the linked list
	while connection and connection ~= self do


		-- Store the next connection
		const nextConnection = connection._next


		-- If connection was a once type, disconnect from the linked list
		if connection._isOnce then
			connection:Disconnect()
		end


		-- If waiter is a yielded thread, execute it via task.spawn
		if connection._thread then
			pcall(task.spawn, connection._thread, ...)


		-- If waiter is a function, execute it via reusable thread
		elseif connection._callback then
			pcall(Thread.Spawn, connection._callback, ...)
		end


		-- Get the next connection
		connection = nextConnection
	end
end


-- Disconnect all connections from the signal
function Signal:DisconnectAll()


	-- Fetch the first connection
	local connection = self._next


	-- Nullify the first and last connection
	self._next = nil
	self._previous = nil


	-- Traverse the linked list and mark everyone as disconnected
	while connection and connection ~= self do
		connection.Connected = false
		connection = connection._next
	end
end


-- Create a new signal
return function<T...>() return setmetatable({}, Signal) :: Signal<T...> end