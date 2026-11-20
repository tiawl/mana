function build:get-platform()
    Scheduler:newDockerTask("get_docker_version", "v1.56", "/version", "GET", "{}")
    Scheduler:newJsonQueryTask("get_platform", ".get_docker_version[0].Platform.Name | stderr")
    Scheduler:taskDependsOn("get_platform", "get_docker_version")
end
