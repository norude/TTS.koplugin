{ pkgs ? import <nixpkgs> { } }:
pkgs.callPackage ({ mkShell }:
  mkShell {
    buildInputs = with pkgs; [ piper-tts python313 python313Packages.pyaudio ];
  }) { }
