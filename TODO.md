Think more about it:
- split InitTask into GroupTask + CallTask ??
- add ReadZonTask + IncludeTask ?
- add ConditionalTask ?
- inventory ??
- add CommandTask for ssh ?

Go for it:
- write tests for exit.expected(1) cases
- return err if rule name:
  - contains whitespace
  - starts with dash
- make docker.Client a singleton
- add oniguruma for jq
- build.zig: replace .debug optimize everywhere with user optimize
- add verbose mode
- add the possibility to send arguments to a rule
- add the possibility to use .{.jq = ".my.filter"} anywhere => potentially rewrite Spec to manage jv objects instead of Zig objects
- rule scope: public or private
- hash the key into Scheduler.addTask()
- add plugin system for custom tasks/modules
