--!strict
--!native
--!optimize 2


local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")


local Threads = require("./Threads")
local Promise = require("./Promise")
local Signal = require("./Signal")
local State = require("./State")


local Types = require("@self/Types")
local Constants = require("@self/Constants")


local Vault = {} :: Types.Vault
Vault.__index = Vault


local ServerShuttingDown = false
local DataStoreHolders: {[string]: Types.DataStoreHolder} = {}


local function DeepClone<DataT>(template: DataT): DataT
	if type(template) ~= "table" then
		return template
	end
	local clone = {}
	for index, value in template :: {[any]:any} do
		clone[index] = DeepClone(value)
	end
	return clone :: DataT
end


local function Reconcile<DataT>(target: any, template: DataT): DataT
	if target == nil then
		return DeepClone(template)
	end
	if typeof(target) ~= "table" or typeof(template) ~= "table" then
		return target
	end
	for key, value in pairs(template) do
		target[key] = Reconcile(target[key], value)
	end
	return target
end


-- Fetch a DataStoreHolder
local function FetchDataStoreHolder(dsName: string): Types.DataStoreHolder


	-- Fetch datastore holder by name
	local dsh: Types.DataStoreHolder = DataStoreHolders[dsName]


	-- Check if non-existent
	if dsh == nil then


	-- Create new datastore holder
		dsh = {
			Name = dsName,
			Vaults = {},
			VaultDataStore = DataStoreService:GetDataStore(dsName),
			LockDataStore = DataStoreService:GetDataStore(dsName),
			LockMemoryStore = MemoryStoreService:GetHashMap(dsName)
		}


		-- Register the new datastore holder
		DataStoreHolders[dsName] = dsh
	end


	-- Return datastore holder
	return dsh
end


-- Find or create a vault object (unusable)
-- Call OpenVaultAsync to make the vault usable
return function<DataT>(dsName: string, vaultName: string, template: DataT): DataT


	local now = DateTime.now().UnixTimestampMillis


	-- Fetch DataStoreHolder
	local dsh = FetchDataStoreHolder(dsName)


	-- If vault already in server, return it blindly
	local vault: Types.Vault<DataT> = dsh.Vaults[vaultName]
	if vault then
		return vault
	end


	-- Else create a new vault
	vault = {} :: Types.Vault<DataT>
	dsh.Vaults[vaultName] = vault


	-- Vault parameters scoped to the function
	local SessionId = HttpService:GenerateGUID(false)
	local UsableState = State(false)
	local PublicData: DataT = DeepClone(template)
	local LockData: Types.LockData = {JobId=game.JobId, Session=SessionId, LockedAt=0}
	local ActivityData: Types.ActivityData =
		{
			FirstLogIn = now,
			LastLogIn = now,
			LastLogOut = now,
			LastSave = now
		}
	local NextReaderId = 0
	local ActiveReaders: {number} = {}
	local HasUnsavedChanges= true
	local DataUpdatedSignal:Signal.Signal<any, ...any> = Signal()
	local MessagingChanging = false
	local MessagingUsableState = State(false)
	local MessagingChannel: RBXScriptConnection
	local LockAcquireChanging = false
	local LockAcquireState = State(false)
	local MSStoredLock: Types.LockData?
	local MSLockState: Types.LockState
	local AcquireSentAt = 0
	local ResponseReceivedAt = 0
	local AcquireSentTo = ""
	local AcknowledgedReceivedFrom = ""
	local ReleasedReceivedFrom = ""


	vault.Name = vaultName
	vault.Usable = UsableState
	vault.DataUpdatedSignal = DataUpdatedSignal
	vault.SessionId = SessionId
	vault.Locals = {}


	-- The function to return activity data
	function vault:GetActivityData()
		return ActivityData
	end


	-- The function to return public data
	function vault:GetPublicData()
		return PublicData
	end


	-- The function to update any field in the data
	-- This also signals all update listeners about the change
	function vault:UpdateData(value: any, ...)
		local keys:{string|number} = {...}
		local pointer:{[string|number]:any} = PublicData
		-- Iterate through the keys and update the current pointer
		for i, key in keys do
			if i == #keys then
			-- If reached the end update the pointer
				pointer[key] = value
			else
				-- Create empty table if it doesn't exist
				pointer[key] = pointer[key] or {}
				-- Move the pointer to the next key
				pointer = pointer[key]
			end
		end
		-- Flag the vault as needs saving
		HasUnsavedChanges = true
		-- Fire the signal for data update listeners
		DataUpdatedSignal:Fire(value, ...)
	end


	local function LockConsensusL1Async():(boolean, boolean?, Types.LockState?)
		local success, lock:Types.LockData? = pcall(dsh.LockMemoryStore.GetAsync, dsh.LockMemoryStore, "_DVL/"..vaultName)
		if not success then
			return false, nil, nil
		end
		MSStoredLock = lock
		if lock == nil then
			MSLockState = Constants.LockState.NONEXISTANT
			return true, nil, MSLockState
		else
			if lock.LockedAt + Constants.MSLockStaleDelay < now then
				MSLockState = Constants.LockState.STALE
			else
				MSLockState = Constants.LockState.FRESH
			end
			return true, lock.Session==SessionId, MSLockState
		end
	end


	local function LockConsensusL2Async():(boolean, Types.AcquireStatus?)
		if MSStoredLock == nil then return false, nil end
		-- The code no longer checks the number of times acquire was sent, it checks time difference between acquire and response
		-- So there is no need to worry about a delayed response. we can safely ignore that knowing it has updated the reception time
		--if AcquireSentAt and ResponseReceivedAt > AcquireSentAt then
		--	if AcquireSentTo == AcknowledgedReceivedFrom then
		--		return true, Constants.AcquireState.ACKNOWLEDGED
		--	elseif AcquireSentTo == ReleasedReceivedFrom then
		--		return true, Constants.AcquireState.RELEASED
		--	end
		--end
		local now = DateTime.now().UnixTimestampMillis
		AcquireSentAt = now
		AcquireSentTo = MSStoredLock.Session
		AcknowledgedReceivedFrom = ""
		ReleasedReceivedFrom = ""
		local message:Types.InterVaultMessage = {Session=SessionId, SentAt=now, Reason=Constants.InterVaultMessageReason.ACQUIRE, JobID=game.JobId}
		local success = pcall(MessagingService.PublishAsync, MessagingService, "_DVMS"..AcquireSentTo, message)
		if not success then
			return false, nil
		end
		local state = Constants.AcquireState.UNKNOWN
		for i = 1, Constants.MessagingExpectedDelay + 1 do
			if not #ActiveReaders then
				return false, nil
			end
			task.wait(1)
			if ReleasedReceivedFrom and ReleasedReceivedFrom == AcquireSentTo then
				return true, Constants.AcquireState.RELEASED
			elseif AcknowledgedReceivedFrom and AcknowledgedReceivedFrom == AcquireSentTo then
				state = Constants.AcquireState.ACKNOWLEDGED
			end
		end
		return true, state
	end


	local function ReviveAsync()


		-- While another thread is altering messaging service, wait
		while MessagingChanging do
			MessagingUsableState.ChangeSignal:Wait()
		end
		MessagingChanging = true
		local attempt = 0
		-- If messaging is unusable, and the vault has readers, try making it usable
		while not MessagingUsableState.Current and #ActiveReaders do
			local success, result = pcall(MessagingService.SubscribeAsync, MessagingService, "_DVMS"..SessionId,
				function(Message: {Data:Types.InterVaultMessage, Sent:number})
					-- TODO: Messaging logic
				end)
			if success then
				MessagingChannel = result
				MessagingUsableState:Update(true)
				break
			end
			warn("[Retrying 2] Attempt:", attempt, "MessagingService.SubscribeAsync", result)
			task.wait(2)
		end
		MessagingChanging = false


		-- While another thread is altering lock acquiring, wait
		while LockAcquireChanging do
			LockAcquireState.ChangeSignal:Wait()
		end
		LockAcquireChanging = true
		attempt = 0
		-- If lock is unacquired, and the vault has readers, try acquiring it
		while not LockAcquireState.Current and #ActiveReaders do
			local success, owned, lockState: Types.LockState? = LockConsensusL1Async()
			if not success then
				warn("[Retrying 2] Attempt:", attempt, "MemoryStore.GetAsync failed", lockState)
				task.wait(2)
				continue
			end
			if lockState == Constants.LockState.NONEXISTANT then
				-- TODO: steal

			else
				local success, acquired: Types.AcquireStatus? = LockConsensusL2Async()
				if not success then
					warn("[Retrying 2] MessagingService.PublishAsync failed", acquired)
					task.wait(2)
					continue
				end

				if lockState == Constants.LockState.STALE then
					if AcquireSentAt - ResponseReceivedAt >= Constants.MessagingExpectedDelay * 3 then
						-- TODO: server dead, steal
					end
				end
			end
			task.wait(4)
		end
		LockAcquireChanging = false
	end


	local function StasisAsync()
		-- TODO: Stop updating lock and only keep update loop and messaging
		-- TODO: Auto cleanup after MemoryStoreExpiryPeriod if vault stayed idle
	end


	local function CleanupAsync()
		-- TODO: Cleanup any remaining functions and false-fire all signals to get rid of all yielded threads
		-- TODO: Leave in a state that this vault becomes invisible
	end


	function vault:Prepare()
		local rid = NextReaderId
		NextReaderId += 1
		table.insert(ActiveReaders, rid)
		Threads.Defer(ReviveAsync)
		-- Return a release function unique to the caller that can be called once and any further calls are ignored
		return function ()
			-- Check if the reader is still active (to prevent double-release bug)
			local index = table.find(ActiveReaders, rid)
			if not index then return end
			-- If yes, remove the reader
			table.remove(ActiveReaders, index)
			-- No readers remain, set the vault to stasis mode
			if not #ActiveReaders then
				if ServerShuttingDown then CleanupAsync()
				else StasisAsync()
				end
			end
		end
	end


	Threads.Defer(ReviveAsync)
	return vault
end