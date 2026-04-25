# Tasks

## P3

- [ ] Repo ships a `.editorconfig` so contributors get consistent indentation in shell, bats, and markdown files
  **ID**: add-editorconfig
  **Tags**: dx, style, onboarding
  **Details**: The taskgrind tree mixes `bin/` bash (2-space indent), `tests/*.bats` (2-space indent), `lib/*.sh` (2-space indent), and markdown. Contributors using editors that honor `.editorconfig` (VS Code, JetBrains, Vim plugins) would set indentation correctly on first open. Today there is none. Both the `dotfiles` and `tasks.md` sibling repos ship one. Add `.editorconfig` with one entry per file type and document it in `CONTRIBUTING.md`.
  **Files**: `.editorconfig`, `CONTRIBUTING.md`
  **Acceptance**: A new `.editorconfig` covers `*.{sh,bash,bats}` (2-space indent, LF line endings, final newline), `*.md` (preserve trailing spaces for hard breaks, LF line endings, final newline), and `Makefile` (tab indentation, 8-char width). `CONTRIBUTING.md` mentions it in the Quick Start or Project Structure section. `make check` still passes.


