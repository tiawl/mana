function build:getPlatform()
    newDockerTask(10, "v1.56", "/version", "GET", JSON_EMPTY_OBJECT)
    newJsonQueryTask("get_platform", ".get_docker_version[0].Platform.Name | stderr")
    taskDependsOn("get_platform", "get_docker_version")
end
