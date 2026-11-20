function build:buildImageBase()
    newDockerBuildTask("build_base", "v1.56", self.argv[1], "base:latest", 23)
end
