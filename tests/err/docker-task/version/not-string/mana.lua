function build:getPlatform()
    newDockerTask("get_docker_version", 10.56, "/version", "GET", "{}")
    newJsonQueryTask("get_platform", ".get_docker_version[0].Platform.Name | stderr")
    taskDependsOn("get_platform", "get_docker_version")
end
