function run:hello(outputs, build_data)
    newJsonQueryTask("dummy", ".")
    return {
        hello = "world"
    }
end

function build:hello()
    newCustomTask("hello", run.hello, nil)
end
