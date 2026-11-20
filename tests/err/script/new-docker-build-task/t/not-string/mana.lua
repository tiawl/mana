function build:buildImageBase()
    Scheduler:newDockerBuildTask("build_base", "v1.56", self.argv[1], 47, "{}")
end
