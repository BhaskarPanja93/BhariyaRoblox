--!strict

local DataVault = require(script.Parent)


local temp = {
	Name = "",
	Score = 0,
	Has = {
		["A"] = 10,
		["B"] = 0,
		[100] = 0
	}
}


local vault = DataVault("DataVault-T1", "1", temp)


vault.DataUpdatedSignal:Connect(function(value, ...) 
	print("Data changed", ..., "to", value)
end)


vault:Prepare()


while not vault.Usable.Current do
	print("Usable", vault.Usable.ChangeSignal:Wait())
end



print(vault.PublicData, vault.ActivityData)

