function build:getPlatform()
    Scheduler:newDockerTask("get_docker_version", "v1.56", "/version", 10, "{}")
    Scheduler:newJsonQueryTask("get_platform", ".get_docker_version[0].Platform.Name | stderr")
    Scheduler:taskDependsOn("get_platform", "get_docker_version")
end
