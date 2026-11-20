function run:hello(outputs, build_data)
    docker("v1.56", 10, "GET", {})
end

function build:hello()
    newCustomTask("hello_world", run.hello, nil)
end
