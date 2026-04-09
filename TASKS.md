# Tasks

## P0

## P1

## P2

## P3

- [ ] Add man page
  **ID**: add-man-page
  **Tags**: docs, distribution
  **Details**: Generate a man page from --help output or write `taskgrind.1` manually. Install to standard man path. Low priority — --help is sufficient for most users.
  **Files**: man/taskgrind.1
  **Acceptance**: `man taskgrind` works after install

- [ ] Homebrew tap for easy install
  **ID**: homebrew-tap
  **Tags**: distribution
  **Details**: Create a Homebrew tap (`cbrwizard/tap`) with a formula for taskgrind. Formula clones the repo and symlinks `bin/taskgrind` to the Homebrew prefix. Depends on `bats-core` (test) and `shellcheck` (dev).
  **Files**: separate repo (homebrew-tap), README.md (update install section)
  **Acceptance**: `brew install cbrwizard/tap/taskgrind` installs and `taskgrind --help` works
