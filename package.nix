{
  lib,
  buildHelixPlugin,
  run-command,
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

  # run-command spawns processes and captures output without deadlocking or
  # leaving zombies. MIT, standalone.
  pluginDependencies = [run-command];

  doSteelCheck = true;

  meta = {
    description = "A ConnectRPC client for the Helix editor";
    homepage = "https://github.com/apetrovic/connect.hx";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
