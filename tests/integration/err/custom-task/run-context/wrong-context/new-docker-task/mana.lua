function run:hello(outputs, build_data)
    newDockerTask("get_docker_version", "v1.56", "/version", "GET", JSON_EMPTY_OBJECT)
    return {
        hello = "world"
    }
end

function build:hello()
    newCustomTask("hello", run.hello, nil)
end
