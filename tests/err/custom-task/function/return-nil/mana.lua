function hello()
    io.stderr:write("Hello world !\n")
end

function build:hello()
    newCustomTask("hello_world", hello)
end
