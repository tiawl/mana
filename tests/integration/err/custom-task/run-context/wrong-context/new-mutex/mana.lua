function run:hello(outputs, build_data)
    newMutex("myMutex")
    return {
        hello = "world"
    }
end

function build:hello()
    newCustomTask("hello", run.hello, nil)
end
