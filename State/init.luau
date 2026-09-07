--!strict
--!native
--!optimize 2


--[[ 
WHY:
- It's hard to keep track and update every dependent everytime the value changes,
	so it's better to have a callback for each dependent and let them update independently every time the "state" changes
	(https://react.dev/reference/react/useState)


NOTES:
- State has generic type, so autofill will be a great help
- Works somewhat similar to UseState in React.js where a change in the state causes a re-render


TESTS:


UPDATES:
- 07-09-2026
	Minor changes and rearrangements for use in external editors
]]


-- Depends on my Signal Module
local Signal = require(script.Parent:WaitForChild("Signal"))


-- The actual State object
local State = {} :: State
State.__index = State


-- State type
export type State<T = any> = {
	Current: T,
	ChangeSignal: Signal.Signal<T>,
	LastModified: number,
	Update: (self: State<T>, newValue: T, force: boolean?) -> (),
	
	__index: State<T>,
}


-- Instead of updating the value directly, this function should be used for updating the value
function State:Update(newValue, force)


	-- Save current time regardless of same or new value
	self.LastModified = os.clock()
	
	
	-- Set the new current value only if wasn't same already
	if force or newValue ~= self.Current then 
		self.Current = newValue 
		
		
		-- Fire the signal with the new value so all listeners receive it
		self.ChangeSignal:Fire(newValue)
	end
end


-- Create a new State object
-- Initial value is required to set the type of the state
return function<T>(initial: T): State<T>


	-- Create the state object
	local state = setmetatable({}, State) :: State<T>


	-- Set initial values
	state.Current = initial
	state.LastModified = os.clock()
	state.ChangeSignal = Signal()


	return state
end