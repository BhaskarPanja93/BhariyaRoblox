--!strict
--!native
--!optimize 2


const DataStoreService = game:GetService("DataStoreService")
const MemoryStoreService = game:GetService("MemoryStoreService")


const Types = require(script.Parent:WaitForChild("Types"))


const VaultsHolders: {[string]: Types.VaultsHolder} = {}


-- Fetch a VaultsHolder
return function(dsName: string): Types.VaultsHolder


-- Fetch datastore holder by name
	local dsh: Types.VaultsHolder = VaultsHolders[dsName]


	-- Check if non-existent
	if dsh == nil then


	-- Create new datastore holder
		dsh = {
			Name = dsName,
			Vaults = {},
			VaultDataStore = DataStoreService:GetDataStore("_DVD/"..dsName),
			LockMemoryStore = MemoryStoreService:GetHashMap("_DVL/"..dsName)
		}


		-- Register the new datastore holder
		VaultsHolders[dsName] = dsh
	end


	-- Return datastore holder
	return dsh
end