message = "bye"

function build:hello()
    newMutex("accessMessage")
    lockMutex("accessMessage")
end
