function build:buildImageBase()
    Scheduler:newDockerBuildTask("build_base", 10.56, self.argv[1], "base:latest", "{}")
end
