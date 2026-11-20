function build:getPlatform()
    Scheduler:newDockerTask("get_docker_version", "v1.56", "/version", "GET", "{}")
    Scheduler:newDockerTask("get_docker_version", "v1.56", "/version", "GET", "{}")
end
