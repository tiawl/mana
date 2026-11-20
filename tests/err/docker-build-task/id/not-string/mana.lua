function build:buildImageBase()
    newDockerBuildTask(10, "v1.56", self.argv[1], "base:latest", "{}")
end
