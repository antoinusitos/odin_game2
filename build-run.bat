@echo off

rem This package is a build script, see build.odin for more
odin run sauce\build -debug -- testarg

build\windows_debug\game.exe