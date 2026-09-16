{
  lib,
  buildHelixPlugin,
  run-command,
  http2curl,
}:
buildHelixPlugin {
  pname = "connect.hx";
  version = "0.0.1";

  # The cog is the repo itself, but only the files steel actually loads are in
  # the source set -- mirroring the builder's install step, which globs
  # `**/*.scm`. Editing the design doc or the README therefore does not force a
  # rebuild of every consumer.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "scm") ./.;
  };

  # Both MIT, both standalone: run-command spawns processes and captures
  # output without deadlocking or leaving zombies; http2curl parses the
  # vscode-restclient `.http` syntax this format is a superset of.
  pluginDependencies = [
    run-command
    http2curl
  ];

  doSteelCheck = true;

  meta = {
    description = "A ConnectRPC client for the Helix editor";
    homepage = "https://github.com/apetrovic/connect.hx";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
