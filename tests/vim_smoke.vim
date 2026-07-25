set nocompatible
set nomore
execute 'set runtimepath^=' .. fnameescape(getcwd())
let g:simplefinder_daemon_path = getcwd() .. '/target/debug/simplefinder-daemon'
runtime plugin/simplefinder.vim

SimpleFinderBuffers
SimpleFinderRecent
SimpleFinderIGrep simplefinder
SimpleFinderResume
SimpleFinderFiles daemon
SimpleFinderRoot

qa!
