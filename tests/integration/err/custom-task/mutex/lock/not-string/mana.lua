function run:hello(outputs, build_data)
    lockMutex(10)
end

function build:hello()
    newCustomTask("hello_world", run.hello, nil)
end
