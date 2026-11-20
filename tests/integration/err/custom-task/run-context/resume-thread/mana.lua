function run:hello(outputs, build_data)
    io.stderr:write(outputs.."\n")
    return {
        hello = "world"
    }
end

function build:hello()
    newCustomTask("hello", run.hello, nil)
end
