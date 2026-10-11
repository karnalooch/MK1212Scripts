-- Bounded canonical diagnostic snapshots. These bytes and checksums are never
-- campaign authority. Plain tables only; ordered queues retain numeric keys.
-- Strings are hex-encoded bytes so binary/control/UTF-8 data are unambiguous.
MKMP_FINGERPRINT_SCHEMA = "mkfp-table-v1";
MKMP_FINGERPRINT_MAX_ENTRIES = 16384;
MKMP_FINGERPRINT_MAX_BYTES = 65536;
MKMP_FINGERPRINT_MAX_DEPTH = 16;

function MKMP_Fingerprint_ByteLess(first, second)
	for i = 1, math.min(#first, #second) do
		local a, b = string.byte(first, i), string.byte(second, i);
		if a ~= b then return a < b; end
	end
	return #first < #second;
end

local function NumberText(value)
	if value ~= value or value == math.huge or value == -math.huge then
		error("MKFP:non_finite_number");
	end
	if value == 0 then return "0"; end
	return (string.gsub(string.format("%.17g", value), ",", "."));
end

local function Scalar(value)
	local kind = type(value);
	if kind == "string" then
		if #value * 2 > MKMP_FINGERPRINT_MAX_BYTES then error("MKFP:byte_budget"); end
		local encoded = string.gsub(value, ".", function(char)
			return string.format("%02x", string.byte(char));
		end);
		return "s"..NumberText(#value)..":"..encoded;
	elseif kind == "number" then
		local text = NumberText(value);
		return "n"..NumberText(#text)..":"..text;
	elseif kind == "boolean" then
		return value and "b1" or "b0";
	end
	error("MKFP:unsupported_scalar");
end

function MKMP_Fingerprint_Checksum(payload)
	-- Both 16-bit halves stay exact in Attila's float-based Lua. Do not combine
	-- them in a 32-bit Lua number. This is diagnostics, not a cryptographic ID.
	local a, b = 1, 0;
	for i = 1, #payload do
		a = (a + string.byte(payload, i)) % 65521;
		b = (b + a) % 65521;
	end
	return "adler32-v1:"..string.format("%04x%04x", b, a);
end

local function CaptureTable(data)
	if type(data) ~= "table" then error("MKFP:provider_not_table"); end
	local parts, active = {}, {};
	local entries, bytes = 0, 0;
	local function append(text)
		bytes = bytes + #text;
		if bytes > MKMP_FINGERPRINT_MAX_BYTES then error("MKFP:byte_budget"); end
		parts[#parts + 1] = text;
	end
	local function claim()
		entries = entries + 1;
		if entries > MKMP_FINGERPRINT_MAX_ENTRIES then error("MKFP:entry_budget"); end
	end
	local encode;
	encode = function(value, depth)
		claim();
		if type(value) ~= "table" then append(Scalar(value)); return; end
		if depth > MKMP_FINGERPRINT_MAX_DEPTH then error("MKFP:depth_budget"); end
		if getmetatable(value) ~= nil then error("MKFP:metatable"); end
		if active[value] then error("MKFP:cycle"); end
		active[value] = true;
		local keys, seen = {}, {};
		local key_bytes = 0;
		for key, _ in pairs(value) do
			claim();
			local token = Scalar(key);
			key_bytes = key_bytes + #token;
			if bytes + key_bytes > MKMP_FINGERPRINT_MAX_BYTES then error("MKFP:byte_budget"); end
			if seen[token] then error("MKFP:key_collision"); end
			seen[token] = true;
			keys[#keys + 1] = {key = key, token = token};
		end
		table.sort(keys, function(a, b) return MKMP_Fingerprint_ByteLess(a.token, b.token); end);
		append("m"..NumberText(#keys)..":");
		for i = 1, #keys do
			append(keys[i].token);
			encode(value[keys[i].key], depth + 1);
		end
		active[value] = nil;
	end
	append("MKFP1;");
	encode(data, 1);
	local payload = table.concat(parts);
	return {
		schema = MKMP_FINGERPRINT_SCHEMA, status = "complete", complete = true,
		entries = entries, bytes = bytes,
		checksum = MKMP_Fingerprint_Checksum(payload), payload = payload
	};
end

function MKMP_Fingerprint_Capture(data)
	local ok, result = pcall(CaptureTable, data);
	if ok then return result; end
	return {
		schema = MKMP_FINGERPRINT_SCHEMA, status = "incomplete", complete = false,
		entries = 0, bytes = 0,
		reason = string.match(tostring(result), "MKFP:([a-z_]+)") or "capture_exception"
	};
end
