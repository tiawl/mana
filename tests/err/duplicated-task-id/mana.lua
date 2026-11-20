function build:getPlatform()
    newDockerTask("get_docker_version", "v1.56", "/version", "GET", "{}")
    newDockerTask("get_docker_version", "v1.56", "/version", "GET", "{}")
end
