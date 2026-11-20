function run:hello(outputs, build_data)
    docker(10, "/version", "GET", {})
end

function build:hello()
    newCustomTask("hello_world", run.hello, nil)
end
