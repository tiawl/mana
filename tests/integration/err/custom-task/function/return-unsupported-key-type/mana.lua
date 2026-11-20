function run:hello(outputs, build_data)
    io.stderr:write("Hello world !\n")
    return { [true] = "value" }
end

function build:hello()
    newCustomTask("hello_world", run.hello, nil)
end
