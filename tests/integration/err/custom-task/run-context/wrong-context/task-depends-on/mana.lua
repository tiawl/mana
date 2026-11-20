function run:hello(outputs, build_data)
    taskDependsOn("task1", "task2")
    return {
        hello = "world"
    }
end

function build:hello()
    newCustomTask("hello", run.hello, nil)
end
