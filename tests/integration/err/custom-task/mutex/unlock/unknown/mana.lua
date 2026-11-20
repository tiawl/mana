function run:hello(outputs, build_data)
    unlockMutex("unknown")
end

function build:hello()
    newMutex("mutex")
    newCustomTask("hello_world", run.hello, nil)
end
