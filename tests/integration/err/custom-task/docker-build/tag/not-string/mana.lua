function run:hello(outputs, build_data)
    dockerBuild("v1.56", ".", 52, {})
end

function build:hello()
    newCustomTask("hello_world", run.hello, nil)
end
