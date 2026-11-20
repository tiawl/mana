function build:getPlatform()
    newDockerTask("get_docker_version", self.argv[1], self.argv[2], self.argv[3], JSON_EMPTY_OBJECT)
    newJsonQueryTask("get_platform", ".get_docker_version[0].Platform.Name | stderr")
    taskDependsOn("get_platform", "get_docker_version")
    newDockerBuildTask("build_base", self.argv[1], self.argv[4], "base:latest", JSON_EMPTY_OBJECT)
end
