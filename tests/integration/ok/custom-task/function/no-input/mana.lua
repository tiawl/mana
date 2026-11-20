function run:hello()
    io.stderr:write("Hello world !\n")
    return {
        hello = "world"
    }
end

function build:hello()
    newDockerTask("get_docker_version", "v1.56", "/version", "GET", JSON_EMPTY_OBJECT)
    newCustomTask("hello_world", run.hello, nil)
    taskDependsOn("hello_world", "get_docker_version")
end
