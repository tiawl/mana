function build:getPlatform()
    newDockerTask("get_docker_version", "v1.56", "/unknown", "GET", JSON_EMPTY_OBJECT)
    newJsonQueryTask("get_platform", ".get_docker_version[0] | stderr")
    taskDependsOn("get_platform", "get_docker_version")
end
