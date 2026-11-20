function run:hello(outputs, build_data)
    print(docker("v1.56", "/version", "GET", JSON_EMPTY_OBJECT)[1]["Platform"]["Name"])
    return {
        hello = "world"
    }
end

function build:hello()
    newCustomTask("version", run.hello, nil)
end
