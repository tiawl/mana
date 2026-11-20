function build:buildImageBase()
    Scheduler:newDockerBuildTask("build_base", "v1.56", 47, "base:latest", "{}")
end
