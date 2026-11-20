function build:getPlatform()
    newDockerTask("get_docker_version", "v1.56", "/version", "GET", JSON_EMPTY_OBJECT)
    newJsonQueryTask("get_platform", ".get_docker_version[0] | undefined_func")
    taskDependsOn("get_platform", "get_docker_version")
end
