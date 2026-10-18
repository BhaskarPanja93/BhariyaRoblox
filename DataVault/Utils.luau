local function DeepClone<T>(template: T): T
	if type(template) ~= "table" then
		return template :: T
	end
	local clone = {}
	for index, value in template :: {[any]:any} do
		clone[index] = DeepClone(value)
	end
	return clone :: T
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


return {
	DeepClone = DeepClone,
	Reconcile = Reconcile
}