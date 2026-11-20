function build:getPlatform()
    newDockerTask("get_docker_version", "v1.56", "/version", "GET", { [true] = "value" })
end
