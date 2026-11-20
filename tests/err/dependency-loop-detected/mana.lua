function build:getPlatform()
    newDockerTask("get_docker_version", "v1.56", "/version", "GET", "{}")
    taskDependsOn("get_docker_version", "get_docker_version")
end
