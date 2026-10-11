cm = { is_multiplayer = function() return true end }
assert(loadfile(arg[1]))()
assert(MKMP_PACK_ID.source == arg[3], "wrong source commit in packaged Lua")
assert(MKMP_PACK_ID.profile == arg[2], "wrong packaged profile")
local experimental = arg[2] == "full-experimental"
assert(MKMP_SP_PARITY.enabled == experimental)
assert(MKMP_SP_PARITY.all_experimental == experimental)
for feature, _ in pairs(MKMP_SP_PARITY) do
    if feature ~= "enabled" and feature ~= "all_experimental" then
        assert(MKMP_SP_PARITY[feature] == false, "individual source flag changed")
    end
end
assert(MKMP_SP_Parity_Enabled("population") == experimental)
assert(MKMP_SP_Parity_Enabled("decisions") == experimental)
assert(MKMP_SP_Parity_Enabled("ironman") == false)
assert(MKMP_SP_Parity_Enabled("change_capital") == false)
assert(MKMP_SP_Parity_Enabled("legacy_networking") == false)
assert(MKMP_SP_Parity_Enabled("unknown_feature") == false)
cm.is_multiplayer = function() return false end
assert(MKMP_SP_Parity_Enabled("population") == false)
print("PASS profile: " .. arg[2])
