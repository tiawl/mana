function run:hello(outputs, build_data)
    lockMutex("unknown")
end

function build:hello()
    newMutex("mutex")
    newCustomTask("hello_world", run.hello, nil)
end
