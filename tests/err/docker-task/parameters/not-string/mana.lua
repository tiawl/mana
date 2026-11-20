function build:getPlatform()
    newDockerTask("get_docker_version", "v1.56", "/version", "GET", 23)
    newJsonQueryTask("get_platform", ".get_docker_version[0].Platform.Name | stderr")
    taskDependsOn("get_platform", "get_docker_version")
end
