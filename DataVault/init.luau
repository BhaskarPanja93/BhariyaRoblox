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
	local UsableState = State(false)
	local PublicData: DataT = DeepClone(template)
	local ActivityData: Types.ActivityData =
		{
			FirstLogIn = now,
			LastLogIn = now,
			LastLogOut = now,
			LastSave = now
		}
	local ReaderId = 0
	local ActiveReaders: {number} = {}
	local HasUnsavedChanges= true
	local DataUpdateSignal:Signal.Signal<any, ...any> = Signal()
	local SessionId = HttpService:GenerateGUID(false)
	local MessagingChanging = false
	local MessagingUsableState = State(false)
	local MessagingChannel: RBXScriptConnection
	local LockAcquireChanging = false
	local LockAcquireState = State(false)
	local MSLockState: Types.LockState
	local DSLockState: Types.LockState


	vault.Name = vaultName
	vault.Usable = UsableState
	vault.DataUpdateSignal = DataUpdateSignal
	vault.SessionId = SessionId


	-- The function to return activity data
	vault.GetActivityData = function (self: Types.Vault<DataT>)
		return ActivityData
	end


	-- The function to return public data
	vault.GetPublicData = function (self: Types.Vault<DataT>)
		return PublicData
	end


	-- The function to update any field in the data
	-- This also signals all update listeners about the change
	vault.UpdateData = function (value: any, ...)
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
		DataUpdateSignal:Fire(value, ...)
	end


	vault.PrepareAsync = function (self: Types.Vault<DataT>)


		-- TODO: PREPARE/REVIVE LOGIC


		-- While another thread is altering messaging service, wait
		while MessagingChanging do
			MessagingUsableState.ChangeSignal:Wait()
		end
		MessagingChanging = true


		-- If messaging is unusable, and the profile has readers, try making it usable
		while not MessagingUsableState.Current and #ActiveReaders do
			local success, result = pcall(MessagingService.SubscribeAsync, MessagingService, "_DVMS"..SessionId,
				function(Message: {Data:Types.InterDSMessages, Sent:number})
					-- TODO: Messaging logic
				end)
			if success then
				MessagingChannel = result
				MessagingUsableState:Update(true)
				break
			end
			task.wait(2)
			warn("[Retrying 2] subscribe failed", result)
		end


		-- While another thread is altering lock acquiring, wait
		while LockAcquireChanging do
			LockAcquireState.ChangeSignal:Wait()
		end
		LockAcquireChanging = true


		-- If lock is unacquired, and the profile has readers, try acquiring it
		while not LockAcquireState.Current and #ActiveReaders do
			local success, lock:Types.LockData? = pcall(dsh.LockMemoryStore.GetAsync, dsh.LockMemoryStore, "_DVL/"..vaultName)
			if not success then
				warn("[Retrying 2] MemoryStore.GetAsync failed", lock)
				task.wait(2)
				continue
			end
			now = DateTime.now().UnixTimestampMillis
			if lock == nil then -- MS NonExistent, Try L3 directly
				MSLockState = Constants.LockState.NONEXISTANT
				success, lock = pcall(dsh.LockDataStore.GetAsync, dsh.LockDataStore, "_DVL/"..vaultName, nil)
				if not success then
					warn("[Retrying 5] DataStore.GetAsync failed", lock)
					task.wait(5)
					continue
				end
				now = DateTime.now().UnixTimestampMillis -- DS Expired, Steal
				if lock == nil then
					DSLockState = Constants.LockState.NONEXISTANT

				elseif lock.LockedAt + Constants.DSLockStaleDelay < now then
					DSLockState = Constants.LockState.STALE

				else
					DSLockState = Constants.LockState.FRESH

				end
			elseif lock.LockedAt + Constants.MSLockStaleDelay < now then -- MS Expired, Try L2
				MSLockState = Constants.LockState.STALE

			else -- MS Fresh, Try L2
				MSLockState = Constants.LockState.FRESH

			end
		end


		local rid = ReaderId
		ReaderId += 1
		table.insert(ActiveReaders, rid)


		-- Return a release function unique to the caller that can be called once and any further calls are ignored
		return function ()
			-- Check if the reader is still active (to prevent double-release bug)
			local index = table.find(ActiveReaders, rid)
			if not index then return end
			-- If yes, remove the reader
			table.remove(ActiveReaders, index)
			-- No readers remain, set the profile to stasis mode
			if not #ActiveReaders then
			-- TODO: STASIS/RELEASE LOGIC
			end
		end
	end


	return vault
end