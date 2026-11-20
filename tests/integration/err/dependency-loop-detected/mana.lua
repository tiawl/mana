function build:getPlatform()
    newDockerTask("get_docker_version", "v1.56", "/version", "GET", JSON_EMPTY_OBJECT)
    taskDependsOn("get_docker_version", "get_docker_version")
end
