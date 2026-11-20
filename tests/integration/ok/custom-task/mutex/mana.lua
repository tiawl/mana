message = "bye"

function run:bye(outputs, build_data)
    lockMutex("accessMessage");
    io.stderr:write(message.."\n")
    unlockMutex("accessMessage");
    return {
        bye = "world"
    }
end

function run:hello(outputs, build_data)
    lockMutex("accessMessage");
    io.stderr:write(message.."\n")
    unlockMutex("accessMessage");
    return {
        hello = "world"
    }
end

function build:hello()
    newCustomTask("hello_world", run.hello, nil)
    newCustomTask("bye_world", run.bye, nil)
    newMutex("accessMessage");
end
