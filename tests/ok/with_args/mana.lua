function build:getPlatform()
    Scheduler:newDockerTask("get_docker_version", self.argv[1], self.argv[2], self.argv[3], "{}")
    Scheduler:newJsonQueryTask("get_platform", ".get_docker_version[0].Platform.Name | stderr")
    Scheduler:taskDependsOn("get_platform", "get_docker_version")
    Scheduler:newDockerBuildTask("build_base", self.argv[1], self.argv[4], "base:latest", "{}")
end
