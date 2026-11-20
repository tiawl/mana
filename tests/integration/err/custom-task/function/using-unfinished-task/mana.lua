function run:hello(outputs, build_data)
    io.stderr:write(outputs["get_docker_version"][1]["Platform"]["Name"].."\n")
    return {
        hello = "world"
    }
end

function build:hello()
    newDockerTask("get_docker_version", "v1.56", "/version", "GET", JSON_EMPTY_OBJECT)
    newCustomTask("hello_world", run.hello, nil)
    taskDependsOn("get_docker_version", "hello_world")
end
