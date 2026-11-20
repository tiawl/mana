function build:buildImageBase()
    newDockerBuildTask("build_base", "v1.56", self.argv[1], 47, JSON_EMPTY_OBJECT)
end
