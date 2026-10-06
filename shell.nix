{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
    pkgs.sqlite
  ];

  buildInputs = with pkgs; [
    flutter
    pkg-config

    # For flutter_secure_storage and other Linux desktop plugins
    libsecret.dev
    jsoncpp.dev
    gtk3.dev
    libepoxy.dev
    libsysprof-capture
    pcre2.dev
    util-linux.dev
    libselinux.dev
    libsepol.dev
    libgcrypt.dev
    libgpg-error.dev
    curl.dev
    sqlite
    libthai.dev
    libdatrie.dev
    libxdmcp.dev
    libxkbcommon.dev
    systemdLibs
    libxtst

    jdk17

    # Build tools
    ninja
    cmake
    clang
  ];
}
