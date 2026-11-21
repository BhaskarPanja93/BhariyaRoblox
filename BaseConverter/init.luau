--!strict
--!native
--!optimize 2

--[[
BaseConverter v1.1.1
Keep a note of the version for tracking updates and changes
]]


-- Removed [space] and [|] from the set so they can be used freely for concat, and other string operations
local CHARACTER_SET = {
	"a","b","c","d","e","f","g","h","i","j",
	"k","l","m","n","o","p","q","r","s","t",
	"u","v","w","x","y","z",

	"A","B","C","D","E","F","G","H","I","J",
	"K","L","M","N","O","P","Q","R","S","T",

	"U","V","W","X","Y","Z",

	"0","1","2","3","4","5","6","7","8","9",

	"!","@","#","$","%","^","&","*","(",")",
	"|","_","=","+","[","]","{","}",";",":",
	",",".","<",">","?","~"
}


-- Base of the encoded string value
const BASE = #CHARACTER_SET


-- Negative sign
const NEGATIVE_SIGN = "-"


-- Reverse map
local CHAR_TO_VALUE = {}


-- Build the reverse map
for index, char in ipairs(CHARACTER_SET) do
	assert(not CHAR_TO_VALUE[char], "Duplicate character: "..char)
	CHAR_TO_VALUE[char] = index - 1
end


-- Encode a number to its string form
const function Encode(n: number): string


	-- Determine whether the number is negative
	const isNegative = n < 0


	-- Convert to positive number
	n = math.abs(n)


	-- No modulus loop is required if the number is zero
	if n == 0 then
		return CHARACTER_SET[1]
	end


	-- Store the characters
	local result = {}


	-- Store the remainder
	local remainder: number


	-- Keep finding the modulus till number reaches less than base
	while n > 0 do
		remainder = n % BASE
		n = math.floor(n / BASE)


		-- Add each character to the table
		table.insert(result, CHARACTER_SET[remainder + 1])
	end


	-- Concat of the table gives the final encoded string
	const encoded = table.concat(result)


	-- Add the negative sign if necessary
	if isNegative then
		return NEGATIVE_SIGN .. encoded
	end


	return encoded
end


-- Decode an encoded string back to its numeric form
const function Decode(s: string): number


	-- Check for negative sign
	const isNegative = s:sub(1, 1) == NEGATIVE_SIGN


	-- Remove the sign if negative
	if isNegative then
		s = s:sub(2)
	end


	-- Final numeric value, start with 0
	local value = 0


	-- Store the current character and its conversion
	local char: string
	local digit: number


	-- For each character, find the number from the reverse map
	for i = #s, 1, -1 do


		-- Convert the character
		char = s:sub(i, i)
		digit = CHAR_TO_VALUE[char]


		-- Assert if the digit exists
		assert(digit ~= nil, "Invalid character: "..char)


		-- Add the value
		value = value * BASE + digit
	end


	-- Return the final sum of all letters converted to number
	if isNegative then
		return -value
	end


	return value
end


-- Return a table with the encode and decode methods
return table.freeze({
	Encode = Encode,
	Decode = Decode
})
