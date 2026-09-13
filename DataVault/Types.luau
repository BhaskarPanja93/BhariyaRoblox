
local Promise = require("../Promise")
local Signal = require("../Signal")
local State = require("../State")


export type Vault<DataT =	any> = {
	PrepareAsync:				(self:Vault<DataT>)->()->(),
	UpdateData: 				(self:Vault<DataT>, value:any, ...any)->(),
	GetPublicData: 				(self:Vault<DataT>)->DataT,
	GetActivityData:			(self:Vault<DataT>)->ActivityData,
	Usable:						State.State<boolean>,
	DataUpdateSignal:			Signal.Signal<any, ...any>,
	SessionId:					string,
	Name: 						string,

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


export type InterDSMessages = {
	SentAt:number,
	Reason:InterDSMessageReason,
	JobID: string,
	Session: string,
	Extra: any
}


export type DataStoreHolder = {
	Name:string,
	VaultDataStore:DataStore,
	LockDataStore:DataStore,
	LockMemoryStore:MemoryStoreHashMap,
	Vaults:{[string]:Vault}
}


export type Acquirer = {
	JobId:string,
	Session:string,
	AcquireTime:number
}


export type LockState = number
export type VaultState = number
export type InterDSMessageReason = number

return nil
