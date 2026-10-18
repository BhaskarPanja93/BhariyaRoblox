--!strict
--!native
--!optimize 2

-- TODO: CHECK when requirement flags are changed, it shouldnt change aggressively and should depend on other factors like lock acquired


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


-- Find or create a vault object (unusable)
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
	local VaultStateChanging = State(false) -- Saves when vault is either cleaning itself up or reviving

	local AcquireSentAt = 0 -- Saves when acquire was sent to other server
	local AcquireSentTo = "" -- Saves the server session id who receives acquire
	local AcknowledgedReceivedAt = 0 -- Saves when acknowledge response was received
	local AcknowledgedReceivedFrom = "" -- Saves the server session id who sent response
	local ReleasedReceivedAt = 0 -- Saves when release response was received
	local ReleasedReceivedFrom = "" -- Saves the server session id who sent released

	local AcquireReceivedFrom = "" -- Saves the session who last sent acquire
	local AcquireReceivedAt = 0 -- Saves when last acquire was received

	local MessagingRequired = true -- Saves if messaging chanel is still required
	local MessagingChangeOngoing = State(false) -- Sets when messaging channel change in progress else resets
	local MessagingUsable = State(false) -- Stores state of messaging service for the vault
	local MessagingChannel: RBXScriptConnection? -- Channel to be used for messaging

	local InitialDataRead = State(false) -- Stores if data has been read
	local InitialDataReadRequired = true -- Stores if data read is still required
	local DSSaveLoopRequired = true -- Saves if DataStore saving loop is required at any stage
	local DSSaveLoopActive = true -- Saves if DataStore save loop is active
	local DataChangeOngoing = State(false) -- Sets when change in progress else resets

	local LockAcquired = State(false) -- Sets when lock is confirmed to be owned by self
	local LockAcquireThread: thread? -- Thread waiting for acquire response
	local LockAcquireRequired = true -- Saves if the lock acquire is still required
	local LockRenewLoopRequired = true -- Saves if MemoryStore lock renew is required at any stage
	local LockRenewLoopActive = false -- Saves if MemoryStore lock renew loop is active
	local LockChangeOngoing = State(false) -- Sets when lock change or upgrade in progress else resets

	local RevivedAt = 0 -- Saves when the vault was revived
	local StasisAt = 0 -- Saves when the vault went to stasis mode
	local CleanedUp = 0 -- Saves when the vault was cleaned up
	local LastDSSaveAt = 0 -- Saves when vault last saved to DataStore
	local LastDataChangeAt = 0 -- Saves when vault data was last modified
	local LastLockRenewAt = 0 -- Saves when lock was last updated in MemoryStore


	vault.Name = vaultName
	vault.Usable = VaultUsable
	vault.DataUpdatedSignal = DataUpdatedSignal
	vault.SessionId = SessionId
	vault.ActivityData = ActivityData
	vault.PublicData = PublicData
	vault.Locals = {}


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


	--local function LockConsensusL2Async():(boolean, AcquireStatus?)
	--	if MSStoredLock == nil then return false, nil end
	--	-- The code no longer checks the number of times acquire was sent, it checks time difference between acquire and response
	--	-- So there is no need to worry about a delayed response. we can safely ignore that knowing it has updated the reception time
	--	if AcquireSentAt and ResponseReceivedAt > AcquireSentAt then
	--		if AcquireSentTo == AcknowledgedReceivedFrom then
	--			return true, Constants.AcquireState.ACKNOWLEDGED
	--		elseif AcquireSentTo == ReleasedReceivedFrom then
	--			return true, Constants.AcquireState.RELEASED
	--		end
	--	end
	--	local now = DateTime.now().UnixTimestampMillis
	--	AcquireSentAt = now
	--	AcquireSentTo = MSStoredLock.Session
	--	AcknowledgedReceivedFrom = ""
	--	ReleasedReceivedFrom = ""
	--	local message:InterVaultMessage = {Session=SessionId, SentAt=now, Reason=Constants.InterVaultMessageReason.ACQUIRE, JobID=game.JobId}
	--	local success = pcall(MessagingService.PublishAsync, MessagingService, "_DVMS"..AcquireSentTo, message)
	--	if not success then
	--		return false, nil
	--	end
	--	local state = Constants.AcquireState.UNKNOWN
	--	for i = 1, Constants.MessagingExpectedDelay + 1 do
	--		if not #ActiveReaders then
	--			return false, nil
	--		end
	--		task.wait(1)
	--		if ReleasedReceivedFrom and ReleasedReceivedFrom == AcquireSentTo then
	--			return true, Constants.AcquireState.RELEASED
	--		elseif AcknowledgedReceivedFrom and AcknowledgedReceivedFrom == AcquireSentTo then
	--			state = Constants.AcquireState.ACKNOWLEDGED
	--		end
	--	end
	--	return true, state
	--end


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
		while MessagingRequired and not MessagingUsable.Current do
			-- Try subscribing to the session
			local success, result = pcall(MessagingService.SubscribeAsync, MessagingService, "_DVM"..SessionId,
				function(Message: {Data:Types.InterVaultMessage, Sent:number})
				-- TODO: Messaging logic
				end)
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
			MessagingUsable:Update(true)
			break
		end
		-- Release the lock for messaging change
		MessagingChangeOngoing:Update(false)
	end


	-- Closes Messaging for the vault (skips if it is already disconnected or never created)
	local function CloseMessaging()
	-- While another thread is modifying the state of the messaging, wait
		while MessagingChangeOngoing.Current do
			if not MessagingChangeOngoing.ChangeSignal:Wait() then break end
		end
		-- Prevent other thread from modifying messaging
		MessagingChangeOngoing:Update(true)
		-- If Messaging channel exists and is not required, disconnect it
		if not MessagingRequired and MessagingChannel then
			MessagingChannel:Disconnect()
			MessagingChannel = nil
			MessagingUsable:Update(false)
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
		while LockAcquireRequired and not LockAcquired.Current do
			local retryRequired = false
			local success, result = pcall(vaultHolder.LockMemoryStore.UpdateAsync, vaultHolder.LockMemoryStore, vaultName,
				function(current: Types.LockData?): Types.LockData?
					local now = DateTime.now().UnixTimestampMillis
					if current == nil then
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
						-- Ignore if its current session and is fresh
						LockData = current
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
							AcknowledgedReceivedFrom = ""
							ReleasedReceivedFrom = ""
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
				MemoryStoreWorking:Update(false)
				warn("[Retrying 2] Attempt:", attempt, "MemoryStore.UpdateAsync failed", result)
				attempt += 1
				task.wait(2)
				continue
			end
			DataStoreWorking:Update(true)
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
						LockAcquired:Update(true)
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
				LockAcquired:Update(true)
				break
			end
		end
		LockChangeOngoing:Update(false)
	end


	local function ReleaseLockAsync()
		-- TODO
	end


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
		while InitialDataReadRequired and not InitialDataRead.Current do
			-- Try reading data from DataStore
			local success, result:Types.DataStoreData? = pcall(vaultHolder.VaultDataStore.GetAsync, vaultHolder.VaultDataStore, vaultName, nil)
			-- If read failed, retry after some time
			if not success then
				DataStoreWorking:Update(false)
				warn("[Retrying 5] Attempt:", attempt, "DataStore.GetAsync", result)
				attempt += 1
				task.wait(5)
				continue
			end
			DataStoreWorking:Update(true)
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
			InitialDataRead:Update(true)
			break
		end
	end


	local function SaveDataAsync()
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
		-- Continue till there are changes yet to be saved
		while HasUnsavedChanges do
			local now = DateTime.now().UnixTimestampMillis
			local data = DSData
			HasUnsavedChanges = false
			local success, result = pcall(vaultHolder.VaultDataStore.SetAsync, vaultHolder.VaultDataStore, vaultName, data)
			if not success then
				-- If failed, retry after a delay
				HasUnsavedChanges = true
				DataStoreWorking:Update(false)
				warn("[Retrying 5] Attempt:", attempt, "DataStore.GetAsync", result)
				attempt += 1
				task.wait(5)
				continue
			end
			LastDSSaveAt = now
			DataStoreWorking:Update(true)
			DataChangeOngoing:Update(false)
		end
	end


	local function DSSaveLoop()
		-- Allow only 1 instance of DS save loop
		if DSSaveLoopActive or not DSSaveLoopRequired then return end
		DSSaveLoopActive = true
		while DSSaveLoopRequired do
			local now = DateTime.now().UnixTimestampMillis
			-- If no unsaved changes or
			-- Recent change was within last 5 seconds and last save was within last DSSaveLoopDelay (45 seconds), skip current iteration
			if not HasUnsavedChanges or (now - LastDataChangeAt < 5000 and now - LastDSSaveAt < Constants.DSSaveLoopDelay) then
				task.wait(5)
				continue
			end
			SaveDataAsync()
		end
		DSSaveLoopActive = false
	end


	-- Cleanup the vault from memory, leaving it totally unusable
	local function CleanupAsync()
		-- De-reference the vault instantly so future vault queries return a new vault
		vaultHolder.Vaults[vaultName] = nil
		VaultUsable:Update(false)
		-- Reset all requirements
		DSSaveLoopRequired = false
		LockRenewLoopRequired = false
		InitialDataReadRequired = false
		-- Save oen final time
		SaveDataAsync()
		-- Release the lock safely (upgrade if required)
		ReleaseLockAsync()
		-- Close messaging channel
		CloseMessaging()
		-- Set new state for the vault
		VaultState:Update(Constants.VaultState.RELEASED)
		-- Send forget to the
		-- Cleanup if lock acquire was still waiting
		local thread = LockAcquireThread
		LockAcquireThread = nil
		if thread and coroutine.status(thread) == "suspended" then
			task.spawn(thread, false)
		end
	end


	-- Set the vault in a semi-released mode where the vault is in the hands of the current server but lock is not renewed nor is data saved
	-- Only use for this mode is to prevent re-reviving a new vault and resume operation on this one
	local function StasisAsync()
		local now = DateTime.now().UnixTimestampMillis
		StasisAt = now
		MessagingRequired = false
		LockAcquireRequired = false
		InitialDataReadRequired = LockAcquired.Current
		DSSaveLoopRequired = false
		LockRenewLoopRequired = false
		-- Wait while another instance of Revive, Statis or Cleanup is ongoing
		while VaultStateChanging.Current do
			DataChangeOngoing.ChangeSignal:Wait()
		end
		-- If received new readers while waiting, quit
		if #ActiveReaders then
			return
		end
		-- Prevent another instance of Revive, Statis or Cleanup
		VaultStateChanging:Update(true)
		-- Re-evaluating is because statis might be waiting for locking state of revive and lock might succeed
		InitialDataReadRequired = LockAcquired.Current
		if not LockAcquired.Current then
			CleanupAsync()
			return
		end
		-- Add a new delayed thread that
		Thread.Delay(Constants.MemoryStoreLockExpiryDelay / 1000, function()
			if VaultState.Current == Constants.VaultState.STASIS and now == StasisAt then
				CleanupAsync()
			end
		end)
		VaultState:Update(Constants.VaultState.STASIS)
	end


	local function RenewLockAsync()
		-- Execute as pcall to prevent errors blocking the loop
		local success, newLock = pcall(vaultHolder.LockMemoryStore.UpdateAsync, vaultHolder.LockMemoryStore, vaultName,
			function(current: Types.LockData?): Types.LockData?
				local now = DateTime.now().UnixTimestampMillis
				if current and current.Session == SessionId then
					-- For same session id, update with new lock
					LockData.LockedAt = now
					return LockData
				else
					-- For changed session id, mark lock as released, discard any unsaved changes and cleanup the vault
					HasUnsavedChanges = false
					LockAcquired:Update(false)
					CleanupAsync()
					return nil
				end
			end, Constants.MemoryStoreLockExpiryDelay)
		if success then
			MemoryStoreWorking:Update(true)
		else
			MemoryStoreWorking:Update(false)
		end
		return success, newLock
	end


	local function LockRenewLoop()
		if LockRenewLoopActive then return end
		LockRenewLoopActive = true
		LockChangeOngoing:Update(true)
		local attempt = 0
		while LockRenewLoopRequired do
			local success, newLock = RenewLockAsync()
			if not success then
				attempt += 1
				warn("[Retrying 2] Attempt:", attempt, "MemoryStore.UpdateAsync", newLock)
				if LastLockRenewAt + Constants.MemoryStoreLockExpiryDelay > DateTime.now().UnixTimestampMillis then
					CleanupAsync()
					return
				end
				task.wait(2)
				continue
			end
			attempt = 0
			if newLock == nil then
				CleanupAsync()
				return
			end
			LastLockRenewAt = DateTime.now().UnixTimestampMillis
			task.wait(Constants.MSLockRenewalDelay / 1000)
		end
		LockRenewLoopActive = false
	end


	local function ReviveAsync()
		RevivedAt = DateTime.now().UnixTimestampMillis
		MessagingRequired = true
		LockAcquireRequired = true
		InitialDataReadRequired = true
		DSSaveLoopRequired = true
		LockRenewLoopRequired = true
		-- Wait while another instance of Revive, Statis or Cleanup is ongoing
		while VaultStateChanging.Current do
			DataChangeOngoing.ChangeSignal:Wait()
		end
		-- If reader left while waiting, quit
		if not #ActiveReaders then
			return
		end
		-- Prevent another instance of Revive, Statis or Cleanup
		VaultStateChanging:Update(true)
		-- Blocking Setup Messaging until it is required and not set up
		if not MessagingUsable.Current then PrepareMessagingAsync() end
		-- If readers left by the time messaging was prepared, close and let cleanup take over
		if not #ActiveReaders then
			VaultStateChanging:Update(false)
			return
		end
		-- Blocking Lock acquire until it is required and not acquired
		if not LockAcquired.Current then AcquireLockAsync() end
		-- If lock is not acquired yet and readers left, close and let cleanup take over
		if not #ActiveReaders and not LockAcquired.Current then
			VaultStateChanging:Update(false)
			return
		end
		-- Start the lock renew loop
		Thread.Defer(LockRenewLoop)
		-- If another server did not send acquire and data is not present, read the data
		if not AcquireReceivedFrom and not InitialDataRead.Current then ReadDataAsync() end
		-- If another server requested acquire, close and let cleanup take over
		if AcquireReceivedFrom then
			VaultStateChanging:Update(false)
			return
		end
		Thread.Defer(DSSaveLoop)
		VaultStateChanging:Update(false)
		VaultUsable:Update(true)
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
		-- Revive the vault (auto ignored if not in stasis mode)
		Thread.Defer(ReviveAsync)
		-- Return a release function unique to the caller that can be called once and any further calls are ignored
		return function ()
			-- Check if the reader is still active (to prevent double-release)
			local index = table.find(ActiveReaders, rid)
			if not index then return end
			-- If yes, remove the reader
			table.remove(ActiveReaders, index)
			-- No readers remain, set the vault to stasis mode or cleanup if server is already shutting down
			if not #ActiveReaders then
				if ServerShuttingDown then CleanupAsync()
				else StasisAsync()
				end
			end
		end
	end


	return vault
end