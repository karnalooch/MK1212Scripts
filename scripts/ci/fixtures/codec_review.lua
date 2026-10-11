-- Independent compatibility regressions based on the schema-2 writer shape.
-- Generated legacy payloads are fixtures, not real user campaign saves.
package.path = "campaigns/main_attila/?.lua;"..package.path;

local data = {};
local writes = 0;
cm = {};
function cm:register_saving_game_callback(_) end
function cm:register_loading_game_callback(_) end
function cm:save_value(key, value, _)
    writes = writes + 1;
    data[key] = value;
end
function cm:load_value(key, default, _)
    if data[key] ~= nil then return data[key]; end
    return default;
end
dofile("campaigns/main_attila/common/mk1212_common.lua");

local function expect_error(call, label)
    assert(not pcall(call), label.." unexpectedly accepted malformed input");
end

-- Schema 2 limited maps to 20,000 rows, not 20,000 scalar fields. This payload
-- is below both the historical row limit and the 1 MiB byte limit.
local legacy_rows = {};
for i = 1, 10001 do legacy_rows[i] = "key_"..tostring(i)..",value,;"; end
data.legacy_large = table.concat(legacy_rows);
data.legacy_large__schema = 2;
local loaded_large = LoadKeyPairTable(nil, "legacy_large");
local loaded_count = 0;
for _, _ in pairs(loaded_large) do loaded_count = loaded_count + 1; end
assert(loaded_count == 10001, "legacy row budget was silently reduced");
SaveKeyPairTable(nil, loaded_large, "migrated_large");
assert(LoadKeyPairTable(nil, "migrated_large").key_10001 == "value", "legacy large map cannot migrate");

-- An old raw first token may legitimately start with the future magic text.
-- Sidecar schema, not that literal alone, identifies a new-format payload.
for _, schema in ipairs({0, 1, 2}) do
    data.legacy_prefix = "MK1212_SAVE_V3|City,%E,%2C,";
    data.legacy_prefix__schema = schema;
    local values = LoadTable(nil, "legacy_prefix");
    assert(values[1] == "MK1212_SAVE_V3|City", "legacy prefix token changed");
    assert(values[2] == "%E" and values[3] == "%2C", "legacy percent text was unescaped");
end

-- Real user-entered region names can contain punctuation and non-ASCII bytes.
-- New saves must preserve their complete value, including explicit emptiness.
local cities = {
    att_reg_lodz = "Łódź, Nowe; Miasto | 100%",
    att_reg_quote = "O'Brien \\\"West\\\"",
    att_reg_empty = "",
    att_reg_controls = "First\nSecond\r\nThird\tEnd"..string.char(0),
    ["region,key;with%delimiters"] = "%E; literal, not empty",
};
SaveKeyPairTable(nil, cities, "cities");
local first_encoding = data.cities;
local loaded_cities = LoadKeyPairTable(nil, "cities");
for key, value in pairs(cities) do
    assert(loaded_cities[key] == value, "city bytes changed for "..key);
end
SaveKeyPairTable(nil, loaded_cities, "cities");
assert(data.cities == first_encoding, "city save/load/save bytes are unstable");

-- Existing comma-separated names already lost data in the legacy loader.
-- A generic decoder cannot reconstruct that author's intended row safely.
data.corrupt_legacy = "att_reg_paris,Paris, Ile-de-France,;";
data.corrupt_legacy__schema = 2;
expect_error(function() LoadKeyPairTable(nil, "corrupt_legacy"); end, "ambiguous legacy city");

-- Diagnostics must not interrupt an otherwise valid save, even if either
-- checksum generation or the log sink raises an exception.
local original_checksum = MK1212_SaveChecksum;
MKMP_Debug_Log = function() end;
MK1212_SaveChecksum = function() error("injected diagnostics checksum failure"); end;
local writes_before = writes;
SaveKeyPairTable(nil, {city = "Paris"}, "checksum_fault");
assert(writes == writes_before + 2, "checksum failure altered engine writes");
assert(LoadKeyPairTable(nil, "checksum_fault").city == "Paris", "checksum failure corrupted output");
MK1212_SaveChecksum = original_checksum;
MKMP_Debug_Log = function() error("injected log sink failure"); end;
SaveKeyPairTable(nil, {city = "Rome"}, "logger_fault");
assert(LoadKeyPairTable(nil, "logger_fault").city == "Rome", "logger failure corrupted output");
MKMP_Debug_Log = nil;

-- Lua 5.1 delegates string '<' to strcoll. Canonical saves require byte order,
-- independent of that process locale. Exercise a second locale when installed
-- and print whether the differential check actually ran.
local collation_map = {A = "1", a = "2", Z = "3", z = "4", _ = "5", ["ä"] = "6"};
local original_collation = os.setlocale(nil, "collate");
assert(os.setlocale("C", "collate"));
SaveKeyPairTable(nil, collation_map, "c_collation");
local expected = data.c_collation;
local alternate = os.setlocale("en_US.utf8", "collate") or os.setlocale("en_US.UTF-8", "collate");
if alternate then
    SaveKeyPairTable(nil, collation_map, "alternate_collation");
    assert(data.alternate_collation == expected, "save key order depends on local collation");
    print("locale_parity=checked");
else
    print("locale_parity=unavailable; byte-format and compatibility checks still executed");
end
assert(os.setlocale(original_collation, "collate"));

print("PASS: codec legacy capacity, literal migration, city bytes and diagnostic isolation");
