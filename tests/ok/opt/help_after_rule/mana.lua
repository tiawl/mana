function build:getPlatform()
    io.stderr:write(self.argv[1].."\n")
    Scheduler:newDockerTask("get_docker_version", "v1.56", "/version", "GET", "{}")
    Scheduler:newJsonQueryTask("get_platform", ".get_docker_version[0].Platform.Name | stderr")
    Scheduler:taskDependsOn("get_platform", "get_docker_version")
end
