{
  "targets": [
    {
      "target_name": "delphi_pty",
      "sources": [ "addon.cpp" ],
      "include_dirs": [
        "<!@(node -p \"require('node-addon-api').include\")"
      ],
      "dependencies": [
        "<!(node -p \"require('node-addon-api').gyp\")"
      ],
      "defines": [ 
        "NAPI_DISABLE_CPP_EXCEPTIONS",
        "WIN32_LEAN_AND_MEAN",
        "_CRT_SECURE_NO_WARNINGS"
      ],
      "msvs_settings": {
        "VCCLCompilerTool": {
          "ExceptionHandling": 1,
          "AdditionalOptions": [ "/EHsc" ]
        }
      },
      "conditions": [
        ["OS=='win'", {
          "libraries": [ "-lkernel32.lib", "-luser32.lib" ]
        }]
      ]
    }
  ]
}