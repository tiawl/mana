function build:getPlatform()
    Scheduler:newDockerTask("get_docker_version", "v1.56", "/unknown", "GET", "{}")
    Scheduler:newJsonQueryTask("get_platform", ".get_docker_version[0] | stderr")
    Scheduler:taskDependsOn("get_platform", "get_docker_version")
end
