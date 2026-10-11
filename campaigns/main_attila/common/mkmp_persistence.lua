-- Shared save codec helpers. Schema 3 retains the established comma/semicolon
-- structure, escapes scalar bytes, and frames the payload to detect a mismatched
-- sidecar. Schemas 0 (no sidecar), 1 and 2 are read literally, never unescaped.
-- This module performs no file I/O and no shared-model mutation.

MK1212_SAVE_V3_PREFIX = "MK1212_SAVE_V3|";

function MK1212_IsFiniteNumber(value)
	return type(value) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge;
end

function MK1212_SaveScalar(value)
	local kind = type(value);
	if kind == "string" or kind == "boolean" then
		return tostring(value);
	end
	if MK1212_IsFiniteNumber(value) then
		-- Use round-trip precision for Lua numbers, including binary64 builds.
		-- Normalize the
		-- decimal separator; local UI/OS locale must not select a save encoding.
		if value == 0 then return "0"; end
		return (string.gsub(string.format("%.17g", value), ",", "."));
	end
	error("MK1212 save refused: unsupported/non-finite scalar "..kind);
end

function MK1212_SaveToken(value, maximum_bytes)
	local text = MK1212_SaveScalar(value);
	local limit = math.min(maximum_bytes or MK1212_SAVE_MAX_STRING_BYTES, MK1212_SAVE_MAX_STRING_BYTES);
	if #text > limit or (text == "" and limit < 2) then
		error("MK1212 save refused: scalar exceeds byte budget");
	end
	if text == "" then return "%E"; end
	local bytes = #text;
	return (string.gsub(text, "[%%,;%z\1-\31\127]", function(char)
		bytes = bytes + 2;
		if bytes > limit then error("MK1212 save refused: escaped scalar exceeds byte budget"); end
		return string.format("%%%02X", string.byte(char));
	end));
end

function MK1212_SaveAppend(parts, value, separator)
	-- Account for the complete framed payload before retaining the next scalar.
	-- Repeated references to one large string cannot accumulate unbounded copies.
	local used = parts.bytes or #MK1212_SAVE_V3_PREFIX;
	local token = MK1212_SaveToken(value, MK1212_SAVE_MAX_STRING_BYTES - used - #separator);
	parts[#parts + 1] = token..separator;
	parts.bytes = used + #token + #separator;
end

function MK1212_SaveEndRow(parts)
	local used = parts.bytes or #MK1212_SAVE_V3_PREFIX;
	if used + 1 > MK1212_SAVE_MAX_STRING_BYTES then error("MK1212 save refused: row exceeds byte budget"); end
	parts[#parts + 1] = ";";
	parts.bytes = used + 1;
end

local function DecodeSaveToken(token, schema, savename)
	if schema < 3 then return token; end
	if token == "%E" then return ""; end
	local parts = {};
	local position = 1;
	while position <= #token do
		local char = string.sub(token, position, position);
		if char == "%" then
			local hex = string.sub(token, position + 1, position + 2);
			if #hex ~= 2 or not string.match(hex, "^[0-9A-F][0-9A-F]$") then
				error("MK1212 load refused: invalid escape in "..savename);
			end
			parts[#parts + 1] = string.char(tonumber(hex, 16));
			position = position + 3;
		else
			parts[#parts + 1] = char;
			position = position + 1;
		end
	end
	local decoded = table.concat(parts);
	if MK1212_SaveToken(decoded) ~= token then
		error("MK1212 load refused: noncanonical escape in "..savename);
	end
	return decoded;
end

function MK1212_SaveByteLess(first, second)
	-- Lua 5.1 string '<' uses strcoll and therefore the process locale. Save
	-- ordering is a byte contract, including accented names and punctuation.
	for i = 1, math.min(#first, #second) do
		local a, b = string.byte(first, i), string.byte(second, i);
		if a ~= b then return a < b; end
	end
	return #first < #second;
end

function MK1212_SaveDenseLength(tab, maximum_entries)
	if type(tab) ~= "table" then error("MK1212 save refused: expected array"); end
	local count = 0;
	local maximum = 0;
	for key, _ in pairs(tab) do
		if not MK1212_IsFiniteNumber(key) or key < 1 or key ~= math.floor(key) then
			error("MK1212 save refused: non-array key");
		end
		count = count + 1;
		maximum = math.max(maximum, key);
		if count > (maximum_entries or MK1212_SAVE_MAX_ENTRIES) then
			error("MK1212 save refused: array exceeds entry budget");
		end
	end
	if maximum ~= count then error("MK1212 save refused: sparse array"); end
	return count;
end

function MK1212_SaveReadString(context, savename)
	local schema = cm:load_value(savename.."__schema", 0, context);
	if schema ~= 0 and schema ~= 1 and schema ~= 2 and schema ~= 3 then
		error("MK1212 load refused: unsupported schema for "..savename..": "..tostring(schema));
	end
	local payload = cm:load_value(savename, "", context);
	if type(payload) ~= "string" or #payload > MK1212_SAVE_MAX_STRING_BYTES then
		error("MK1212 load refused: invalid/oversized payload for "..savename);
	end
	local framed = string.sub(payload, 1, #MK1212_SAVE_V3_PREFIX) == MK1212_SAVE_V3_PREFIX;
	if schema == 3 then
		if not framed then error("MK1212 load refused: schema/payload mismatch for "..savename); end
		payload = string.sub(payload, #MK1212_SAVE_V3_PREFIX + 1);
	end
	return payload, schema;
end

local function SplitSaveFields(text, delimiter, savename, maximum_entries)
	local values = {};
	local position = 1;
	while position <= #text do
		local separator = string.find(text, delimiter, position, true);
		if not separator or separator == position then
			error("MK1212 load refused: malformed fields in "..savename);
		end
		values[#values + 1] = string.sub(text, position, separator - 1);
		if #values > (maximum_entries or MK1212_SAVE_MAX_ENTRIES) then
			error("MK1212 load refused: entry budget in "..savename);
		end
		position = separator + 1;
	end
	return values;
end

function MK1212_LoadSaveList(context, savename)
	local payload, schema = MK1212_SaveReadString(context, savename);
	local fields = SplitSaveFields(payload, ",", savename);
	for i = 1, #fields do fields[i] = DecodeSaveToken(fields[i], schema, savename); end
	return fields;
end

function MK1212_LoadSaveRows(context, savename)
	local payload, schema = MK1212_SaveReadString(context, savename);
	local encoded_rows = SplitSaveFields(payload, ";", savename);
	local rows = {};
	for i = 1, #encoded_rows do
		-- Legacy map budgets count rows, not scalar fields. The already-checked
		-- byte budget bounds nested lists without halving valid map capacity.
		local fields = SplitSaveFields(encoded_rows[i], ",", savename, MK1212_SAVE_MAX_STRING_BYTES);
		for j = 1, #fields do fields[j] = DecodeSaveToken(fields[j], schema, savename); end
		rows[#rows + 1] = fields;
	end
	return rows;
end

function MK1212_SaveNumber(value, savename)
	local result = tonumber(value);
	if result == nil and type(value) == "string" then
		-- Lua 5.1 tonumber uses the process strtod locale. Keep the canonical
		-- on-disk dot, but let the native correctly-rounded parser consume its
		-- own decimal marker. Never change the game's process-wide locale.
		local marker = string.sub(string.format("%.1f", 1.5), 2, -2);
		if marker ~= "." and marker ~= "" then
			result = tonumber((string.gsub(value, "%.", marker)));
		end
	end
	if not MK1212_IsFiniteNumber(result) then
		error("MK1212 load refused: invalid number in "..tostring(savename));
	end
	return result;
end

function MK1212_SaveBoolean(value, savename)
	if value == "true" then return true; end
	if value == "false" then return false; end
	error("MK1212 load refused: invalid boolean in "..tostring(savename));
end

function MK1212_SaveUniqueRow(tab, row, field_count, savename)
	if #row ~= field_count or row[1] == nil or tab[row[1]] ~= nil then
		error("MK1212 load refused: malformed/duplicate row in "..savename);
	end
	return row[1];
end

function MK1212_SaveChecksum(payload)
	-- Adler-32 is a bounded diagnostics checksum, not a cryptographic identity.
	-- It never selects a gameplay path; the pack manifest uses SHA-256 separately.
	local a, b = 1, 0;
	for i = 1, #payload do
		a = (a + string.byte(payload, i)) % 65521;
		b = (b + a) % 65521;
	end
	-- The vendored Attila Lua harness uses float numbers. Each 16-bit half is
	-- exact; combining them arithmetically into 32 bits could lose low bits.
	return "adler32-v1:"..string.format("%04x%04x", b, a);
end
