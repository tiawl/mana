function run:hello(outputs, build_data)
    dockerBuild(10, ".", "base:latest", {})
end

function build:hello()
    newCustomTask("hello_world", run.hello, nil)
end
