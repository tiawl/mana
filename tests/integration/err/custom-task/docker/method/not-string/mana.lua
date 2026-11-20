function run:hello(outputs, build_data)
    docker("v1.56", "/version", 10, {})
end

function build:hello()
    newCustomTask("hello_world", run.hello, nil)
end
