local Signal = require(script.Parent.Parent:WaitForChild('Signal'))
local State = require(script.Parent.Parent:WaitForChild('State'))


export type Vault<DataT =	any> = {
	Prepare:					(self:Vault<DataT>)->()->(),
	UpdateData: 				(self:Vault<DataT>, value:any, ...any)->(),
	PublicData: 				DataT,
	ActivityData:				ActivityData,
	Usable:						State.State<boolean>,
	DataUpdatedSignal:			Signal.Signal<any, ...any>,
	SessionId:					string,
	Name: 						string,
	Locals:						{},

	__index: Vault<DataT>,
}


export type LockData = {
	JobId:string,
	LockedAt:number,
	Session:string
}


export type ActivityData = {
	FirstLogIn:number,
	LastLogIn:number,
	LastLogOut:number,
	LastSave:number
}


export type DataStoreData = {
	__ACTIVITY:ActivityData,
	__PUBLIC:any
}


export type InterVaultMessage = {
	SentAt:number,
	Reason:InterVaultMessageReason,
	JobID: string,
	Session: string,
	Extra: any
}


export type VaultsHolder = {
	Name:string,
	VaultDataStore:DataStore,
	LockMemoryStore:MemoryStoreHashMap,
	Vaults:{[string]:Vault}
}


export type Acquirer = {
	JobId:string,
	Session:string,
	AcquireTime:number
}


export type AcquireStatus = number
export type LockFreshness = number
export type VaultState = number
export type InterVaultMessageReason = number


return nil
