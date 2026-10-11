-- Execute the production local Pope UI click and the production shared RNG
-- helper in two isolated Lua environments. This models scripting contracts;
-- it is not a real Attila network session.

local function ui_node(name, state)
    local node = {name = name, children = {}, state = state, x = 0, y = 0};
    function node:Find(child_name)
        return self.children[child_name];
    end
    function node:CreateComponent(child_name, _)
        self.state.created = self.state.created + 1;
        local child = ui_node(child_name, self.state);
        self.children[child_name] = child;
        return child;
    end
    function node:Position() return self.x, self.y; end
    function node:SetState(value) self.ui_state = value; end
    function node:SetMoveable(value) self.moveable = value; end
    function node:MoveTo(x, y) self.x, self.y = x, y; end
    function node:SetVisible(value) self.visible = value; end
    return node;
end

local function child(parent, name)
    local node = ui_node(name, parent.state);
    parent.children[name] = node;
    return node;
end

local function load_source(path, env)
    local chunk = assert(loadfile(path));
    setfenv(chunk, env);
    chunk();
end

local function peer()
    local state = {rng_calls = 0, created = 0};
    local root = ui_node("root", state);
    local garbage = child(root, "garbage");
    local election = child(garbage, "pope_election_panel");
    local button_set = child(election, "button_set");
    child(child(button_set, "accept"), "button_accept");
    local list_box = child(child(election, "preferati_list"), "list_box");
    for i = 1, 3 do
        child(list_box, "cardinal_template_"..tostring(i));
        child(list_box, "button_vote_"..tostring(i));
        local votes = child(list_box, "tx_votes_"..tostring(i));
        votes.x, votes.y = 100, i * 40;
    end

    local cm = {};
    function cm:ui_root() return root; end
    function cm:register_saving_game_callback(_) end
    function cm:register_loading_game_callback(_) end
    function cm:is_multiplayer() return true; end
    function cm:model() return {turn_number = function() return 3; end}; end
    function cm:random_number(maximum, minimum)
        minimum = minimum or 1;
        state.rng_calls = state.rng_calls + 1;
        -- Same scripted engine results on both peers until a peer-local UI
        -- consumes an additional draw. This is not an engine RNG emulator.
        return minimum + ((state.rng_calls * 17 + 19) % (maximum - minimum + 1));
    end

    local env = setmetatable({cm = cm, UIComponent = function(value) return value; end}, {__index = _G});
    env._G = env;
    env.require = function(module)
        assert(module == "common/mkmp_persistence", "unexpected test module "..tostring(module));
        load_source("campaigns/main_attila/"..module..".lua", env);
        return true;
    end;
    load_source("campaigns/main_attila/common/mk1212_common.lua", env);
    load_source("campaigns/main_attila/mechanics/pope/mechanics_pope_ui.lua", env);
    env.MISSION_PANEL_OPEN = false;
    env.POPE_ELECTION_PANEL_OPEN = true;
    -- The unfinished UI has no row-to-candidate binding. It must not mutate
    -- legitimate election data or infer a new voting result from presentation.
    env.COLLEGE_OF_CARDINALS_VOTES = {["10"] = "20"};
    return env, state, list_box;
end

local host, host_state, host_list = peer();
local client, client_state = peer();

host.OnComponentLClickUp_Pope_UI({string = "button_vote_1"});
assert(host_state.created > 0, "local vote click did not exercise UI refresh");
assert(host_state.rng_calls == 0, "HOST-only Pope UI consumed campaign RNG");
assert(client_state.rng_calls == 0, "idle CLIENT consumed campaign RNG");

local first_created = host_state.created;
for i = 1, 3 do
    local count = 0;
    for j = 1, 8 do
        if host_list:Find("faction_logo_"..tostring(i).."_"..tostring(j)) then
            count = count + 1;
        end
    end
    assert(count >= 1 and count <= 8, "placeholder row left its existing 1..8 display budget");
end

for _ = 1, 5 do
    host.OnComponentLClickUp_Pope_UI({string = "button_vote_2"});
end
assert(host_state.rng_calls == 0, "repeated local refresh consumed campaign RNG");
assert(host_state.created == first_created, "repeated refresh duplicated vote logos");
assert(host.COLLEGE_OF_CARDINALS_VOTES["10"] == "20", "UI modified shared election votes");

local host_roll = host.MK1212_Random_Int(16, 30, "test.shared_after_ui");
local client_roll = client.MK1212_Random_Int(16, 30, "test.shared_after_ui");
assert(host_roll == client_roll, "HOST-only UI shifted the next shared campaign draw");
assert(host_state.rng_calls == 1 and client_state.rng_calls == 1, "shared RNG call counts differ");

print("PASS: production Pope UI keeps shared RNG untouched; repeated refresh is bounded");
