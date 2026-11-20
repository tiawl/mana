function build:buildImageBase()
    Scheduler:newDockerBuildTask("build_base", "not adockerversion", self.argv[1], "base:latest", "{}")
end
