(define package-name 'connect.hx)
(define version "0.0.1")

;; forge resolves these when the plugin is installed outside nix. The nix
;; build takes the same cogs from `pluginDependencies` in package.nix --
;; keep both lists in step.
(define dependencies
  '((#:name run-command
     #:git-url "https://github.com/waddie/run-command.scm")))
