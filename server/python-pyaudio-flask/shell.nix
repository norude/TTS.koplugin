{pkgs ? import <nixpkgs> {}}: let
  python = pkgs.python314;
  pythonEnv = python.withPackages (ps:
    with ps; [
      edge-tts
      flask
      flask.optional-dependencies.async
      pyaudio
      pydub
      onnxruntime
      pathvalidate
    ]);
in
  pkgs.mkShell {
    buildInputs = [
      pythonEnv
      pkgs.piper-tts
    ];
  }
