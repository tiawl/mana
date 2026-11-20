function build:buildImageBase()
    newDockerBuildTask("build_base", 10.56, self.argv[1], "base:latest", JSON_EMPTY_OBJECT)
end
