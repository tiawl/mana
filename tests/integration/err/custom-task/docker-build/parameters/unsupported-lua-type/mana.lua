function dummy() end

function run:hello(outputs, build_data)
    dockerBuild("v1.56", ".", "base-latest", dummy)
end

function build:hello()
    newCustomTask("hello_world", run.hello, nil)
end
