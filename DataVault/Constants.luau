local Types = require(script.Parent.Types)


return {
	InterDSMessageReason = table.freeze({
		ACQUIRE 	= 0 	:: Types.InterDSMessageReason, -- Ask for lock from old server
		RELEASED 	= 1 	:: Types.InterDSMessageReason, -- Vault was released and lock is either upgraded or removed
		FORGET 		= 2 	:: Types.InterDSMessageReason, -- Ask old server to ignore previous acquire call
		OK 			= 3 	:: Types.InterDSMessageReason, -- Server PONG response
		UPDATE 		= 4 	:: Types.InterDSMessageReason, -- Remote data update from other server
	}),
	VaultState = table.freeze({
		CREATED 	= 0 	:: Types.VaultState, -- Freshly created vault object
		OPENING 	= 1 	:: Types.VaultState, -- Reader has been added
		LOCKED 		= 2 	:: Types.VaultState, -- Vault has completed acquiring lock, data is not loaded yet
		ACTIVE 		= 3 	:: Types.VaultState, -- This is when data is totally in hand and is locked and ready for use
		RELEASING 	= 4 	:: Types.VaultState, -- Vault has no readers so release process started, server will still hold the vault in case player returns
		STASIS 		= 5 	:: Types.VaultState, -- Server is waiting for player to rejoin or other server to request lock acquire
		RELEASED 	= 6 	:: Types.VaultState, -- Vault was called from other server or player rejoined and current vault is now stale and cleaned up
	}),
	LockState = table.freeze({
		NONEXISTANT = -1,
		STALE = 0,
		FRESH = 1,
	}),

	MSLockRenewalDelay 					= 20 * 1000, -- 20 seconds (Server updates MS after this interval)
	MSLockStaleDelay 					= (20 * 1000 * 5) + 1000, -- 101 seconds (5 misses) (MS not updated for this interval is considered down or dead)
	MemoryStoreLockExpiryDelay 			= 120 * 60 * 1000, -- 120 minutes (MS exist for this interval so other servers can see who owned the lock before down or dead, or still owns it)

	DSLockRenewalDelay 					= 60 * 1000, -- 60 seconds (Server updates the DS after this interval)
	DSLockStaleDelay 					= (60 * 1000 * 5) + 1000, -- 301 seconds (5 misses) (DS not updated for this interval is considered down or dead)

	MessagingExpectedDelay				= 7 * 1000, -- 7 seconds
	DSSaveLoopDelay 					= 45 * 1000, -- 45 seconds
}