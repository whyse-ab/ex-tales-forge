@echo off
pushd %~dp0
call ex_tales_forge eval TalesForge.Release.migrate
popd
