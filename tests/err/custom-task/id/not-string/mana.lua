function hello(outputs)
    return "{\"hello\": \"world\"}"
end

function build:hello()
    newCustomTask(10, hello)
end
