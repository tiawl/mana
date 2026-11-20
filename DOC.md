# Doc

wip

## Log levels

- verbose: `mana` reported an internal debug detail.
- debug: `mana` reported an internal step or success during its execution.
- note: `mana` reported a user step during its execution.
- info: `mana` reported a user success during its execution.
- warning: `mana` encountered an error but ignore it and continue its execution. You can solve it by yourself.
- error: `mana` encountered an error and can't continue its execution. It is a reproducible error. So you can solve it by yourself.
- fatal: `mana` encountered an error and can't continue its execution. It is an unreproducible error. You probably can't solve by yourself. If encountered, you should open an issue.

## Run context

As stated in the README, one of the core principles of `mana` is "User Control". So it gives you the most freedom it can. But it comes with the cost of responsability. In the run context, tasks are executed asynchronously. Each task is executed in its own thread and in its own Lua stack. So you are free to create new variables and access it whenever you want. But things become touchy for global variables.
From a custom task, if:
- you need to change the value of a global variable
- or you need to read the value of a global variable that could change
You can guarantee a sequential access to a global variable using `taskDependsOn` during build context. But it's a huge cost and it's not really elegant. To solve this usecase, `mana` introduced 3 Lua functions:
- `newMutex(name)`: only usable in build context
- `lockMutex(name)`: only usable in run context
- `unlockMutex(name)`: only usable in run context
