function build:buildImageBase()
    newDockerBuildTask("build_base", "not adockerversion", self.argv[1], "base:latest", JSON_EMPTY_OBJECT)
end
