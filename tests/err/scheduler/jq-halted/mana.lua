function build:getPlatform()
    Scheduler:newDockerTask("get_docker_version", "v1.56", "/version", "GET", "{}")
    Scheduler:newJsonQueryTask("get_platform", "halt_error(1)")
    Scheduler:taskDependsOn("get_platform", "get_docker_version")
end
