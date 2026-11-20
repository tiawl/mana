function dummy() end

function run:hello(outputs, build_data)
    io.stderr:write("Hello world !\n")
    return dummy
end

function build:hello()
    newCustomTask("hello_world", run.hello, nil)
end
