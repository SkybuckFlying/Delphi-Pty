{
  "targets": [
    {
      "target_name": "delphi_pty",
      "sources": [ "addon.cpp" ],
      "include_dirs": [
        "<!(node -p \"require('node-addon-api').include\")"
      ],
      "defines": [ "NAPI_CPP_EXCEPTIONS" ],
      "cflags!": [ "-fno-exceptions" ],
      "cxxflags!": [ "-fno-exceptions" ]
    }
  ]
}