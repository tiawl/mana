function build:getPlatform()
    newDockerTask("get_docker_version", "v1.56", "/version", "GET", "{}")
    newJsonQueryTask("get_platform", "halt_error(1)")
    taskDependsOn("get_platform", "get_docker_version")
end
