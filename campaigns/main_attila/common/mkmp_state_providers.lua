-- Diagnostic views own their copies. They are never returned to the gameplay
-- executor and never reconstruct model state from a log or fingerprint.

function MKMP_Diagnostic_Copy(value)
	local seen, nodes, bytes = {}, 0, 0;
	local function copy(item, depth)
		nodes = nodes + 1;
		if nodes > 16384 or depth > 16 then error("diagnostic state exceeds node budget"); end
		local kind = type(item);
		if kind ~= "table" then
			if kind ~= "string" and kind ~= "number" and kind ~= "boolean" then error("diagnostic state unsupported"); end
			local text = MK1212_SaveScalar(item);
			bytes = bytes + #text + 16;
			if bytes > 131072 then error("diagnostic state exceeds byte budget"); end
			return item;
		end
		if getmetatable(item) ~= nil then error("diagnostic state must be a plain table"); end
		if seen[item] then error("diagnostic state cycle"); end
		seen[item] = true;
		local output = {};
		for key, child in pairs(item) do
			if type(key) ~= "string" and type(key) ~= "number" then error("diagnostic state invalid key"); end
			output[copy(key, depth + 1)] = copy(child, depth + 1);
		end
		seen[item] = nil;
		return output;
	end
	return copy(value, 0);
end

local providers_registered = false;
function MKMP_Register_Campaign_State_Providers()
	if providers_registered or not MKMP_Debug_Register_State_Provider then return; end
	providers_registered = true;
	local providers = {
		{"deferred_transfers", "MKMP_Transfers_Get_State"},
		{"buffer", "MKMP_Buffer_Get_State"},
		{"vassals", "MKMP_Vassals_Get_State"},
		{"decisions", "MKMP_Decisions_Get_State"},
		{"region_trade", "MKMP_Region_Trade_Get_State"},
		{"population", "MKMP_Population_Get_State"},
		{"population_counts", "MKMP_Population_Counts_Get_State"},
		{"population_manpower", "MKMP_Population_Manpower_Get_State"},
		{"annexation", "MKMP_Annex_Get_State"}
	};
	for i = 1, #providers do
		local provider = providers[i];
		local name, getter = provider[1], provider[2];
		MKMP_Debug_Register_State_Provider(name, function()
			if type(_G[getter]) ~= "function" then return nil, "unavailable", "module_unavailable"; end
			return _G[getter]();
		end);
	end
end
