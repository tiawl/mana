function run:hello(outputs, build_data)
    unlockMutex(10)
end

function build:hello()
    newCustomTask("hello_world", run.hello, nil)
end
