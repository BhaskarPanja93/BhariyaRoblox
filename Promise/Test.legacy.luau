local Promise = require(script.Parent)


local expected = ""
local actual = ""


function addToActual(value)
	if value == nil then addToActual("nil") end
	if value == false then addToActual("false") end
	if value == true then addToActual("true") end
	if typeof(value) == "string" then actual = actual..value.." " end
end

function resetActual()
	actual = ""
end

function compare()
	print(if actual == expected then "PASS" else "FAIL")
	if actual ~= expected then print(actual) end
end


local p, q
local success, temp

local x = Promise.New(function(resolve, reject)
	resolve(12345)
	reject("")
end)


----------------------------------------------------------------
-- TEST_LATE_SUBSCRIBERS
----------------------------------------------------------------

print("\nTEST_LATE_SUBSCRIBERS")

resetActual()
expected = "p resolve OK q reject NO q catch NO p await true OK q await false NO "

p = Promise.New(function(resolve, reject)
	resolve("OK")
end)
q = Promise.New(function(resolve, reject)
	reject("NO")
end)

task.wait()

p:AndThen(function(value)
	addToActual("p resolve")
	addToActual(value)
end, function(reason)
	addToActual("p reject")
	addToActual(reason)
end)

p:Catch(function(reason)
	addToActual("p catch")
	addToActual(reason)
end)

q:AndThen(function(value)
	addToActual("q catch")
	addToActual(value)
end, function(reason)
	addToActual("q reject")
	addToActual(reason)
end)

q:Catch(function(reason)
	addToActual("q catch")
	addToActual(reason)
end)

success, temp = p:Await()
addToActual("p await")
addToActual(success)
addToActual(temp)

success, temp = q:Await()
addToActual("q await")
addToActual(success)
addToActual(temp)


compare()

----------------------------------------------------------------
-- TEST_EARLY_SUBSCRIBERS
----------------------------------------------------------------

print("\nTEST_EARLY_SUBSCRIBERS")

resetActual()
expected = "p resolve OK p await true OK q reject NO q catch NO q await false NO "


p = Promise.New(function(resolve, reject)
	task.wait()
	resolve("OK")
end)
q = Promise.New(function(resolve, reject)
	task.wait(1)
	reject("NO")
end)


p:AndThen(function(value)
	addToActual("p resolve")
	addToActual(value)
end, function(reason)
	addToActual("p reject")
	addToActual(reason)
end)

p:Catch(function(reason)
	addToActual("p catch")
	addToActual(reason)
end)

q:AndThen(function(value)
	addToActual("q catch")
	addToActual(value)
end, function(reason)
	addToActual("q reject")
	addToActual(reason)
end)

q:Catch(function(reason)
	addToActual("q catch")
	addToActual(reason)
end)

success, temp = p:Await()
addToActual("p await")
addToActual(success)
addToActual(temp)

success, temp = q:Await()
addToActual("q await")
addToActual(success)
addToActual(temp)


compare()

----------------------------------------------------------------
-- TEST_MULTIPLE_VALUES
----------------------------------------------------------------

print("\nTEST_MULTIPLE_VALUES")

resetActual()
expected = "p resolve OK q reject NO q catch NO p await true OK q await false NO "


p = Promise.New(function(resolve, reject)
	resolve("OK")
	resolve("OKKK")
	reject("NOOO")
end)
q = Promise.New(function(resolve, reject)
	reject("NO")
	resolve("OKKK")
	reject("NOOO")
end)


p:AndThen(function(value)
	addToActual("p resolve")
	addToActual(value)
end, function(reason)
	addToActual("p reject")
	addToActual(reason)
end)

p:Catch(function(reason)
	addToActual("p catch")
	addToActual(reason)
end)

q:AndThen(function(value)
	addToActual("q catch")
	addToActual(value)
end, function(reason)
	addToActual("q reject")
	addToActual(reason)
end)

q:Catch(function(reason)
	addToActual("q catch")
	addToActual(reason)
end)

success, temp = p:Await()
addToActual("p await")
addToActual(success)
addToActual(temp)

success, temp = q:Await()
addToActual("q await")
addToActual(success)
addToActual(temp)


compare()


----------------------------------------------------------------
-- TEST_DEFERRED_RESET
----------------------------------------------------------------

print("\nTEST_DEFERRED_RESET")

resetActual()
expected = "d resolve OK d await true OK d reject NO d catch NO d await false NO "


local d = Promise.Deferred()

d.Promise:AndThen(function(value)
	addToActual("d resolve")
	addToActual(value)
end, function(reason)
	addToActual("d reject")
	addToActual(reason)
end)

d.Promise:Catch(function(reason)
	addToActual("d catch")
	addToActual(reason)
end)

d:Resolve("OK")

success, temp = d.Promise:Await()
addToActual("d await")
addToActual(success)
addToActual(temp)

d:Reset()


d.Promise:AndThen(function(value)
	addToActual("d resolve")
	addToActual(value)
end, function(reason)
	addToActual("d reject")
	addToActual(reason)
end)

d.Promise:Catch(function(reason)
	addToActual("d catch")
	addToActual(reason)
end)

d:Reject("NO")

success, temp = d.Promise:Await()
addToActual("d await")
addToActual(success)
addToActual(temp)


compare()
