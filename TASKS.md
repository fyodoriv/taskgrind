# Tasks

## P0

## P1

## P2

## P3

- [ ] Homebrew tap for easy install
  **ID**: homebrew-tap
  **Tags**: distribution
  **Details**: Create a Homebrew tap (`cbrwizard/tap`) with a formula for taskgrind. Formula clones the repo and symlinks `bin/taskgrind` to the Homebrew prefix. Depends on `bats-core` (test) and `shellcheck` (dev).
  **Files**: separate repo (homebrew-tap), README.md (update install section)
  **Acceptance**: `brew install cbrwizard/tap/taskgrind` installs and `taskgrind --help` works
