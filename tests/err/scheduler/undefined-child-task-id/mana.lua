function build:getPlatform()
    Scheduler:newDockerTask("get_docker_version", "v1.56", "/version", "GET", "{}")
    Scheduler:taskDependsOn("get_platform", "get_docker_version")
end
