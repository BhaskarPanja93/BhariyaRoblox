--!strict
--!native
--!optimize 2


--[[
State v1.0.1
Keep a note of the version for tracking updates and changes
]]


-- Depends on my Signal Module
const Signal = require(script.Parent:WaitForChild("Signal"))


-- The actual State object
const State = {} :: State
State.__index = State


-- State type
export type State<T = any> = {
	Current: T,
	ChangeSignal: Signal.Signal<T, T>,
	LastModified: number,
	Update: (self: State<T>, newValue: T) -> (),
	
	__index: State<T>,
}


-- Instead of updating the value directly, this function should be used for updating the value
function State:Update(newValue)


	-- Save current time and new value
	const oldValue = self.Current
	self.Current = newValue
	self.LastModified = os.clock()


	-- Fire the signal with the old and new value so all listeners receive it
	self.ChangeSignal:Fire(oldValue, newValue)
end


-- Create a new State object
-- Initial value is required to set the type of the state
return function<T>(initial: T): State<T>


	-- Create the state object
	const state = setmetatable(
		{
			Current = initial,
			LastModified = os.clock(),
		}, State) :: State<T>


	-- Set other initial values
	state.ChangeSignal = Signal()


	return state
end