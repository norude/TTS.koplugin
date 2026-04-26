{ pkgs ? import <nixpkgs> { } }:
pkgs.callPackage ({ mkShell }:
  mkShell {
    buildInputs = with pkgs; [
      piper-tts
      python313
      python313Packages.edge-tts
      python313Packages.flask
      python313Packages.flask.optional-dependencies.async
      python313Packages.pyaudio
      python313Packages.pydub
    ];
  }) { }
