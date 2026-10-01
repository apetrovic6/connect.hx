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
  #
  # Under passthru, not as a top-level argument: buildHelixPlugin changed where
  # it reads this. It used to take `pluginDependencies` as an argument and copy
  # it into passthru; it now reads `args.passthru.pluginDependencies` and
  # defaults to []. A top-level one is silently ignored, so the cog installs
  # without its dependency and the first sign is helix refusing to start --
  # `(require "run-command/run-command.scm")` fails at load with "No such file
  # or directory", because the consuming configuration walks passthru to decide
  # what to put in STEEL_HOME.
  passthru.pluginDependencies = [run-command];

  doSteelCheck = true;

  meta = {
    description = "A ConnectRPC client for the Helix editor";
    homepage = "https://github.com/apetrovic6/connect.hx";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
