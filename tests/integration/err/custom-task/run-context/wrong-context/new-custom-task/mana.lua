function run:bye(outputs, build_data)
    return {
        bye = "world"
    }
end

function run:hello(outputs, build_data)
    newCustomTask("bye", run.bye, nil)
    return {
        hello = "world"
    }
end

function build:hello()
    newCustomTask("hello", run.hello, nil)
end
