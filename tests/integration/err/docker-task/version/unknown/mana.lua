function build:getPlatform()
    newDockerTask("get_docker_version", "not adockerversion", "/version", "GET", JSON_EMPTY_OBJECT)
    newJsonQueryTask("get_platform", ".get_docker_version[0].Platform.Name | stderr")
    taskDependsOn("get_platform", "get_docker_version")
end
