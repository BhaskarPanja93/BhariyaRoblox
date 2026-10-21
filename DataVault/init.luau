--!strict
--!native
--!optimize 2

--[[
DataVault v0.1.0

TODO: CHECK when requirement flags are changed, it shouldn't change aggressively and should depend on other factors like lock acquired
TODO: Everytime there is a wait, reevaluate requirement of that function and revert if necessary
TODO: Vault state and other flag updates
]]


local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")


local FetchVaultsHolder = require(script:WaitForChild('VaultsHolder'))
local Signal = require(script.Parent:WaitForChild('Signal'))
local State = require(script.Parent:WaitForChild('State'))
local Thread = require(script.Parent:WaitForChild('Thread'))
local Types = require(script:WaitForChild('Types'))
local Utils = require(script:WaitForChild('Utils'))
local Constants = require(script:WaitForChild("Constants"))


local Vault = {} :: Types.Vault
Vault.__index = Vault


local ServerShuttingDown = false
local MemoryStoreWorking = State(true)
local DataStoreWorking = State(true)


-- Call OpenVaultAsync to make the vault usable
return function<DataT>(dsName: string, vaultName: string, template: DataT): Types.Vault<DataT>


	local now = DateTime.now().UnixTimestampMillis


	-- Fetch VaultsHolder
	local vaultHolder = FetchVaultsHolder(dsName)


	-- If vault already in server, return it blindly
	local vault: Types.Vault<DataT> = vaultHolder.Vaults[vaultName]
	if vault then
		return vault
	end


	-- Else create a new vault
	vault = {} :: Types.Vault<DataT>
	vaultHolder.Vaults[vaultName] = vault


	-- Vault parameters scoped to the function
	local SessionId = HttpService:GenerateGUID(false) -- Unique ID to find and track the vault session (will be used by other servers to talk to current server)
	local VaultUsable = State(false) -- Vault starts with being unusable
	local VaultState = State(Constants.VaultState.CREATED) -- Initial state of the vault is CREATED
	local LockData: Types.LockData = {JobId=game.JobId, Session=SessionId, LockedAt=0} -- Dummy lock value
	local PublicData: DataT = Utils.DeepClone(template) -- use template as the default data for the vault
	local ActivityData: Types.ActivityData = -- Activity data is partially metadata that stores user's first and last activity
		{
			FirstLogIn = now,
			LastLogIn = now,
			LastLogOut = now,
			LastSave = now
		}
	local DSData: Types.DataStoreData = {__PUBLIC=PublicData, __ACTIVITY=ActivityData} -- Final data to be saved into datastore
	local NextReaderId = 0 -- Each reader gets its own ID
	local ActiveReaders: {number} = {} -- ALl the active readers
	local HasUnsavedChanges= false -- Profile started with default template data, so it needs to be saved
	local DataUpdatedSignal:Signal.Signal<any, ...any> = Signal() -- Fired when any data field changes
	local VaultPrivateStateChanging = State(false) -- Sets when vault is ongoing cleanup or stasis convertion or reviving
	local VaultPrivateState: "REVIVE"|"STASIS"|"CLEANUP" = "REVIVE" -- Saves vault's private state (1: Revive, 0: Stasis, -1: Cleanup)

	local AcquireSentAt = 0 -- Saves when acquire was sent to other server
	local AcquireSentTo = "" -- Saves the server session id who receives acquire
	local AcknowledgedReceivedAt = 0 -- Saves when acknowledge response was received
	local ReleasedReceivedAt = 0 -- Saves when release response was received

	local AcquireReceivedFrom = "" -- Saves the session who last sent acquire

	local MessagingUsable = false -- Stores state of messaging service for the vault
	local MessagingChannel: RBXScriptConnection? -- Channel to be used for messaging
	local MessagingChangeOngoing = State(false) -- Sets when messaging channel change in progress else resets

	local LockAcquired = false -- Sets when lock is confirmed to be owned by self
	local LockAcquireThread: thread? -- Thread waiting for acquire response
	local LockRenewLoopRequired = true -- Saves if MemoryStore lock renew is required at any stage
	local LockRenewLoopActive = false -- Saves if MemoryStore lock renew loop is active
	local LockChangeOngoing = State(false) -- Sets when lock change or upgrade in progress else resets

	local InitialDataRead = false -- Stores if data has been read
	local DSSaveLoopRequired = true -- Saves if DataStore saving loop is required at any stage
	local DSSaveLoopActive = true -- Saves if DataStore save loop is active
	local DataChangeOngoing = State(false) -- Sets when change in progress else resets

	local StasisAt = 0 -- Saves when the vault went to stasis mode
	local LastDSSavedAt = 0 -- Saves when vault last saved to DataStore
	local LastDataChangedAt = 0 -- Saves when vault data was last modified
	local LastLockRenewedAt = 0 -- Saves when lock was last updated in MemoryStore


	vault.Name = vaultName
	vault.Usable = VaultUsable
	vault.DataUpdatedSignal = DataUpdatedSignal
	vault.SessionId = SessionId
	vault.ActivityData = ActivityData
	vault.PublicData = PublicData
	vault.Locals = {}


	-- OK
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


	-- OK
	-- Release the lock or upgrade it to the newest acquirer
	local function UpgradeOrReleaseLockAsync()
	-- While another thread is modifying lock, wait
		while LockChangeOngoing.Current do LockChangeOngoing.ChangeSignal:Wait() end
		-- Prevent other threads from modifying lock
		LockChangeOngoing:Update(true)
		-- Execute as pcall to prevent errors
		local success = pcall(vaultHolder.LockMemoryStore.UpdateAsync, vaultHolder.LockMemoryStore, vaultName,
			function(current: Types.LockData?): Types.LockData?
				local now = DateTime.now().UnixTimestampMillis
				if current and current.Session == SessionId then
				-- For same session id, update with new lock with the acquirer's session id
					LockData.LockedAt = now
					LockData.Session = AcquireReceivedFrom
					return LockData
				else
				-- For changed session id, mark lock as released, discard any unsaved changes and cleanup the vault
					HasUnsavedChanges = false
					LockAcquired = false
					return nil
				end
			end, Constants.MemoryStoreLockExpiryDelay)
		-- Notify MemoryStore activity
		MemoryStoreWorking:Update(success)
		if success then
			local message: Types.InterVaultMessage = {Session=SessionId, SentAt=now, Reason=Constants.InterVaultMessageReason.RELEASED, JobID=game.JobId}
			pcall(MessagingService.PublishAsync, MessagingService, "_DVM"..LockData.Session, message)
			-- Unlock lock modifications
			LockChangeOngoing:Update(false)
		else
		-- Let other threads modify lock
			LockChangeOngoing:Update(false)
			-- If failed and last updated is longer than memory store limit, close the vault
			UpgradeOrReleaseLockAsync()
			return
		end
	end


	-- OK
	-- Save data into datastore only if it has unsaved changes and ios old enough to be saved
	local function SaveDataAsync(forceSave: boolean)
	-- While another thread is modifying the state of the data, wait
		while DataChangeOngoing.Current do
			DataChangeOngoing.ChangeSignal:Wait()
		end
		-- Prevent other thread from modifying data
		DataChangeOngoing:Update(true)
		-- If no unsaved changes after waiting, or last change was too recent and last save isn't too old, skip. But forceSave skips the time based skipping
		if not HasUnsavedChanges or ((now - LastDataChangedAt < 5000 and now - LastDSSavedAt < Constants.DSSaveLoopDelay) and not forceSave) then return end
		-- Count attempts for logging failure rates
		local attempt = 1
		-- Continue till there are changes yet to be saved
		while HasUnsavedChanges do
			local now = DateTime.now().UnixTimestampMillis
			HasUnsavedChanges = false
			-- TODO: BUG POSSIBLE: update takes X time and data was updated in that X time, will newest data be saved or old one, plus HasUnsavedChanges might not flag correctly
			local success, result = pcall(vaultHolder.VaultDataStore.SetAsync, vaultHolder.VaultDataStore, vaultName, DSData)
			DataStoreWorking:Update(success)
			if not success then
			-- If failed, retry after a delay
				HasUnsavedChanges = true
				warn("[Retrying 5] Attempt:", attempt, "DataStore.GetAsync", result)
				attempt += 1
				task.wait(5)
				continue
			end
			LastDSSavedAt = now
			-- Allow other threads to take over now
			DataChangeOngoing:Update(false)
		end
	end


	-- OK
	-- Closes Messaging for the vault (skips if it is already disconnected or never created)
	local function CloseMessaging()
	-- While another thread is modifying the state of the messaging, wait
		while MessagingChangeOngoing.Current do
			MessagingChangeOngoing.ChangeSignal:Wait()
		end
		-- Prevent other thread from modifying messaging
		MessagingChangeOngoing:Update(true)
		-- If Messaging channel exists and is not required, disconnect it
		if VaultPrivateState ~= "REVIVE" and MessagingChannel then
			MessagingChannel:Disconnect()
			MessagingChannel = nil
			MessagingUsable = false
		end
		-- Release the lock for messaging change
		MessagingChangeOngoing:Update(false)
	end


	-- OK
	-- Cleanup the vault from memory, leaving it totally unusable
	local function CleanupAsync()
		VaultPrivateState = "CLEANUP"
		-- De-reference the vault instantly so future vault queries return a new vault
		vaultHolder.Vaults[vaultName] = nil
		VaultUsable:Update(false)
		-- Reset all requirements
		DSSaveLoopRequired = false
		LockRenewLoopRequired = false
		-- Save oen final time
		if HasUnsavedChanges then SaveDataAsync(true) end
		-- Release the lock safely (upgrade if required)
		if LockAcquired then UpgradeOrReleaseLockAsync() end
		-- Close messaging channel
		if MessagingUsable then CloseMessaging() end
		-- Set new state for the vault
		VaultState:Update(Constants.VaultState.RELEASED)
		-- Send forget to the server who sent acquire
		-- Cleanup if lock acquire was still waiting
		local thread = LockAcquireThread
		LockAcquireThread = nil
		if thread and coroutine.status(thread) == "suspended" then
			task.spawn(thread, false)
		end
	end


	-- OK
	-- Performs operations based on messages received from another session or server
	local function MessagingLogic(Message: {Data:Types.InterVaultMessage, Sent:number})
		if Message.Data.Reason == Constants.InterVaultMessageReason.ACQUIRE then
			AcquireReceivedFrom = Message.Data.Session
			if VaultPrivateState == "STASIS" then
				CleanupAsync()
			end
		elseif Message.Data.Reason == Constants.InterVaultMessageReason.FORGET then
			AcquireReceivedFrom = ""
		elseif Message.Data.Reason == Constants.InterVaultMessageReason.OK then
			if AcquireSentTo ~= Message.Data.Session then return end
			AcknowledgedReceivedAt = Message.Data.SentAt
		elseif Message.Data.Reason == Constants.InterVaultMessageReason.UPDATE then

		elseif Message.Data.Reason == Constants.InterVaultMessageReason.RELEASED then
			if AcquireSentTo ~= Message.Data.Session then return end
			ReleasedReceivedAt = Message.Data.SentAt
			local thread = LockAcquireThread
			LockAcquireThread = nil
			if thread and coroutine.status(thread) == "suspended" then
				task.spawn(thread, false)
			end
		end
	end


	-- OK
	-- Starts preparation of Messaging service for the vault (skips if it is already prepared)
	local function PrepareMessagingAsync()
		-- While another thread is modifying the state of the messaging, wait
		while MessagingChangeOngoing.Current do
			MessagingChangeOngoing.ChangeSignal:Wait()
		end
		-- Prevent other thread from modifying messaging
		MessagingChangeOngoing:Update(true)
		-- Update the vault state
		VaultState:Update(Constants.VaultState.MESSAGEPREPARING)
		-- Count attempts for logging failure rates
		local attempt = 1
		-- While messaging is unusable and required, try making it usable
		while VaultPrivateState == "REVIVE" and not MessagingUsable do
			-- Try subscribing to the session
			local success, result = pcall(MessagingService.SubscribeAsync, MessagingService, "_DVM"..SessionId, MessagingLogic)
			-- If subscribe failed, retry after a delay
			if not success then
				warn("[Retrying 2] Attempt:", attempt, "MessagingService.SubscribeAsync", result)
				attempt += 1
				task.wait(2)
				continue
			end
			-- Save the result as the messaging channel
			MessagingChannel = result
			-- Define messaging as usable
			MessagingUsable = true
			break
		end
		-- Release the lock for messaging change
		MessagingChangeOngoing:Update(false)
	end


	local function AcquireLockAsync()
		-- While another thread is modifying the state of the lock, wait
		while LockChangeOngoing.Current do
			LockChangeOngoing.ChangeSignal:Wait()
		end
		-- Prevent other thread from modifying lock
		LockChangeOngoing:Update(true)
		-- Update the vault state
		VaultState:Update(Constants.VaultState.LOCKING)
		-- Count attempts for logging failure rates
		local attempt = 1
		-- If lock is unacquired, and it is required, try to acquire it
		while VaultPrivateState == "REVIVE" and not LockAcquired do
			local retryRequired = false
			local success, result = pcall(vaultHolder.LockMemoryStore.UpdateAsync, vaultHolder.LockMemoryStore, vaultName,
				function(current: Types.LockData?): Types.LockData?
					local now = DateTime.now().UnixTimestampMillis
					if current == nil or not current.Session then
						-- Lock non-existent, instantly acquire it
						LockData.LockedAt = now
						return LockData
					elseif current.JobId == game.JobId and current.Session == SessionId then
						-- Current session owns it
						if current.LockedAt + Constants.MSLockStaleDelay < now then
							-- Lock is stale, renew it
							LockData.LockedAt = now
							return LockData
						end
						LockData = current
						-- Ignore if its current session and is fresh
						return nil
					else
						-- Owned by another server
						retryRequired = true
						local lastResponseAt = math.max(AcknowledgedReceivedAt, ReleasedReceivedAt)
						if now - current.LockedAt > Constants.MSLockStaleDelay and AcquireSentAt - lastResponseAt >= Constants.MessagingExpectedDelay * 5 then
							-- Lock is stale, and did not receive any response for 5 acquires, assume server dead, Steal it
							LockData.LockedAt = now
							return LockData
						end
						if not AcquireSentAt or AcquireSentAt > lastResponseAt or now - lastResponseAt > Constants.MessagingExpectedDelay then
							-- Acquire was never sent
							-- or Response is older than recent acquire
							-- or Response is older than Expected delay
							if not AcquireSentTo then
								AcknowledgedReceivedAt = now - 3
								ReleasedReceivedAt = now - 3
							end
							-- Send the acquire message
							local message: Types.InterVaultMessage = {Session=SessionId, SentAt=now, Reason=Constants.InterVaultMessageReason.ACQUIRE, JobID=game.JobId}
							local success, result = pcall(MessagingService.PublishAsync, MessagingService, "_DVM"..current.Session, message)
							if not success then
								-- Acquire sent failed
								warn("[Retrying 4]", "MessagingService.PublishAsync failed", result)
							else
								-- Acquire sent
								AcquireSentAt = now
								AcquireSentTo = current.Session
							end
						end
						return nil
					end
				end, Constants.MemoryStoreLockExpiryDelay)
			if not success then
				-- Update Failed
				warn("[Retrying 2] Attempt:", attempt, "MemoryStore.UpdateAsync failed", result)
				attempt += 1
				task.wait(2)
				continue
			end
			MemoryStoreWorking:Update(success)
			if retryRequired then
				-- Needs to retry (acquire process)
				if AcquireSentTo and AcquireSentAt then
					-- If acquire sent was successful, save the thread and yield till response is received
					LockAcquireThread = coroutine.running()
					-- On another thread resume the thread if not resumed by response
					Thread.Delay(Constants.MessagingExpectedDelay + 2, function(...)
						local thread = LockAcquireThread
						LockAcquireThread = nil
						if thread and coroutine.status(thread) == "suspended" then
							task.spawn(thread, false)
						end
					end)
					-- Pause execution and on resume check if resumed by response or manual
					if coroutine.yield() then
						-- Break out of loop if resumed by response
						LockAcquired = true
						break
					else
						-- Retry the loop if resumed manually
						continue
					end
				end
				-- Any other case, retry after a delay
				task.wait(4)
				continue
			else
				LastLockRenewedAt = LockData.LockedAt
				LockAcquired = true
				break
			end
		end
		LockChangeOngoing:Update(false)
	end


	-- OK
	-- Read initial data from datastore
	local function ReadDataAsync()
		-- While another thread is modifying the state of the data, wait
		while DataChangeOngoing.Current do
			DataChangeOngoing.ChangeSignal:Wait()
		end
		-- Prevent other thread from modifying data
		DataChangeOngoing:Update(true)
		-- Update the vault state
		VaultState:Update(Constants.VaultState.READING)
		-- Count attempts for logging failure rates
		local attempt = 1
		-- Keep trying till vault is in revive state and initial data is not read
		while VaultPrivateState == "REVIVE" and not InitialDataRead do
			-- Try reading data from DataStore
			local success, result:Types.DataStoreData? = pcall(vaultHolder.VaultDataStore.GetAsync, vaultHolder.VaultDataStore, vaultName, nil)
			DataStoreWorking:Update(success)
			-- If read failed, retry after some time
			if not success then
				warn("[Retrying 5] Attempt:", attempt, "DataStore.GetAsync", result)
				attempt += 1
				task.wait(5)
				continue
			end
			-- Store the result as the data
			if result then
				-- If data existed, use it
				DSData = result
				HasUnsavedChanges = false
			else
				-- If no data exist in datastore, use the default data and flag for a save
				HasUnsavedChanges = true
			end
			-- Define data as read
			InitialDataRead = true
			break
		end
	end


	-- TODO: Needs further optimization for AFK vaults (loop runs even for AFK vault)
	-- OK
	-- Upon data read, keep it saved every fixed amount of time
	local function DSSaveLoop()
		-- If there exist another loop, don't start a new loop
		if DSSaveLoopActive or not DSSaveLoopRequired then return end
		DSSaveLoopActive = true
		-- While ds save loop is required, keep running with delay
		while DSSaveLoopRequired do
			local now = DateTime.now().UnixTimestampMillis
			-- If no unsaved changes, wait entire period
			if not HasUnsavedChanges then task.wait(Constants.DSSaveLoopDelay); continue end
			-- Recent change was within last 5 seconds and last save was within last DSSaveLoopDelay (60 seconds), wait a small period and attempt save
			if now - LastDataChangedAt < 5000 and now - LastDSSavedAt < Constants.DSSaveLoopDelay then task.wait(5); continue end
			-- Regular save
			SaveDataAsync(false)
		end
		-- Allow other threads to start loop now
		DSSaveLoopActive = false
	end


	-- OK
	-- Set the vault in a semi-released mode where the vault is in the hands of the current server but lock is not renewed nor is data saved
	-- Only use for this mode is to prevent re-reviving a new vault and resume operation on this one
	local function StasisAsync()
		VaultPrivateState = "STASIS"
		local now = DateTime.now().UnixTimestampMillis
		StasisAt = now
		-- Reset requirement flags
		DSSaveLoopRequired = false
		LockRenewLoopRequired = false
		-- Wait while another instance of Revive, Stasis or Cleanup is ongoing
		while VaultPrivateStateChanging.Current do DataChangeOngoing.ChangeSignal:Wait() end
		-- If received new readers while waiting, quit
		if VaultPrivateState ~= "STASIS" then return end
		-- Prevent another instance of Revive, Stasis or Cleanup
		VaultPrivateStateChanging:Update(true)
		-- If lock was not acquired even after waiting, directly cleanup without any wait
		if not LockAcquired then
			CleanupAsync()
			return
		end
		if AcquireReceivedFrom then
			-- If another server is waiting for the vault to close, upgrade the lock and cleanup
			CleanupAsync()
		else
			-- Save before going stasis
			if InitialDataRead then SaveDataAsync(true) end
			-- Add a new delayed thread that waits for a specific time and then cleans up the vault automatically if it has been sitting idle all that time
			Thread.Delay((Constants.MemoryStoreLockExpiryDelay - Constants.MSLockRenewalDelay) / 1000, function()
				if VaultPrivateState == "STASIS" and now == StasisAt then CleanupAsync() end
			end)
			VaultState:Update(Constants.VaultState.STASIS)
		end
	end


	-- OK
	-- Renew lock only when it gets closer to stale
	local function RenewLockAsync()
		-- While another thread is modifying lock, wait
		while LockChangeOngoing.Current do LockChangeOngoing.ChangeSignal:Wait() end
		-- Prevent other threads from modifying lock
		LockChangeOngoing:Update(true)
		-- If renew was called too early, return and do nothing
		if Constants.MSLockRenewalDelay - 1000 >= (DateTime.now().UnixTimestampMillis - LastLockRenewedAt) then return end
		-- Execute as pcall to prevent errors breaking the loop
		local success = pcall(vaultHolder.LockMemoryStore.UpdateAsync, vaultHolder.LockMemoryStore, vaultName,
			function(current: Types.LockData?): Types.LockData?
				local now = DateTime.now().UnixTimestampMillis
				if current and current.Session == SessionId then
					-- For same session id, update with new lock
					LockData.LockedAt = now
					return LockData
				else
					-- For changed session id, mark lock as released, discard any unsaved changes and cleanup the vault
					HasUnsavedChanges = false
					LockAcquired = false
					CleanupAsync()
					return nil
				end
			end, Constants.MemoryStoreLockExpiryDelay)
		-- Notify MemoryStore activity
		MemoryStoreWorking:Update(success)
		if not success then
			-- Let other threads modify lock
			LockChangeOngoing:Update(false)
			-- If failed and last updated is longer than memory store limit, close the vault
			if DateTime.now().UnixTimestampMillis - LastLockRenewedAt > Constants.MemoryStoreLockExpiryDelay then CleanupAsync() end
			return
		end
		-- If lock saved successfully, update the last updated time
		LastLockRenewedAt = LockData.LockedAt
		-- Unlock lock modifications
		LockChangeOngoing:Update(false)
	end


	-- OK
	-- Upon lock acquire, keep it updated every fixed amount of time
	local function LockRenewLoop()
		-- If there exist another loop, don't start a new loop
		if LockRenewLoopActive then return end
		LockRenewLoopActive = true
		-- While lock renew loop is required, keep renewing with delay
		while LockRenewLoopRequired do
			task.wait(math.max(0, (Constants.MSLockRenewalDelay - (DateTime.now().UnixTimestampMillis - LastLockRenewedAt))/1000))
			RenewLockAsync()
		end
		-- Allow other threads to start loop now
		LockRenewLoopActive = false
	end


	-- OK
	-- Revive rebuilds missing or broken parts of the vault and make it new ready for use
	-- It is async and so changes while this function is being executed can change or halt the process or reviving
	local function ReviveAsync()
		VaultPrivateState = "REVIVE"
		-- Set all requirement flags
		DSSaveLoopRequired = true
		LockRenewLoopRequired = true
		-- Wait while another instance of Revive, Stasis or Cleanup is ongoing
		while VaultPrivateStateChanging.Current do DataChangeOngoing.ChangeSignal:Wait() end
		-- If stasis or cleanup was called while waiting, quit
		if VaultPrivateState ~= "REVIVE" then return end
		-- Prevent another instance of Revive, Stasis or Cleanup
		VaultPrivateStateChanging:Update(true)
		-- Blocking Setup Messaging until it is required and not set up
		if VaultPrivateState == "REVIVE" and not MessagingUsable then PrepareMessagingAsync() end
		-- If vault was called for stasis or cleanup by the time messaging was prepared, close and let it take over
		if VaultPrivateState ~= "REVIVE" then
			VaultPrivateStateChanging:Update(false)
			return
		end
		-- Blocking Lock acquire until it is required and not acquired
		if VaultPrivateState == "REVIVE" and not LockAcquired then AcquireLockAsync() end
		-- If lock is not acquired yet and vault was called for stasis or cleanup, close and let it take over
		if VaultPrivateState ~= "REVIVE" and not LockAcquired then
			VaultPrivateStateChanging:Update(false)
			return
		end
		-- Start the lock renew loop
		Thread.Defer(LockRenewLoop)
		-- If another server requested acquire, close and let cleanup take over
		if AcquireReceivedFrom then
			VaultPrivateStateChanging:Update(false)
			return
		end
		-- If data is not present, read the data
		if not InitialDataRead then ReadDataAsync() end
		Thread.Defer(DSSaveLoop)
		VaultPrivateStateChanging:Update(false)
		VaultUsable:Update(true)
	end


	-- OK
	-- Initiate all vault services if not started already, the caller will be called a unique reader
	-- Return a unique function to mark release, if no other readers are active, the vault will switch to stasis mode or be cleaned up
	-- This function call is compulsory in order to prevent a vault from getting released automatically (in scenarios like trading where keeping the vault open till trade succeeds)
	-- Similarly, calling the release function is compulsory to let the profile release freely
	function vault:Prepare()
		-- Infinitely scale count to serve individual reader
		local rid = NextReaderId
		NextReaderId += 1
		table.insert(ActiveReaders, rid)
		-- Revive the vault
		Thread.Defer(ReviveAsync)
		-- Return a release function unique to the caller that can be called once and any further calls are ignored
		return function ()
			-- Check if the reader is still active (to prevent double-release)
			local index = table.find(ActiveReaders, rid)
			-- Skip if already called (reader absent)
			if not index then return end
			-- If yes, remove the reader
			table.remove(ActiveReaders, index)
			-- No readers remain, set the vault to stasis mode or cleanup if server is already shutting down
			if not #ActiveReaders then
				-- If server is shutting down then directly cleanup else move to stasis mode
				if ServerShuttingDown then CleanupAsync()
				else StasisAsync()
				end
			end
		end
	end


	return vault
end