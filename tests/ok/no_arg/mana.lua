function hello(outputs)
    io.stderr:write(outputs["get_docker_version"].."\n")
    io.stderr:write("Hello world !\n")
    return "{\"hello\": \"world\"}"
end

function build:getPlatform()
    newDockerTask("get_docker_version", "v1.56", "/version", "GET", "{}")
    newJsonQueryTask("get_platform", ".get_docker_version[0].Platform.Name | stderr")
    taskDependsOn("get_platform", "get_docker_version")
    newCustomTask("hello_world", hello)
    taskDependsOn("hello_world", "get_docker_version")
    taskDependsOn("get_platform", "hello_world")
end
