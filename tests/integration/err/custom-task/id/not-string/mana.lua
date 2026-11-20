function run:hello(outputs, build_data)
    return {
        hello = "world"
    }
end

function build:hello()
    newCustomTask(10, run.hello, nil)
end
