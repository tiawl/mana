function hello()
    io.stderr:write("Hello world !\n")
    return "XX"
end

function build:hello()
    newCustomTask("hello_world", hello)
end
