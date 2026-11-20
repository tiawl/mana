message = "bye"

function build:hello()
    newMutex("accessMessage")
    unlockMutex("accessMessage")
end
