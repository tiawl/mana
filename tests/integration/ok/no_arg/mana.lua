function run:hello(outputs, build_data)
    io.stderr:write(outputs["get_docker_version"][1]["Platform"]["Name"].."\n")
    io.stderr:write("Hello world !\n")
    io.stderr:write(build_data.sent.."\n")
    return {
        hello = "world"
    }
end

function build:getPlatform()
    local build_data = { sent = "to run context" }
    newDockerTask("get_docker_version", "v1.56", "/version", "GET", JSON_EMPTY_OBJECT)
    newJsonQueryTask("get_platform", ".get_docker_version[0].Platform.Name | stderr")
    taskDependsOn("get_platform", "get_docker_version")
    newCustomTask("hello_world", run.hello, build_data)
    taskDependsOn("hello_world", "get_docker_version")
    taskDependsOn("get_platform", "hello_world")
end
