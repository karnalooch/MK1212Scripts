-- Parse, but do not execute, every emitted campaign/frontend/library source.
for i = 1, #arg do
    local chunk, err = loadfile(arg[i])
    assert(chunk, tostring(err))
end
print("PASS syntax: " .. tostring(#arg))
