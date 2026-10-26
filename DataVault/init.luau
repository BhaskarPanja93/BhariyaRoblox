--!strict
--!native
--!optimize 2

--[[
DataVault v0.2.0

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


local ServerShuttingDown = State(false)
local MemoryStoreWorking = State(true)
local DataStoreWorking = State(true)


game:BindToClose(function()
	ServerShuttingDown:Update(true)
end)


local function GetVault<DataT>(dsName: string, vaultName: string, template: DataT): Types.Vault<DataT>


	local now = DateTime.now().UnixTimestampMillis


	-- Fetch VaultsHolder
	local vaultHolder = FetchVaultsHolder(dsName)


	-- If vault already in server, return it blindly
	local vault: Types.Vault<DataT> = vaultHolder.Vaults[vaultName]
	if vault then return vault end


	-- Else create a new vault
	vault = {} :: Types.Vault<DataT>
	vaultHolder.Vaults[vaultName] = vault


	-- Vault parameters scoped to the function
	local SessionId = HttpService:GenerateGUID(false) -- Unique ID to find and track the vault session (will be used by other servers to talk to current server)
	local VaultUsable = State(false) -- Vault starts with being unusable
	local VaultState = State(Constants.VaultState.CREATED) -- Initial state of the vault is CREATED
	local LockData: Types.LockData = {JobId=game.JobId, Session=SessionId, LockedAt=0} -- Dummy lock value
	local DSData: Types.DataStoreData = {
		__PUBLIC=Utils.DeepClone(template),
		__ACTIVITY={
			FirstLogIn = now,
			LastLogIn = now,
			LastLogOut = now,
			LastSave = now
		}
	} -- Dummy DS data
	local NextReaderId = 0 -- Each reader gets its own ID
	local ActiveReaders: {number} = {} -- ALl the active readers
	local HasUnsavedChanges= false -- Profile started with default template data, so it needs to be saved
	local DataUpdatedSignal:Signal.Signal<{string|number}, any> = Signal() -- Fired when any data field changes
	local VaultPrivateStateChanging = State(false) -- Sets when vault is ongoing cleanup or stasis convertion or reviving
	local VaultPrivateState: "REVIVE"|"STASIS"|"CLEANUP" = "REVIVE" -- Saves vault's private state

	local AcquireReceivedFrom = "" -- Saves the session who last sent acquire
	local AcquireSentAt = 0 -- Saves when acquire was sent to other server
	local AcquireSentTo = "" -- Saves the server session id who receives acquire
	local AcquireAcknowledgedReceivedAt = 0 -- Saves when acknowledge response was received
	local ReleasedReceivedAt = 0 -- Saves when release response was received

	local MessagingUsable = false -- Stores state of messaging service for the vault
	local MessagingChannel: RBXScriptConnection? -- Channel to be used for messaging
	local MessagingChangeOngoing = State(false) -- Sets when messaging channel change in progress else resets

	local LockAcquired = false -- Sets when lock is confirmed to be owned by self
	local LockAcquireThread: thread? -- Thread waiting for acquire response
	local LockChangeOngoing = State(false) -- Sets when lock change or upgrade in progress else resets
	local LockRenewLoopRequired = true -- Saves if MemoryStore lock renew is required at any stage
	local LockRenewLoopActive = false -- Saves if MemoryStore lock renew loop is active

	local InitialDataRead = false -- Stores if data has been read
	local DataChangeOngoing = State(false) -- Sets when change in progress else resets
	local DSSaveLoopRequired = true -- Saves if DataStore saving loop is required at any stage
	local DSSaveLoopActive = false -- Saves if DataStore save loop is active

	local StasisAt = 0 -- Saves when the vault went to stasis mode
	local LastDSSavedAt = 0 -- Saves when vault last saved to DataStore
	local LastDataChangedAt = 0 -- Saves when vault data was last modified
	local LastLockRenewedAt = 0 -- Saves when lock was last updated in MemoryStore


	vault.Name = vaultName
	vault.Usable = VaultUsable
	vault.DataUpdatedSignal = DataUpdatedSignal
	vault.SessionId = SessionId
	vault.Locals = {}


	function vault:GetPublicData()
		return DSData.__PUBLIC
	end


	function vault:GetActivityData()
		return DSData.__ACTIVITY
	end


	-- The function to update any field in the data
	-- This also signals all update listeners about the change
	function vault:UpdateData(keys, value)
		local pointer:{[string|number]:any} = DSData.__PUBLIC
		-- Iterate through the keys and update the current pointer
		for i, key in keys do
			if i == #keys then
				if value ~= pointer[key] then
					-- If values are not same, update
					pointer[key] = value
					-- Flag the vault as needs saving
					HasUnsavedChanges = true
				end
			else
				-- Create empty table if it doesn't exist
				pointer[key] = pointer[key] or {}
				-- Move the pointer to the next key
				pointer = pointer[key]
			end
		end
		-- Fire the signal for data update listeners
		DataUpdatedSignal:Fire(keys, value)
	end


	-- Release the lock or upgrade it to the newest acquirer
	local function UpgradeOrReleaseLockAsync()
		print("UpgradeOrReleaseLockAsync")
		-- While another thread is modifying lock, wait
		while LockChangeOngoing.Current do LockChangeOngoing.ChangeSignal:Wait() end
		-- If vault went back to revived state while waiting, ignore the release call
		if VaultPrivateState == "REVIVE" then return end
		-- Prevent other threads from modifying lock
		LockChangeOngoing:Update(true)
		local now = DateTime.now().UnixTimestampMillis
		print("Upgrading lock")
		-- Execute as pcall to prevent errors
		local success = pcall(vaultHolder.LockMemoryStore.UpdateAsync, vaultHolder.LockMemoryStore, vaultName,
			function(current: Types.LockData?): Types.LockData?
				now = DateTime.now().UnixTimestampMillis
				if current ~= nil and current.Session == SessionId then
					-- For same session id, update with new lock with the acquirer's session id
					LockData.LockedAt = now
					LockData.Session = AcquireReceivedFrom
					return LockData
				else
					-- For changed session id, mark lock as released, discard any unsaved changes and cleanup the vault
					print("Lock already stolen")
					HasUnsavedChanges = false
					LockAcquired = false
					return nil
				end
			end, Constants.MemoryStoreLockExpiryDelay / 1000)
		MemoryStoreWorking:Update(success)
		now = DateTime.now().UnixTimestampMillis
		if success then
			print("Released lock")
			if LockData.Session ~= "" then
				-- Send message to acquirer
				local message: Types.InterVaultMessage = {Session=SessionId, SentAt=now, Reason=Constants.InterVaultMessageReason.RELEASED}
				pcall(MessagingService.PublishAsync, MessagingService, "_DVM"..LockData.Session, message)
			end
			-- Unlock lock modifications
			LockChangeOngoing:Update(false)
		else
			-- Wait and retry
			warn("[Retrying 3]", "MemoryStore.UpdateAsync (upgrade or release lock)")
			task.wait(3)
			-- Unlock lock modifications
			LockChangeOngoing:Update(false)
			-- If failed and last updated is longer than memory store stale limit, close the vault
			if now - LastLockRenewedAt < Constants.MSLockStaleDelay then UpgradeOrReleaseLockAsync() end
		end
	end


	-- Save data into datastore with the option to force save which forcefully saves ignoring last updated and last saved values
	local function SaveDataAsync(forceSave: boolean)
		print("SaveDataAsync")
		-- While another thread is modifying the state of the data, wait
		while DataChangeOngoing.Current do DataChangeOngoing.ChangeSignal:Wait() end
		local now = DateTime.now().UnixTimestampMillis
		-- If no unsaved changes after waiting, or last change was too recent and last save isn't too old, skip. But forceSave skips the time based skipping
		if not InitialDataRead or not HasUnsavedChanges or ((not forceSave and now - LastDataChangedAt < 5000 and now - LastDSSavedAt < Constants.DSSaveLoopDelay)) then return end
		-- Prevent other thread from modifying data
		DataChangeOngoing:Update(true)
		print("Save started")
		-- Count attempts for logging failure rates
		local attempt = 1
		-- Continue till there are changes yet to be saved
		while HasUnsavedChanges and VaultState.Current ~= Constants.VaultState.RELEASED do
			now = DateTime.now().UnixTimestampMillis
			HasUnsavedChanges = false
			-- SetAsync clones the last value pf the DSData, so further modification while it is saving acts as new changes
			local success, result = pcall(vaultHolder.VaultDataStore.SetAsync, vaultHolder.VaultDataStore, vaultName, DSData)
			DataStoreWorking:Update(success)
			if not success then
				-- If failed, retry after a delay
				HasUnsavedChanges = true
				warn("[Retrying 5] Attempt:", attempt, "DataStore.SetAsync", result)
				attempt += 1
				task.wait(5)
				continue
			end
			LastDSSavedAt = now
			-- Allow other threads to take over now
			DataChangeOngoing:Update(false)
		end
	end


	-- Closes Messaging for the vault (skips if it is already disconnected or never created)
	local function CloseMessaging()
		print("CloseMessaging")
		-- While another thread is modifying the state of the messaging, wait
		while MessagingChangeOngoing.Current do MessagingChangeOngoing.ChangeSignal:Wait() end
		-- If vault went back to revived state while waiting, ignore the release call
		if VaultPrivateState == "REVIVE" then return end
		-- Prevent other thread from modifying messaging
		MessagingChangeOngoing:Update(true)
		print("Closing messaging")
		-- If Messaging channel exists and is not required, disconnect it
		if MessagingChannel ~= nil then
			MessagingChannel:Disconnect()
			MessagingChannel = nil
			MessagingUsable = false
		end
		-- Release the lock for messaging change
		MessagingChangeOngoing:Update(false)
	end


	-- Cleanup the vault from memory, leaving it totally unusable
	local function CleanupAsync()
		print("CleanupAsync")
		VaultPrivateState = "CLEANUP"
		-- Set new state for the vault
		VaultState:Update(Constants.VaultState.RELEASING)
		-- De-reference the vault instantly so future vault queries return a new vault
		vaultHolder.Vaults[vaultName] = nil
		VaultUsable:Update(false)
		-- Reset all requirements
		DSSaveLoopRequired = false
		LockRenewLoopRequired = false
		-- Wait while another instance of Revive, Stasis or Cleanup is ongoing
		-- NOTE: Do not add a check after wait in this case as post cleanup the vault should be unusable and not revertible
		while VaultPrivateStateChanging.Current do VaultPrivateStateChanging.ChangeSignal:Wait() end
		print("Cleaning up")
		-- Save one final time
		if InitialDataRead and HasUnsavedChanges then SaveDataAsync(true) end
		-- Release the lock safely (upgrade if required)
		if LockAcquired then UpgradeOrReleaseLockAsync() end
		-- Close messaging channel
		if MessagingUsable then CloseMessaging() end
		-- Set new state for the vault
		VaultState:Update(Constants.VaultState.RELEASED)
		-- Send forget to the server who received current session's acquire
		local message: Types.InterVaultMessage = {Session=SessionId, SentAt=now, Reason=Constants.InterVaultMessageReason.FORGET}
		pcall(MessagingService.PublishAsync, MessagingService, "_DVM"..LockData.Session, message)
		-- Cleanup if lock acquire was still waiting
		local thread = LockAcquireThread
		LockAcquireThread = nil
		if thread ~= nil and coroutine.status(thread) == "suspended" then
			task.spawn(thread, false)
		end
	end


	-- Performs operations based on messages received from another session or server
	local function MessagingLogic(Message: {Data:Types.InterVaultMessage, Sent:number})
		print("Message received", Message)
		if Message.Data.Reason == Constants.InterVaultMessageReason.ACQUIRE then
			-- Save the server session id to upgrade lock in the future
			AcquireReceivedFrom = Message.Data.Session
			-- If vault was already in stasis mode, upgrade directly
			if VaultPrivateState == "STASIS" then CleanupAsync() end
		elseif Message.Data.Reason == Constants.InterVaultMessageReason.FORGET then
			-- Remove the last known acquirer if the same server sent Forget
			if Message.Data.Session == AcquireReceivedFrom then AcquireReceivedFrom = "" end
		elseif Message.Data.Reason == Constants.InterVaultMessageReason.ACQUIRE_OK then
			-- Acknowledgement received for acquire
			if AcquireSentTo ~= Message.Data.Session then return end
			AcquireAcknowledgedReceivedAt = Message.Data.SentAt
		elseif Message.Data.Reason == Constants.InterVaultMessageReason.RELEASED then
			-- Other server released or upgraded the lock
			if AcquireSentTo ~= Message.Data.Session then return end
			ReleasedReceivedAt = Message.Data.SentAt
			-- Activate the lock acquire suspended thread
			local thread = LockAcquireThread
			LockAcquireThread = nil
			if thread ~= nil and coroutine.status(thread) == "suspended" then task.spawn(thread, true) end
		elseif Message.Data.Reason == Constants.InterVaultMessageReason.UPDATE then
			-- Collect the data received through messaging
			local RemoteUpdateData: Types.RemoteUpdateData = Message.Data.Extra
			-- Fetch the vault
			vault = GetVault(RemoteUpdateData.DS, RemoteUpdateData.Vault, template)
			-- If server doesn't hold the vault, reject the message
			if not vault.Usable.Current then return end
			-- Prepare the vault for the update action
			local release = vault:Prepare()
			-- Update the data (active vault data change listeners will get this signal fire)
			vault:UpdateData(RemoteUpdateData.Keys, RemoteUpdateData.Value)
			-- Send acknowledgement to sending server
			local message:Types.InterVaultMessage = {Reason=Constants.InterVaultMessageReason.UPDATE_OK, Extra=RemoteUpdateData.ID, SentAt=DateTime.now().UnixTimestampMillis, Session=SessionId}
			for i = 1, 3 do
				if pcall(MessagingService.PublishAsync, MessagingService, "_DVM"..Message.Data.Session, message) then break end
				task.wait(2)
			end
			-- Release the vault (let it go back to stasis or cleanup or run as usual with one less reader)
			release()
		end
	end


	-- Starts preparation of Messaging service for the vault (skips if it is already prepared)
	local function PrepareMessagingAsync()
		print("PrepareMessagingAsync")
		-- While another thread is modifying the state of the messaging, wait
		while MessagingChangeOngoing.Current do MessagingChangeOngoing.ChangeSignal:Wait() end
		-- If vault changed state while waiting, ignore the call
		if VaultPrivateState ~= "REVIVE" then return end
		-- Prevent other thread from modifying messaging
		MessagingChangeOngoing:Update(true)
		print("Messaging preparing")
		-- Update the vault state
		VaultState:Update(Constants.VaultState.MESSAGEPREPARING)
		-- Count attempts for logging failure rates
		local attempt = 1
		-- While messaging is unusable and required, try making it usable
		while VaultPrivateState == "REVIVE" and not MessagingUsable do
			-- Try subscribing to the session
			local success, result = pcall(MessagingService.SubscribeAsync, MessagingService, "_DVM"..SessionId, MessagingLogic)
			if not success then
				-- If subscribe failed, retry after a delay
				warn("[Retrying 2] Attempt:", attempt, "MessagingService.SubscribeAsync", result)
				attempt += 1
				task.wait(2)
				continue
			end
			print("Messaging prepared")
			-- Save the result as the messaging channel
			MessagingChannel = result
			-- Define messaging as usable
			MessagingUsable = true
			break
		end
		-- Release the lock for messaging change
		MessagingChangeOngoing:Update(false)
	end


	-- Acquire lock initially when the vault is created
	local function AcquireLockAsync()
		print("AcquireLockAsync")
		-- While another thread is modifying the state of the lock, wait
		while LockChangeOngoing.Current do LockChangeOngoing.ChangeSignal:Wait() end
		-- Prevent other thread from modifying lock
		LockChangeOngoing:Update(true)
		print("Acquiring lock")
		-- Update the vault state
		VaultState:Update(Constants.VaultState.LOCKING)
		-- Count attempts for logging failure rates
		local attempt = 1
		-- If lock is unacquired, and it is required, try to acquire it
		while VaultPrivateState == "REVIVE" and not LockAcquired do
			-- Remembers if a retry is required
			local retryRequired = false
			-- Call Update in pcall to prevent errors breaking the loop
			local success, result = pcall(vaultHolder.LockMemoryStore.UpdateAsync, vaultHolder.LockMemoryStore, vaultName,
				function(current: Types.LockData?): Types.LockData?
					local now = DateTime.now().UnixTimestampMillis
					if current == nil or current.Session == "" then
						-- Lock non-existent, instantly acquire it
						print("Non existent lock", current)
						LockData.LockedAt = now
						return LockData
					elseif current.JobId == game.JobId and current.Session == SessionId then
						-- Current session owns it
						print("Lock already owned")
						if current.LockedAt + Constants.MSLockStaleDelay < now then
							-- Lock is stale, renew it
							print("Renewing stale lock")
							LockData.LockedAt = now
							return LockData
						end
						-- Ignore if its current session and is fresh
						LockData = current
						return nil
					else
						-- Owned by another server
						print("Other server owns lock")
						retryRequired = true
						local lastResponseAt = math.max(AcquireAcknowledgedReceivedAt, ReleasedReceivedAt)
						if now - current.LockedAt > Constants.MSLockStaleDelay and AcquireSentAt - lastResponseAt >= Constants.MessagingExpectedDelay * 5 then
							-- Lock is stale, and did not receive any response for 5 acquires, assume server dead, Steal it
							print("Server didnt respond for last 35 seconds and lock is older than 101 seconds... Stealing lock")
							LockData.LockedAt = now
							return LockData
						end
						-- Acquire was never sent
						-- or Response is older than recent acquire
						-- or Response is older than Expected delay
						-- For sending acquire again
						if AcquireSentAt == 0 or AcquireSentAt > lastResponseAt or now - lastResponseAt > Constants.MessagingExpectedDelay then
							if AcquireSentTo == "" then
								AcquireAcknowledgedReceivedAt = now - 1
								ReleasedReceivedAt = now - 1
							end
							-- Send the acquire message
							print("Sending acquire:", current.Session)
							local message: Types.InterVaultMessage = {Session=SessionId, SentAt=now, Reason=Constants.InterVaultMessageReason.ACQUIRE, JobID=game.JobId}
							local success, result = pcall(MessagingService.PublishAsync, MessagingService, "_DVM"..current.Session, message)
							if not success then
								-- Acquire send failed
								warn("[Retrying]", "MessagingService.PublishAsync", result)
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
				-- Update Failed, retry
				warn("[Retrying 3] Attempt:", attempt, "MemoryStore.UpdateAsync", result)
				attempt += 1
				task.wait(3)
				continue
			end
			MemoryStoreWorking:Update(success)
			-- Needs to retry (acquire process)
			if retryRequired then
				print("Retrying lock acquire")
				-- If acquire sent was successful, save the thread and yield till response is received
				if AcquireSentTo ~= "" and AcquireSentAt ~= 0 then
					LockAcquireThread = coroutine.running()
					-- On another thread resume the thread if not resumed by response
					Thread.Delay((Constants.MessagingExpectedDelay) / 1000 + 1, function(...)
						print("ReSpawning acquire thread")
						local thread = LockAcquireThread
						LockAcquireThread = nil
						if thread ~= nil and coroutine.status(thread) == "suspended" then task.spawn(thread, false) end
					end)
					print("Freezing acquire thread")
					-- Pause execution and on resume check if resumed by response or manually
					if not coroutine.yield() then continue end
					-- Break out of loop if resumed by response
					LockAcquired = true
					break
				end
			else
				-- Mark acquired if retry is not required
				print("Acquired lock")
				LastLockRenewedAt = LockData.LockedAt
				LockAcquired = true
				break
			end
		end
		-- Release lock change lock for other threads
		LockChangeOngoing:Update(false)
	end


	-- Read initial data from datastore
	local function ReadDataAsync()
		print("ReadDataAsync")
		-- While another thread is modifying the state of the data, wait
		while DataChangeOngoing.Current do DataChangeOngoing.ChangeSignal:Wait() end
		-- If vault state changed while waiting, ignore the call
		if VaultPrivateState ~= "REVIVE" then return end
		-- Prevent other threads from modifying data
		DataChangeOngoing:Update(true)
		print("Reading data")
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
			-- If data existed, use it
			if result ~= nil then
				print("Found old data")
				local now = DateTime.now().UnixTimestampMillis
				DSData = result
				Utils.Reconcile(DSData.__PUBLIC, template)
				HasUnsavedChanges = true
				LastDataChangedAt = now
				LastDSSavedAt = now
			else
				-- If no data exist in datastore, use the default data and flag for a save
				print("Using default data")
				HasUnsavedChanges = true
			end
			-- Define data as read
			InitialDataRead = true
			break
		end
		-- Release data change lock for other threads
		DataChangeOngoing:Update(false)
	end


	-- Upon data read, keep it saved every fixed amount of time
	-- TODO: Needs minor optimization for AFK vaults (loop runs (full DSSaveLoopDelay duration) even for AFK vault)
	local function DSSaveLoop()
		print("DSSaveLoop")
		-- If there exist another loop, don't start a new loop
		if DSSaveLoopActive or not DSSaveLoopRequired then return end
		DSSaveLoopActive = true
		print("Data save loop start")
		-- While ds save loop is required, keep running with delay
		while DSSaveLoopRequired do
			local now = DateTime.now().UnixTimestampMillis
			-- If no unsaved changes, wait entire period
			if not InitialDataRead then print("Initial data not read"); task.wait(Constants.DSSaveLoopDelay / 1000); continue end
			if not HasUnsavedChanges then print("No unsaved change"); task.wait(Constants.DSSaveLoopDelay / 1000); continue end
			-- Recent change was within last 5 seconds and last save was within last DSSaveLoopDelay (60 seconds), wait a small period and attempt save
			if now - LastDataChangedAt < 5000 and now - LastDSSavedAt < Constants.DSSaveLoopDelay then print("Last change too recent"); task.wait(10); continue end
			-- Regular save
			SaveDataAsync(false)
		end
		print("Data save loop end")
		-- Allow other threads to start new loop
		DSSaveLoopActive = false
	end


	-- Set the vault in a semi-released mode where the vault is in the hands of the current server but lock is not renewed nor is data saved
	-- Only use for this mode is to prevent re-reviving a new vault and resume operation on this one
	local function StasisAsync()
		print("StasisAsync")
		VaultPrivateState = "STASIS"
		local now = DateTime.now().UnixTimestampMillis
		StasisAt = now
		-- Reset requirement flags
		DSSaveLoopRequired = false
		LockRenewLoopRequired = false
		-- Wait while another instance of Revive, Stasis or Cleanup is ongoing
		while VaultPrivateStateChanging.Current do VaultPrivateStateChanging.ChangeSignal:Wait() end
		-- If changed state while waiting, quit
		if VaultPrivateState ~= "STASIS" then
			VaultPrivateStateChanging:Update(false)
			return
		end
		-- Prevent another instance of Revive, Stasis or Cleanup
		VaultPrivateStateChanging:Update(true)
		-- If lock was not acquired even after waiting, directly cleanup without any wait
		-- Or if another server is waiting for the vault to close, upgrade the lock and cleanup
		if not LockAcquired or AcquireReceivedFrom then
			CleanupAsync()
		else
			-- Save before going stasis
			-- TODO: saving before going stasis removes the possibility of server crashing (data lost while stasis) but it causes unnecessary frequent saves for server jumpers
			if InitialDataRead and HasUnsavedChanges then SaveDataAsync(true) end
			if VaultPrivateState ~= "STASIS" then
				VaultPrivateStateChanging:Update(false)
				return
			end
			-- Add a new delayed thread that waits for a specific time and then cleans up the vault automatically if it has been sitting idle all that time
			Thread.Delay((Constants.MemoryStoreLockExpiryDelay - Constants.MSLockRenewalDelay) / 1000, function()
				if VaultPrivateState == "STASIS" and now == StasisAt then CleanupAsync() end
			end)
			VaultState:Update(Constants.VaultState.STASIS)
		end
	end


	-- Renew lock only when it gets closer to stale
	local function RenewLockAsync()
		print("RenewLockAsync")
		-- While another thread is modifying lock, wait
		while LockChangeOngoing.Current do LockChangeOngoing.ChangeSignal:Wait() end
		local now = DateTime.now().UnixTimestampMillis
		-- If renew was called too early, return and do nothing
		if Constants.MSLockRenewalDelay - 1000 >= (now - LastLockRenewedAt) then return end
		-- Prevent other threads from modifying lock
		LockChangeOngoing:Update(true)
		print("Renewing lock")
		-- Execute as pcall to prevent errors breaking the loop
		local success = pcall(vaultHolder.LockMemoryStore.UpdateAsync, vaultHolder.LockMemoryStore, vaultName,
			function(current: Types.LockData?): Types.LockData?
				now = DateTime.now().UnixTimestampMillis
				if current ~= nil and current.Session == SessionId then
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


	-- Upon lock acquire, keep it updated every fixed amount of time
	local function LockRenewLoop()
		print("LockRenewLoop")
		-- If there exist another loop, don't start a new loop
		if LockRenewLoopActive then return end
		LockRenewLoopActive = true
		print("Lock renew loop start")
		-- While lock renew loop is required, keep renewing with delay
		while LockRenewLoopRequired do
			task.wait(math.max(0, (Constants.MSLockRenewalDelay - (DateTime.now().UnixTimestampMillis - LastLockRenewedAt))/1000))
			RenewLockAsync()
		end
		print("Lock renew loop end")
		-- Allow other threads to start loop now
		LockRenewLoopActive = false
	end


	-- Revive rebuilds missing or broken parts of the vault and make it new ready for use
	-- It is async and so changes while this function is being executed can change or halt the process or reviving
	local function ReviveAsync()
		VaultPrivateState = "REVIVE"
		-- Set all requirement flags
		DSSaveLoopRequired = true
		LockRenewLoopRequired = true
		-- Wait while another instance of Revive, Stasis or Cleanup is ongoing
		while VaultPrivateStateChanging.Current do VaultPrivateStateChanging.ChangeSignal:Wait() end
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
		-- Don't release just yet because the caller of this might be a remote update which is compulsory, or have this part and let the remote update just auto reject
		--if AcquireReceivedFrom ~= "" then
		--	VaultPrivateStateChanging:Update(false)
		--	CleanupAsync()
		--	return
		--end
		-- If data is not present, read the data
		if not InitialDataRead then ReadDataAsync() end
		VaultState:Update(Constants.VaultState.ACTIVE)
		Thread.Defer(DSSaveLoop)
		VaultUsable:Update(true)
		VaultPrivateStateChanging:Update(false)
	end


	-- Initiate all vault services if not started already, the caller will be called a unique reader
	-- Return a unique function to mark release, if no other readers are active, the vault will switch to stasis mode or be cleaned up
	-- This function call is compulsory in order to prevent a vault from getting released automatically (in scenarios like trading where keeping the vault open till trade succeeds)
	-- Similarly, calling the release function is compulsory to let the profile release freely
	function vault:Prepare()
		-- Infinitely scale count to serve individual reader
		local rid = NextReaderId
		NextReaderId += 1
		table.insert(ActiveReaders, rid)
		local shutdownConnection : Signal.Connection<boolean, boolean>
		-- Return a release function unique to the caller that can be called once and any further calls are ignored
		local releaseFunction = function ()
			if shutdownConnection.Connected then shutdownConnection:Disconnect() end
			-- Check if the reader is still active (to prevent double-release)
			local index = table.find(ActiveReaders, rid)
			-- Skip if already called (reader absent)
			if not index then return end
			-- If yes, remove the reader
			table.remove(ActiveReaders, index)
			-- No readers remain, set the vault to stasis mode or cleanup if server is already shutting down
			if #ActiveReaders == 0 then
				print("No active readers")
				-- If server is shutting down then directly cleanup else move to stasis mode
				if ServerShuttingDown then CleanupAsync()
				else StasisAsync()
				end
			end
		end
		-- Attach a watcher for server shut down
		shutdownConnection = ServerShuttingDown.ChangeSignal:Connect(function(_: boolean, isShuttingDown: boolean)
			if isShuttingDown then releaseFunction() end
		end)
		-- Revive the vault
		Thread.Spawn(ReviveAsync)
		return releaseFunction
	end


	return vault
end