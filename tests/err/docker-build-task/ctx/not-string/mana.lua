function build:buildImageBase()
    newDockerBuildTask("build_base", "v1.56", 47, "base:latest", "{}")
end
