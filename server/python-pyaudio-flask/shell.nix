{pkgs ? import <nixpkgs> {}}: let
  python = pkgs.python314;
  pythonEnv = python.withPackages (ps:
    with ps; [
      edge-tts
      flask
      asgiref
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
