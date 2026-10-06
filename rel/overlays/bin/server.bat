@echo off
pushd %~dp0
set PHX_SERVER=true
call ex_tales_forge start
popd
