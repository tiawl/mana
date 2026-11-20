function hello()
    io.stderr:write("Hello world !\n")
    return 5
end

function build:hello()
    newCustomTask("hello_world", hello)
end
