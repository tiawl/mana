Think more about it:
- split InitTask into GroupTask + CallTask ??
- add ReadZonTask + IncludeTask ?
- add ConditionalTask ?
- inventory ??
- add CommandTask for ssh ?

Go for it:
- write tests for warning
- return err if rule name:
  - contains whitespace
  - starts with dash
- make docker.Client a singleton
- add oniguruma for jq
- build.zig: replace .debug optimize everywhere with user optimize
- add verbose mode: options + more debug
- add the possibility to send arguments to a rule
- add the possibility to use .{.jq = ".my.filter"} anywhere => potentially rewrite Spec to manage jv objects instead of Zig objects
- rule scope: public or private
- hash the key into Scheduler.addTask()
- add plugin system for custom tasks/modules:
    - see how zig fetch and manage dependencies
    - use https://github.com/natecraddock/ziglua or write a custom lua C API binding
    - use https://github.com/nmap/nmap/blob/9faa841afd45103cf190f13f67320f28a4623f0b/nselib/libssh2-utility.lua in lua script for ssh client
