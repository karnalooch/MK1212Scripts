-- Exercise the actual Lua 5.1 C numeric conversion under a comma locale.
-- This process-local test must not be replaced by a fake tonumber function.
package.path = "campaigns/main_attila/?.lua;"..package.path;

local data = {};
cm = {};
function cm:register_saving_game_callback(_) end
function cm:register_loading_game_callback(_) end
function cm:save_value(key, value, _) data[key] = value; end
function cm:load_value(key, default, _)
    if data[key] ~= nil then return data[key]; end
    return default;
end
dofile("campaigns/main_attila/common/mk1212_common.lua");

assert(os.setlocale("C", "numeric"));
local numbers = {zero = 0, positive = 1.5, negative = -2.75, tenth = 0.1,
    -- Vendored Attila Lua 5.1 uses LUA_NUMBER float. These magnitudes exercise
    -- exponent formatting without overflowing/underflowing that actual type.
    tiny = 1.23456789012345e-20, large = 1.23456789012345e20, integer = 42};
SaveKeyPairTable(nil, numbers, "numbers");
local canonical_payload = data.numbers;
-- Valid old numeric tokens were also dot-decimal; legacy schema loading must
-- remain usable after changing the process numeric locale.
data.legacy_numbers = "ratio,1.5,;negative,-2.75,;";
data.legacy_numbers__schema = 2;

local candidates = {os.getenv("MK1212_TEST_NUMERIC_LOCALE") or "pl_PL.UTF-8",
    "pl_PL.utf8", "de_DE.UTF-8", "de_DE.utf8", "fr_FR.UTF-8", "fr_FR.utf8"};
local selected;
for _, candidate in ipairs(candidates) do
    local available = os.setlocale(candidate, "numeric");
    if available and string.format("%.1f", 1.5) == "1,5" then
        selected = available;
        break;
    end
end
if not selected then
    print("SKIP: no comma numeric locale is installed or generated");
    os.exit(77);
end
assert(tonumber("1.5") == nil and tonumber("1,5") == 1.5,
    "test runtime did not expose the real locale-dependent strtod behavior");

local loaded = LoadKeyPairTableNumbers(nil, "numbers");
for key, expected in pairs(numbers) do
    assert(loaded[key] == expected, "comma locale changed binary number "..key);
end
SaveKeyPairTable(nil, loaded, "numbers");
assert(data.numbers == canonical_payload, "numeric locale changed canonical save bytes");
local legacy = LoadKeyPairTableNumbers(nil, "legacy_numbers");
assert(legacy.ratio == 1.5 and legacy.negative == -2.75, "legacy dot decimals no longer load");
assert(not pcall(MK1212_SaveNumber, "1.5trailing", "malformed"), "partial numeric parse accepted");
assert(os.setlocale(nil, "numeric") == selected, "codec changed process numeric locale");

assert(os.setlocale("C", "numeric"));
loaded = LoadKeyPairTableNumbers(nil, "numbers");
for key, expected in pairs(numbers) do
    assert(loaded[key] == expected, "C locale cannot reload comma-locale save "..key);
end
print("PASS: real comma numeric locale, binary-number round trip and canonical bytes ("..selected..")");
