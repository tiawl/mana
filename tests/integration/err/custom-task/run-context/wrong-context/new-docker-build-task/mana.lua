function run:hello(outputs, build_data)
    newDockerBuildTask("build_base", "v1.56", ".", "base:latest", JSON_EMPTY_OBJECT)
    return {
        hello = "world"
    }
end

function build:hello()
    newCustomTask("hello", run.hello, nil)
end
